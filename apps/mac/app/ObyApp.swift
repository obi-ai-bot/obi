import ApplicationServices
import SwiftUI
import UserNotifications

@main
struct ObyApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            // What's working and what needs you, in the words Home on the iPhone uses.
            Text(app.island.model.summary)
            Divider()
            // The window with the conversation, Agents and Live (apps/mac/app/App/ChatWindow.swift).
            Button("Open Oby") { app.chat.show() }
                .keyboardShortcut("o")
            // The drag-to-select overlay (apps/mac/app/Snapshot.swift); the screenshot goes with your next message.
            Button("Show Oby Your Screen…") { app.showScreen() }
            // The same keys work from any app (apps/mac/app/StopAllKey.swift).
            Button("Stop All Agents") { app.island.stopAll() }
                .keyboardShortcut(".", modifiers: [.control, .option, .command])
            // First launch was skipped or Accessibility refused: fn does nothing until it's allowed.
            if !AXIsProcessTrusted() {
                Button("To Talk With fn, Allow Accessibility…") { Task { await Permissions().ask(.accessibility) } }
            }
            // Settings are pages in the window (docs/mac-design.md A1).
            Button("Settings…") { app.chat.showSettings() }
                .keyboardShortcut(",")
            Button("Show First Launch…") { app.firstLaunch.show() }
            Divider()
            // Updates (apps/mac/app/Updater.swift): the version, and Sparkle's window on demand.
            Text("Oby \(Updater.version)")
            // An update is downloaded: Restart installs it and relaunches, after this Mac's check if one runs.
            if let pill = app.island.model.updater.pill {
                Button(pill) { app.island.model.updater.install() }
                    .disabled(app.island.model.updater.waiting)
            }
            Button("Check for Updates…") { app.island.updater.check() }
            Divider()
            Button("Quit Oby") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            MenuBarLabel(model: app.island.model)
        }
        // Oby is a regular app (#528): with its window in front, the menu bar is Oby's own — the app menu
        // (About, Check for Updates…, Settings…, Hide, Quit), Edit, View, Window and Help, SwiftUI's
        // standard ones, which the composer's Undo, Cut, Copy and Paste go through.
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { app.island.updater.check() }
            }
            // ⌘, opens the window on Settings, with no Settings window of its own.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { app.chat.showSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}

/// Oby's icon, and beside it how many agents are working or need you (nothing when none do).
struct MenuBarLabel: View {
    let model: IslandModel

    var body: some View {
        let count = model.working + model.needsYou
        HStack(spacing: 3) {
            Image(nsImage: .obyMenuBarIcon)
            if count > 0 { Text("\(count)").monospacedDigit() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.label(working: model.working, needsYou: model.needsYou))
    }

    /// "Oby", or "Oby: 2 working, 1 needs you".
    static func label(working: Int, needsYou: Int) -> String {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if needsYou > 0 { parts.append(needsYou == 1 ? "1 needs you" : "\(needsYou) need you") }
        return parts.isEmpty ? "Oby" : "Oby: " + parts.joined(separator: ", ")
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
        // Hosting the unit tests: no desk, and no fight with the Oby that's already running.
        guard NSClassFromString("XCTestCase") == nil else { return }
        // A pipe to an agent that just exited must not take Oby down with it.
        signal(SIGPIPE, SIG_IGN)
        Task.detached { _ = Shell.environment }
        // One Oby at a time: a second launch quietly leaves the first one in charge.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        guard others.isEmpty else { NSApp.terminate(nil); return }
        // Before the desk starts, so a click on an alert that launched Oby still arrives.
        UNUserNotificationCenter.current().delegate = self
        RunnerFeed.registerCategories()
        island.openWindow = { [weak self] job in self?.chat.show(job: job) }
        island.windowShowsTalk = { [weak self] in self.map { $0.chat.showsTalk || $0.firstLaunch.isOpen } ?? false }
        island.windowShowsConversation = { [weak self] in self?.chat.showsConversation ?? false }
        // A dropped runner is tried again within seconds while the window shows.
        island.feed.windowOpen = { [weak self] in self?.chat.isOpen ?? false }
        island.start()
        // obid as This Mac's engine: the Swift runner an older build registered goes, and the
        // engine is registered when nothing else serves this Mac (apps/mac/app/LoginItem.swift).
        RunnerLoginItem().reconcile(onThisMac: UserDefaults.standard.bool(forKey: RunnerFeed.thisMacKey))
        // Outside Applications (opened from the disk image or Downloads): no engine, no updates.
        if !RunnerLoginItem.mayRegister() { askToMoveToApplications() }
        // Scheduled update checks (apps/mac/app/Updater.swift), in the build that ships. A Debug build from
        // Xcode checks only when asked, so a release never replaces it quietly.
        #if !DEBUG
        if RunnerLoginItem.mayRegister() { island.updater.start() }
        #endif
        // Opened by hand (Finder, Spotlight, the Dock, `open`), Oby comes up in front with its window, as
        // any Mac app does; started at login, it waits in the menu bar.
        if !FirstLaunch.done { firstLaunch.show() } else if !launchedAtLogin { chat.show(home: true) }
    }

    /// Sangam's design has no screen for this, so a plain alert (apps/mac/app/LoginItem.swift, `mayRegister`).
    private func askToMoveToApplications() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Oby to Applications"
        alert.informativeText = RunnerLoginItem.moveToApplications
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    /// Whether macOS started Oby as a login item (Settings › General › Open at login). Read before
    /// launching finishes, while the launch's Apple event is still the current one.
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// A click on an alert opens the window on its job (the runner's, or one of this Mac's); the runner's
    /// Publish starts publishing there. An alert about nothing in particular opens the window.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let id = info[RunnerFeed.jobKey] as? String {
            // Allow or Deny right in the alert, on the very ask it showed; otherwise the job opens.
            if let ask = info[RunnerFeed.permissionKey] as? String,
               [RunnerFeed.allowButton, RunnerFeed.denyButton].contains(response.actionIdentifier) {
                let decision: RunnerPermission.Decision = response.actionIdentifier == RunnerFeed.allowButton ? .allow : .deny
                if (try? await island.model.feed.answer(id, decision, ask: ask)) != nil { return }
            }
            island.model.publishing = response.actionIdentifier == RunnerFeed.publishButton ? id : nil
            chat.show(job: (id: id, local: false))
        } else if let id = info[IslandController.localJobKey] as? String {
            chat.show(job: (id: id, local: true))
        } else {
            chat.show()
        }
    }

    /// Clicking Oby's Dock icon, or opening it again (Spotlight, Finder, `open`), while it runs opens its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopen() }
        return true
    }

    /// What a reopen does with no window up: the window opens (tests count it instead).
    lazy var reopen: () -> Void = { [unowned self] in chat.show() }

    /// Closing the window leaves Oby running: the talk key, its pill and the menu bar icon carry on.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Show Oby your screen with the window closed: the overlay, then the window opens on the conversation with the screenshot attached.
    func showScreen() {
        Task {
            await island.model.tray.screenshot()
            chat.show()
        }
    }

    /// While Oby runs (always, in the menu bar), the alert still shows, so it isn't missed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The tunnel is Oby's child: it ends with Oby (apps/mac/app/RemoteAccess.swift).
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
