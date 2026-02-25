import UIKit
import HomeKit
import ServiceManagement

final class AppDelegate: NSObject, UIApplicationDelegate, ObservableObject {

    // MARK: - Public (observed by UI)

    @Published private(set) var statusText: String? = String(localized: "status.starting")
    @Published private(set) var homes: [HomeInfo] = []
    @Published private(set) var isServerRunning = false
    @Published private(set) var serverAddress = "localhost:18089"
    @Published var launchAtLogin = false

    /// When `true`, the next scene that connects should be shown.
    /// When `false`, it is the automatic initial scene and should be dismissed.
    var shouldShowWindow = false

    // MARK: - Internal

    let homeManager = HMHomeManager()
    private(set) var cache: HomeKitCache!
    private var httpServer: HTTPServer?
    private var statusBarController: StatusBarController?

    private static let serverPort: UInt16 = 18089

    // MARK: - UIApplicationDelegate

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        cache = HomeKitCache(homeManager: homeManager)

        NotificationCenter.default.addObserver(
            forName: .homeKitCacheDidRebuild,
            object: cache,
            queue: .main
        ) { [weak self] _ in
            self?.handleCacheRebuild()
        }

        #if targetEnvironment(macCatalyst)
        // Start as a menu-bar-only app (no Dock icon, no window).
        setActivationPolicy(.accessory)
        #endif

        setupMenuBar()
        readLaunchAtLoginState()

        print("[RestyHome] Waiting for HomeKit homes to load...")
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    // MARK: - Window Management

    func showWindow() {
        #if targetEnvironment(macCatalyst)
        guard ensureAppKitLoaded() else { return }
        guard let nsApp = getNSApp() else { return }

        // Mark that we intentionally want a window
        shouldShowWindow = true

        // Switch from accessory (no dock icon) to regular (dock icon + window)
        setActivationPolicy(.regular)

        // Try to find and show an existing hidden NSWindow
        var shown = false
        if let windows = nsApp.perform(NSSelectorFromString("windows"))?.takeUnretainedValue() as? [AnyObject] {
            for window in windows {
                _ = window.perform(NSSelectorFromString("makeKeyAndOrderFront:"), with: nil)
                shown = true
            }
        }

        if !shown {
            // No windows at all -- request a new scene from UIKit
            UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
        }

        // Bring to front
        _ = nsApp.perform(NSSelectorFromString("activateIgnoringOtherApps:"), with: true as NSNumber)
        #endif
    }

    #if targetEnvironment(macCatalyst)

    /// Dynamically set NSApplication activation policy.
    /// - `.regular` (0): app appears in Dock, can have windows
    /// - `.accessory` (1): app does not appear in Dock
    private func setActivationPolicy(_ policy: ActivationPolicy) {
        guard let nsApp = getNSApp() else { return }

        typealias SetPolicyFunc = @convention(c) (AnyObject, Selector, Int) -> Bool
        let sel = NSSelectorFromString("setActivationPolicy:")
        guard let method = class_getInstanceMethod(type(of: nsApp), sel) else { return }
        let impl = method_getImplementation(method)
        let function = unsafeBitCast(impl, to: SetPolicyFunc.self)
        _ = function(nsApp, sel, policy.rawValue)
    }

    enum ActivationPolicy: Int {
        case regular = 0
        case accessory = 1
    }

    private func ensureAppKitLoaded() -> Bool {
        guard let appKitBundle = Bundle(path: "/System/Library/Frameworks/AppKit.framework"),
              appKitBundle.isLoaded || appKitBundle.load() else { return false }
        return true
    }

    func getNSApp() -> AnyObject? {
        guard let nsAppClass = NSClassFromString("NSApplication") else { return nil }
        return (nsAppClass as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue()
    }

    /// Called when all windows are closed -- hide from Dock but keep running.
    func windowsDidClose() {
        setActivationPolicy(.accessory)
    }
    #endif

    // MARK: - Launch at Login

    func toggleLaunchAtLogin() {
        #if targetEnvironment(macCatalyst)
        if #available(macCatalyst 16.0, *) {
            let service = SMAppService.mainApp
            do {
                if launchAtLogin {
                    try service.unregister()
                } else {
                    try service.register()
                }
                readLaunchAtLoginState()
            } catch {
                print("[RestyHome] Failed to toggle launch at login: \(error)")
            }
        }
        #endif
    }

    private func readLaunchAtLoginState() {
        #if targetEnvironment(macCatalyst)
        if #available(macCatalyst 16.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            statusBarController?.updateLaunchAtLoginState(launchAtLogin)
        }
        #endif
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        #if targetEnvironment(macCatalyst)
        statusBarController = StatusBarController(
            onShowWindow: { [weak self] in
                self?.showWindow()
            },
            onToggleLaunchAtLogin: { [weak self] in
                self?.toggleLaunchAtLogin()
            },
            onQuit: {
                exit(0)
            }
        )
        statusBarController?.setup()
        #endif
    }

    // MARK: - Cache Handling

    private func handleCacheRebuild() {
        homes = homeManager.homes.map { home in
            HomeInfo(
                id: home.uniqueIdentifier,
                name: home.name,
                isPrimary: home.isPrimary,
                accessoryCount: home.accessories.count,
                roomCount: home.rooms.count,
                sceneCount: home.actionSets.count
            )
        }

        statusText = String(localized: "status.loaded \(cache.homeCount) \(cache.totalAccessoryCount)")

        guard httpServer == nil else { return }
        httpServer = HTTPServer(cache: cache, port: Self.serverPort)
        httpServer?.start()
        isServerRunning = true
        serverAddress = "localhost:\(Self.serverPort)"
        statusText = String(localized: "status.listening \(serverAddress)")
    }
}

// MARK: - SceneDelegate

/// Tracks scene lifecycle. When the scene disconnects (window closed),
/// switches the app to accessory mode (no Dock icon) so it keeps running
/// in the menu bar only.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        #if targetEnvironment(macCatalyst)
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        guard let windowScene = scene as? UIWindowScene else { return }

        if !appDelegate.shouldShowWindow {
            // This is the automatic initial scene — hide it before it ever renders.
            // 1. Minimize the window scene size constraints so nothing appears.
            let geometryPrefs = UIWindowScene.GeometryPreferences.Mac(systemFrame: .zero)
            windowScene.requestGeometryUpdate(geometryPrefs) { _ in }

            // 2. Destroy the scene session on the next run loop tick.
            DispatchQueue.main.async {
                UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
            }

            // 3. Close any NSWindows that may have been created, via AppKit.
            DispatchQueue.main.async {
                guard let nsApp = appDelegate.getNSApp() else { return }
                if let windows = nsApp.perform(NSSelectorFromString("windows"))?.takeUnretainedValue() as? [AnyObject] {
                    for window in windows {
                        _ = window.perform(NSSelectorFromString("orderOut:"), with: nil)
                    }
                }
            }
            return
        }
        #endif
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        print("[SceneDelegate] Scene disconnected — hiding from Dock")
        #if targetEnvironment(macCatalyst)
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.shouldShowWindow = false
            appDelegate.windowsDidClose()
        }
        #endif
    }
}
