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
            Button("Settings…") { SettingsSelection.open(.general) }
                .keyboardShortcut(",")
            Button("Show First Launch…") { app.firstLaunch.show() }
            Divider()
            // Updates (Mac/Updater.swift): the version, and Sparkle's window on demand.
            Text("Oby \(Updater.version)")
            Button("Check for Updates…") { app.island.updater.check() }
            Divider()
            Button("Quit Oby") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: .obyMenuBarIcon)
                .accessibilityLabel("Oby")
        }
        // The app menu, when a window of Oby's is up: Check for Updates… under About.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsSelection.open(.general) }.keyboardShortcut(",")
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { app.island.updater.check() }
            }
        }
    }
}

/// The Settings tabs, on the one the window's sidebar asked for (SettingsSelection).
private struct SettingsTabs: View {
    let app: AppDelegate
    private let selection = SettingsSelection.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: Binding { selection.tab } set: { selection.tab = $0 }) {
                Text("General").tag(SettingsTab.general)
                Text("Runner").tag(SettingsTab.runner)
                Text("Remote").tag(SettingsTab.remote)
                Text("Accounts").tag(SettingsTab.accounts)
                Text("Models").tag(SettingsTab.models)
                Text("Vault").tag(SettingsTab.vault)
                Text("About").tag(SettingsTab.about)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()
            Divider()
            Group {
                switch selection.tab {
                case .general: SettingsView(desk: app.island.desk)
                case .runner: RunnerSettingsView(feed: app.island.feed, availability: app.island.availability, remote: app.island.remote)
                case .remote: RemoteAccessSettingsView(remote: app.island.remote)
                case .accounts: AccountsSettingsView(store: app.island.desk.accounts, feed: app.island.feed)
                case .models: ModelsSettingsView(store: app.island.desk.accounts, feed: app.island.feed)
                case .vault: VaultSettingsView(vault: .shared)
                case .about: AboutSettingsView(updater: app.island.updater)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 640)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let island = IslandController()
    lazy var firstLaunch = FirstLaunch(island: island)
    /// The Oby window: the conversation, Agents and Live (#11).
    lazy var chat = ChatWindow(island: island)
    private var settingsWindow: NSWindow?

    /// The chat and notch use an explicit window: showSettingsWindow: no longer opens SwiftUI Settings.
    func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Oby Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsTabs(app: self))
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    override init() {
        UserDefaults.standard.register(defaults: AgentModels.defaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting the unit tests: no island, and no fight with the Oby that's already running.
        guard NSClassFromString("XCTestCase") == nil else { return }
        // A pipe to an agent that just exited must not take Oby down with it.
        SettingsSelection.shared.show = { [weak self] in self?.showSettings() }
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
        // Scheduled update checks (Mac/Updater.swift), in the build that ships. A Debug build from
        // Xcode checks only when asked, so a release never replaces it quietly.
        #if !DEBUG
        island.updater.start()
        #endif
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
        // The tunnel is Oby's child: it ends with Oby (Mac/RemoteAccess.swift).
        island.remote.stop()
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
