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
        // Nothing alerts for what the window shows in front (#862).
        island.feed.windowShows = { [weak self] place in self?.chat.shows(place) ?? false }
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
        launched = true
        if !FirstLaunch.done {
            firstLaunch.show()
        } else if OpenedInvite.shared.invite != nil {
            // Opened by an oby://join link that came before this: its page instead of Home.
            chat.showSettings(.sphere)
        } else if !launchedAtLogin {
            chat.show(home: true)
        }
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

    /// Whether launching finished: an oby://join link before then waits for it.
    private var launched = false

    /// Whether macOS started Oby as a login item (Settings › General › Open at login). Read before
    /// launching finishes, while the launch's Apple event is still the current one.
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// A click on an alert opens the window on its job (the runner's, or one of this Mac's) or its
    /// conversation; an alert about nothing in particular opens the window. Its buttons and its Reply
    /// answer right there (#863), with the alert's own ids (`Alerts.answer`): the very ask it showed,
    /// never a newer one. Publish and a Confirm open the window, where Touch ID signs them. An answer
    /// that doesn't go through (asked elsewhere meanwhile, obid unreachable) opens the window on it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        let answer = Alerts.answer(response.actionIdentifier, typed: typed, info: info)
        let feed = island.model.feed
        do {
            switch answer {
            case .open(let place, let draft):
                island.model.publishing = nil
                return open(place, draft: draft)
            case .publish(let job):
                island.model.publishing = job
                return open(.job(job))
            case .permission(let job, let ask, let decision, let message): try await feed.answer(job, decision, message: message, ask: ask)
            case .tell(let job, let words, let said):
                // Waiting on something the alert didn't show now: words would answer that instead.
                guard feed.said(job) == said else { throw RunnerError(message: "It needs something else now.") }
                feed.apply(try await feed.about(job) { try await $0.tell(job, words) })
            case .settle(let item, let words): try await feed.settle(item, answer: words)
            case .say(let conversation, let words): try await feed.say(words, in: conversation)
            case .pick(let conversation?, let said, let question, let option):
                try await feed.say(Desk.answered(said, question: question, option: option), in: conversation)
            case .pick(nil, let said, let question, let option): island.desk.answer(option, said: said, question: question)
            }
        } catch {
            // The words typed wait in the box there.
            let words = typed.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Alerts.mostWords)) }
            open(Alerts.place(info), draft: words?.isEmpty == false ? words : nil)
        }
    }

    /// The window on `place`, with `draft` in its box when an alert's words couldn't go from there.
    private func open(_ place: AlertPlace, draft: String? = nil) {
        switch place {
        case .job(let id):
            if let draft { Drafts.keep(draft, as: Drafts.task(id)) }
            chat.show(job: (id: id, local: false))
        case .localJob(let id): chat.show(job: (id: id, local: true))
        case .conversation(let id):
            if let draft { Drafts.keep(draft, as: Drafts.conversation(id)) }
            chat.show(conversation: id)
        case .window:
            if let draft { Drafts.keep(draft, as: Drafts.home) }
            chat.show()
        }
    }

    /// Oby went behind another app: what waited for the owner while the window showed it alerts now.
    func applicationDidResignActive(_ notification: Notification) {
        island.feed.windowLeft()
    }

    /// `oby://join/<host>#…`, an Obysphere's join page's Open in Oby: Settings › Obysphere on the Join
    /// screen for that link, where you choose to join. Any other oby:// link does nothing. The link's
    /// secret is after the #: nothing here logs it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let invite = urls.lazy.compactMap(InviteLink.init(opened:)).first else { return }
        OpenedInvite.shared.invite = invite
        if launched { chat.showSettings(.sphere) }
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
        // The tunnel is obid's (#896): it keeps running; only the app's check-ins stop.
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
