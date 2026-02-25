import Foundation
import UIKit

/// Bridges Mac Catalyst to AppKit for menu bar (NSStatusItem) support.
///
/// Since Mac Catalyst cannot directly `import AppKit`, this uses Objective-C
/// runtime functions to dynamically load AppKit classes and invoke methods.
/// This is the standard pattern used by Catalyst apps that need menu bar access.
///
/// On non-macOS platforms, all methods are no-ops.
final class StatusBarController: NSObject {

    private var statusItem: AnyObject?
    private var onShowWindow: (() -> Void)?
    private var onToggleLaunchAtLogin: (() -> Void)?
    private var onQuit: (() -> Void)?

    private var launchAtLoginMenuItem: AnyObject? // NSMenuItem

    init(
        onShowWindow: @escaping () -> Void,
        onToggleLaunchAtLogin: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onShowWindow = onShowWindow
        self.onToggleLaunchAtLogin = onToggleLaunchAtLogin
        self.onQuit = onQuit
        super.init()
    }

    // MARK: - Setup

    func setup() {
        #if targetEnvironment(macCatalyst)
        guard loadAppKit() else { return }

        guard let statusItem = createStatusItem() else {
            print("[StatusBar] Failed to create status item")
            return
        }
        self.statusItem = statusItem

        configureButton(of: statusItem)

        let menu = buildMenu()
        _ = statusItem.perform(sel("setMenu:"), with: menu)

        print("[StatusBar] Menu bar item created")
        #endif
    }

    /// Updates the checkmark on the "Launch at Login" menu item.
    func updateLaunchAtLoginState(_ enabled: Bool) {
        #if targetEnvironment(macCatalyst)
        guard let menuItem = launchAtLoginMenuItem else { return }

        // setState: takes NSControlStateValue (NSInteger), not an object.
        // We must call through the typed IMP to pass a primitive.
        typealias SetStateFunc = @convention(c) (AnyObject, Selector, Int) -> Void
        let stateSel = NSSelectorFromString("setState:")
        guard let method = class_getInstanceMethod(type(of: menuItem), stateSel) else { return }
        let impl = method_getImplementation(method)
        let function = unsafeBitCast(impl, to: SetStateFunc.self)
        function(menuItem, stateSel, enabled ? 1 : 0) // NSControlStateValueOn = 1, Off = 0
        #endif
    }

    // MARK: - AppKit Loading

    #if targetEnvironment(macCatalyst)

    private func loadAppKit() -> Bool {
        guard let bundle = Bundle(path: "/System/Library/Frameworks/AppKit.framework") else {
            print("[StatusBar] AppKit framework not found")
            return false
        }
        guard bundle.load() else {
            print("[StatusBar] Failed to load AppKit")
            return false
        }
        return true
    }

    // MARK: - Status Item Creation

    private func createStatusItem() -> AnyObject? {
        guard let nsStatusBar = NSClassFromString("NSStatusBar") else { return nil }

        // [NSStatusBar systemStatusBar]
        guard let systemBar = (nsStatusBar as AnyObject).perform(sel("systemStatusBar"))?.takeUnretainedValue() else {
            return nil
        }

        // NSVariableStatusItemLength = -2.0 on macOS
        // We use the helper: [NSStatusBar statusItemWithLength:]
        // But perform(_:with:) can't pass CGFloat primitives, so we use a different approach:
        // We call -statusItemWithLength: via NSInvocation or use the convenience approach.

        // Alternative: Use the value as an NSNumber and rely on the ObjC bridge.
        // Actually, for CGFloat args, perform(with:) won't work. Let's use objc_msgSend directly.

        typealias StatusItemFunc = @convention(c) (AnyObject, Selector, CGFloat) -> AnyObject
        let selector = sel("statusItemWithLength:")
        guard let method = class_getInstanceMethod(type(of: systemBar), selector) else {
            return nil
        }
        let impl = method_getImplementation(method)
        let function = unsafeBitCast(impl, to: StatusItemFunc.self)
        let item = function(systemBar, selector, -2.0) // NSVariableStatusItemLength

        return item
    }

    // MARK: - Button Configuration

    private func configureButton(of statusItem: AnyObject) {
        guard let button = statusItem.perform(sel("button"))?.takeUnretainedValue() else {
            return
        }

        // Create NSImage with SF Symbol
        guard let nsImageClass = NSClassFromString("NSImage") else { return }

        typealias ImageFunc = @convention(c) (AnyClass, Selector, NSString, NSString?) -> AnyObject?
        let imgSel = sel("imageWithSystemSymbolName:accessibilityDescription:")
        guard let imgMethod = class_getClassMethod(nsImageClass, imgSel) else { return }
        let imgImpl = method_getImplementation(imgMethod)
        let imgFunction = unsafeBitCast(imgImpl, to: ImageFunc.self)

        if let image = imgFunction(nsImageClass, imgSel, "house.fill" as NSString, "RestyHome" as NSString) {
            _ = button.perform(sel("setImage:"), with: image)
        }
    }

    // MARK: - Menu Construction

    private func buildMenu() -> AnyObject {
        guard let menuClass = NSClassFromString("NSMenu") as? NSObject.Type else {
            fatalError("[StatusBar] NSMenu not available")
        }

        let menu = menuClass.init()

        // Show Window
        addMenuItem(
            to: menu,
            title: localized("menu.show_window"),
            action: sel("showWindowAction:"),
            keyEquivalent: ""
        )

        addSeparator(to: menu)

        // Launch at Login
        let loginItem = addMenuItem(
            to: menu,
            title: localized("menu.launch_at_login"),
            action: sel("toggleLaunchAtLoginAction:"),
            keyEquivalent: ""
        )
        self.launchAtLoginMenuItem = loginItem

        addSeparator(to: menu)

        // Quit
        addMenuItem(
            to: menu,
            title: localized("menu.quit"),
            action: sel("quitAction:"),
            keyEquivalent: "q"
        )

        return menu
    }

    @discardableResult
    private func addMenuItem(to menu: AnyObject, title: String, action: Selector, keyEquivalent: String) -> AnyObject? {
        guard let menuItemClass = NSClassFromString("NSMenuItem") else { return nil }

        // +[NSMenuItem alloc] then -[NSMenuItem initWithTitle:action:keyEquivalent:]
        // We use perform() for alloc (returns an object), then typed IMP for the init.
        guard let allocated = (menuItemClass as AnyObject)
            .perform(sel("alloc"))?.takeUnretainedValue() else { return nil }

        typealias InitFunc = @convention(c) (AnyObject, Selector, NSString, Selector?, NSString) -> AnyObject
        let initSel = sel("initWithTitle:action:keyEquivalent:")
        guard let method = class_getInstanceMethod(menuItemClass, initSel) else { return nil }
        let impl = method_getImplementation(method)
        let function = unsafeBitCast(impl, to: InitFunc.self)
        let menuItem = function(allocated, initSel, title as NSString, action, keyEquivalent as NSString)

        _ = menuItem.perform(sel("setTarget:"), with: self)
        _ = menu.perform(sel("addItem:"), with: menuItem)

        return menuItem
    }

    private func addSeparator(to menu: AnyObject) {
        guard let menuItemClass = NSClassFromString("NSMenuItem") else { return }
        guard let separator = (menuItemClass as AnyObject).perform(sel("separatorItem"))?.takeUnretainedValue() else { return }
        _ = menu.perform(sel("addItem:"), with: separator)
    }

    /// Convenience for `NSSelectorFromString`.
    private func sel(_ name: String) -> Selector {
        NSSelectorFromString(name)
    }

    #endif

    // MARK: - Menu Actions

    @objc private func showWindowAction(_ sender: AnyObject?) {
        onShowWindow?()
    }

    @objc private func toggleLaunchAtLoginAction(_ sender: AnyObject?) {
        onToggleLaunchAtLogin?()
    }

    @objc private func quitAction(_ sender: AnyObject?) {
        onQuit?()
    }
}
