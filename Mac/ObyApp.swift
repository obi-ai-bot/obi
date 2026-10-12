import SwiftUI
import UserNotifications

@main
struct ObyApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            // The window with the conversation, Agents and Live (Mac/App/ChatWindow.swift); the island opens on hover or click.
            Button("Open Oby") { app.chat.show() }
                .keyboardShortcut("o")
            // The same keys work from any app (Mac/StopAllKey.swift).
            Button("Stop All Jobs") { app.island.stopAll() }
                .keyboardShortcut(".", modifiers: [.control, .option, .command])
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Button("Show First Launch…") { app.firstLaunch.show() }
            Divider()
            Button("Quit Oby") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: .obyMenuBarIcon)
                .accessibilityLabel("Oby")
        }

        Settings {
            SettingsTabs(app: app)
        }
    }
}

/// The Settings tabs, on the one the window's sidebar asked for (SettingsSelection).
private struct SettingsTabs: View {
    let app: AppDelegate
    private let selection = SettingsSelection.shared

    var body: some View {
        TabView(selection: Binding { selection.tab } set: { selection.tab = $0 }) {
            SettingsView(desk: app.island.desk).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            RunnerSettingsView(feed: app.island.feed).tabItem { Label("Runner", systemImage: "server.rack") }.tag(SettingsTab.runner)
            AccountsSettingsView(store: app.island.desk.accounts, feed: app.island.feed).tabItem { Label("Accounts", systemImage: "person.2") }.tag(SettingsTab.accounts)
            ModelsSettingsView(feed: app.island.feed).tabItem { Label("Models", systemImage: "cpu") }.tag(SettingsTab.models)
            VaultSettingsView(vault: .shared).tabItem { Label("Vault", systemImage: "lock") }.tag(SettingsTab.vault)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let island = IslandController()
    lazy var firstLaunch = FirstLaunch(island: island)
    /// The Oby window: the conversation, Agents and Live (#11).
    lazy var chat = ChatWindow(island: island)

    override init() {
        UserDefaults.standard.register(defaults: AgentModels.defaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting the unit tests: no island, and no fight with the Oby that's already running.
        guard NSClassFromString("XCTestCase") == nil else { return }
        // A pipe to an agent that just exited must not take Oby down with it.
        signal(SIGPIPE, SIG_IGN)
        Task.detached { _ = Shell.environment }
        // One Oby at a time: a second launch quietly leaves the first one in charge.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        guard others.isEmpty else { NSApp.terminate(nil); return }
        // Before the island starts, so a click on an alert that launched Oby still arrives.
        UNUserNotificationCenter.current().delegate = self
        RunnerFeed.registerCategories()
        island.openWindow = { [weak self] job in self?.chat.show(job: job) }
        island.start()
        if !FirstLaunch.done { firstLaunch.show() }
    }

    /// A click on a runner's alert opens the island on its job; its Publish starts publishing there.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo[RunnerFeed.jobKey] as? String else { return }
        island.open(job: id, publish: response.actionIdentifier == RunnerFeed.publishButton)
    }

    /// While Oby runs (always, in the menu bar), the alert still shows, so it isn't missed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func applicationWillTerminate(_ notification: Notification) {
        island.desk.quit()
    }
}

extension NSImage {
    /// Sangam's menu bar icon: the soft block with two eyes, as a template image.
    static let obyMenuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3, width: 15, height: 12.1), xRadius: 5, yRadius: 5).fill()
            context.compositingOperation = .clear
            for x in [4.9, 11.1] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 8, width: 2, height: 3.8), xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
