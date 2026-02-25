import SwiftUI

@main
struct RestyHomeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate)
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject private var appDelegate: AppDelegate

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            contentSection
            Divider()
            footerSection
        }
        .frame(minWidth: 380, minHeight: 300)
        .background(Color(.systemBackground))
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 8) {
            if let status = appDelegate.statusText {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            serverStatusBadge
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var serverStatusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(appDelegate.isServerRunning ? .green : .orange)
                .frame(width: 8, height: 8)

            Text(appDelegate.isServerRunning
                 ? String(localized: "server.status.running")
                 : String(localized: "server.status.stopped"))
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.fill.tertiary, in: Capsule())
    }

    // MARK: - Content

    private var contentSection: some View {
        Group {
            if appDelegate.homes.isEmpty {
                emptyState
            } else {
                homeList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "house.lodge")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("home.empty")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var homeList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(appDelegate.homes) { home in
                    HomeCard(home: home)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "network")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("api.footer \(appDelegate.serverAddress)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            #if targetEnvironment(macCatalyst)
            HStack {
                Toggle(isOn: Binding(
                    get: { appDelegate.launchAtLogin },
                    set: { _ in appDelegate.toggleLaunchAtLogin() }
                )) {
                    Text("menu.launch_at_login")
                        .font(.caption2)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Spacer()

                Text("app.hint.close_window")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            #endif
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
}

// MARK: - HomeCard

private struct HomeCard: View {
    let home: HomeInfo

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: home.isPrimary ? "house.fill" : "house")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(home.name)
                    .font(.headline)

                Text("home.summary \(home.accessoryCount) \(home.roomCount) \(home.sceneCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - HomeInfo (lightweight value type for the UI)

/// A lightweight, `Identifiable` snapshot of an `HMHome` for the SwiftUI layer.
/// Avoids passing mutable HomeKit objects into the view hierarchy.
struct HomeInfo: Identifiable {
    let id: UUID
    let name: String
    let isPrimary: Bool
    let accessoryCount: Int
    let roomCount: Int
    let sceneCount: Int
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppDelegate())
}
