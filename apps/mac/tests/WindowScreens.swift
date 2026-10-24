import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Oby

/// Pictures of the window for a pull request, against Sangam's design: off unless `OBY_SCREENS`
/// names a folder (`TEST_RUNNER_OBY_SCREENS=… xcodebuild test -only-testing:MacTests/WindowScreens`),
/// with a shell taking each picture as its window's number lands in `windows.txt` there.
/// The window is the real one (ChatWindow.make, its title bar and toolbar), with made-up jobs on a
/// feed that talks to no runner, so no one's work is in the pictures.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OBY_SCREENS"] != nil))
struct WindowScreens {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OBY_SCREENS"] ?? NSTemporaryDirectory())
    let now = Date.now

    func job(_ id: String, _ title: String, kind: Plan.Kind = .build, status: Job.Status, issue: Int? = nil, ago: TimeInterval,
             repo: String = "deskree-inc/oby", agent: String = "claude", question: Bool = false) -> Job {
        var job = Job(id: id, request: title, agent: agent, account: "deskree", repo: repo, branch: "oby/\(id)", base: "dev",
                      pr: nil, kind: kind, task: title, created: now - ago)
        job.status = status
        job.title = title
        job.issue = issue
        if question { job.question = Plan.Question(text: "Post this review as you?", options: ["Post review", "Read it first"]) }
        if status == .running && !question { job.step = "Reading src/queue/retry.ts" }
        if status == .done || status == .failed { job.finished = now - ago + 600 }
        return job
    }

    /// The scene: a few reviews, issues and tasks, some needing you.
    func model() -> IslandModel {
        let feed = RunnerFeed()
        let jobs = [
            job("r1", "#251 settings layout", kind: .review, status: .running, ago: 3600, question: true),
            job("r2", "#412 retry jitter", kind: .review, status: .running, ago: 1080, repo: "deskree-inc/tetrix-ee"),
            job("r3", "#398 graph test", kind: .review, status: .done, ago: 9000),
            job("r4", "#405 usage meter", kind: .review, status: .done, ago: 12000),
            job("i1", "Search ignores accents", status: .running, issue: 488, ago: 2400, question: true),
            job("i2", "#251 Attention queue", status: .running, issue: 251, ago: 900, agent: "codex"),
            job("i3", "Flaky timezone test", status: .done, issue: 470, ago: 20000),
            job("t1", "Dark mode flashes on launch", status: .queued, ago: 300),
            job("t2", "Bump Sparkle to 2.9.6", status: .done, ago: 30000),
        ]
        for job in jobs.reversed() { feed.apply(job) }
        return IslandModel(desk: Desk(), feed: feed, availability: MacAvailability())
    }

    /// Opens the window on `state`, lets it settle, and saves what's on it as `name`.png.
    /// The panel's settings live in the app's own defaults (the test host is the app): set for a
    /// picture, then put back as they were.
    func withPanel(open: Bool, _ work: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard, keys = ["ObySidebarOpen", "ObySidebarWidth"]
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set(open, forKey: "ObySidebarOpen")
        defaults.set(Double(Tokens.sidebar), forKey: "ObySidebarWidth")
        try await work()
    }

    /// `hover`: where the pointer rests for the picture, from the window's top left.
    func shoot(_ name: String, model: IslandModel, state: ChatState, sidebar: Bool = true, hover: CGPoint? = nil) async throws {
        try await withPanel(open: sidebar) { try await picture(name, model: model, state: state, hover: hover) }
    }

    private func picture(_ name: String, model: IslandModel, state: ChatState, hover: CGPoint? = nil) async throws {
        // Oby itself, from the app's bundled character, once it has drawn.
        let character = ObyCharacter(query: "embed&size=1.23")
        let window = ChatWindow.make(ChatView(model: model, state: state, character: character))
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        defer { window.close() }
        ChatWindow.measureLights(window, into: state)
        for _ in 0..<50 where !character.ready { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(1200))
        if let hover, let height = window.contentView?.bounds.height,
           let moved = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: hover.x, y: height - hover.y), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 0, pressure: 0) {
            window.sendEvent(moved)
            try await Task.sleep(for: .milliseconds(500))
        }
        try await save(name, window: window)
    }

    /// Names the window in `windows.txt` and waits for the shell's picture of it.
    private func save(_ name: String, window: NSWindow) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "\(name).png")
        // The test host has no Screen Recording, so it names the window and the shell that ran the
        // tests takes the picture (`screencapture -l`), watching `windows.txt`.
        let list = folder.appending(path: "windows.txt")
        let line = Data("\(name) \(window.windowNumber)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: list) { handle.seekToEndOfFile(); handle.write(line); try handle.close() }
        else { try line.write(to: list) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(200)) }
        #expect(FileManager.default.fileExists(atPath: file.path), "screencapture made no \(name).png")
    }

    @Test func home() async throws {
        try await shoot("mac-home", model: model(), state: ChatState(defaults: .scratch))
    }

    @Test func homeWithThePanelClosed() async throws {
        try await shoot("mac-home-closed", model: model(), state: ChatState(defaults: .scratch), sidebar: false)
    }

    @Test func group() async throws {
        let state = ChatState(defaults: .scratch)
        state.trail.start(.group(.review))
        try await shoot("mac-group", model: model(), state: state)
    }

    @Test func conversation() async throws {
        let model = model()
        let turns = [
            Turn(id: "t1", date: now - 600, who: .user, text: "Ernesto asked you to review tetrix-ee #412."),
            Turn(id: "t2", date: now - 590, who: .oby, text: "On it. Claude Code has it in tetrix-ee on Deskree.", jobs: ["r2"]),
            Turn(id: "t3", date: now - 420, who: .user, text: "focus on the jitter math, I trust the rest"),
            Turn(id: "t4", date: now - 410, who: .oby, text: "Got it. Claude Code is starting with `src/queue/retry.ts`.\n\n- the backoff cap\n- the jitter range", jobs: ["i2"]),
        ]
        for turn in turns { model.feed.conversation.apply(turn) }
        var ask = InboxItem(id: "q1", kind: .question, job: "i2", title: "#251 Attention queue",
                            text: "Should a job that commits nothing end as failed, or get a new status?", options: ["Failed", "A new status"], created: now - 300)
        ask.details = ["It ends as failed and shows under Needs you.", "A new status: Empty, which needs nothing from you."]
        model.feed.apply(ask)
        let state = ChatState(defaults: .scratch)
        state.trail.start(.talk)
        try await shoot("mac-convo", model: model, state: state)
    }

    /// Oby at work on an answer: its face melted into bouncing dots (Sangam's ObyFaceLive), over
    /// "Working" and the tool line it's on.
    @Test func conversationAtWork() async throws {
        let model = model()
        model.feed.conversation.apply(Turn(id: "w1", date: now - 20, who: .user, text: "Why does the iOS build fail?"))
        model.feed.conversation.apply(TurnStep(turn: "w1", index: 0, action: "tool", text: "Reading the log", state: .running,
                                               tool: "read", detail: ".github/workflows/ios.yml"))
        let state = ChatState(defaults: .scratch)
        state.trail.start(.talk)
        try await shoot("mac-convo-working", model: model, state: state, sidebar: false)
    }

    /// Oby starting work, as Claude Code does: the job's card is under your words the moment it
    /// starts, still at work on its answer, and a follow-up told from a task's page goes with that
    /// task's card, under Sangam's line.
    @Test func conversationStartingWork() async throws {
        let model = model()
        model.feed.conversation.apply(Turn(id: "s1", date: now - 900, who: .user, text: "the timezone test is flaky again, fix it"))
        model.feed.conversation.apply(Turn(id: "s2", date: now - 890, who: .oby, text: "On it. Claude Code is fixing #470 in oby on Deskree.", jobs: ["i3"]))
        var follow = job("f1", "Follow-up: Flaky timezone test", status: .running, ago: 120)
        follow.followUpOf = "i3"
        follow.step = "Reading Tests/ScheduleTests.swift"
        model.feed.apply(follow)
        model.feed.conversation.apply(Turn(id: "s3", date: now - 20, who: .user, text: "Dark mode flashes on launch, fix it"))
        model.feed.conversation.apply(TurnStep(turn: "s3", index: 0, action: "tool", text: "Starting a job", state: .done,
                                               tool: "oby_dispatch", detail: "deskree-inc/oby"))
        var started = job("t3", "Dark mode flashes on launch", status: .running, ago: 10)
        started.step = "Getting ready"
        model.feed.apply(started, extras: RunnerJobExtras(id: "t3", turn: "s3"))
        let state = ChatState(defaults: .scratch)
        state.trail.start(.talk)
        try await shoot("mac-convo-starting", model: model, state: state, sidebar: false)
    }

    /// Your GitHub work (`GET /v1/github/work`): Review PR with what waits for your review and your
    /// own pull request, beside the jobs already on it.
    @Test func gitHubReview() async throws {
        let model = model()
        model.feed.apply(gitHub())
        let state = ChatState()
        state.trail.start(.group(.review))
        try await shoot("mac-github-review", model: model, state: state)
    }

    /// Issues while obid's gh isn't signed in: Connect GitHub first.
    @Test func gitHubConnect() async throws {
        let model = model()
        model.feed.apply(GitHubWork(signedIn: false))
        let state = ChatState()
        state.trail.start(.group(.issues))
        try await shoot("mac-github-connect", model: model, state: state)
    }

    func gitHub() -> GitHubWork {
        GitHubWork(signedIn: true, login: "well-prado", items: [
            .init(id: "a1", list: .reviews, repo: "deskree-inc/tetrix-ee", number: 389, title: "webhook fix", url: "https://github.com/deskree-inc/tetrix-ee/pull/389",
                  author: "Ernesto", updated: now - 1500),
            .init(id: "a2", list: .reviews, repo: "deskree-inc/tetrix-front-end", number: 405, title: "usage meters", url: "https://github.com/deskree-inc/tetrix-front-end/pull/405",
                  author: "Daniel", updated: now - 7000, known: false),
            .init(id: "a3", list: .mine, repo: "deskree-inc/oby", number: 700, title: "Pair a device sends you to Remote access",
                  url: "https://github.com/deskree-inc/oby/pull/700", author: "well-prado", updated: now - 3000, reviewDecision: "CHANGES_REQUESTED", checks: "SUCCESS"),
            .init(id: "a4", list: .assigned, repo: "deskree-inc/oby", number: 640, title: "Clear done keeps a merged job", url: "https://github.com/deskree-inc/oby/issues/640",
                  author: "well-prado", updated: now - 4000),
        ])
    }

    /// A kind's page with the owner's shape of work (2026-10-21): 9 pull requests waiting for review,
    /// 51 issues assigned on the roadmap's columns, jobs running and done. `open` false leaves only
    /// the done jobs, so Issues and Review PR open on To do.
    func busy(open: Bool) -> IslandModel {
        let model = model()
        if !open {
            for (id, title, kind) in [("r1", "#251 settings layout", Plan.Kind.review), ("r2", "#412 retry jitter", .review), ("i1", "Search ignores accents", .build),
                                      ("i2", "#251 Attention queue", .build), ("t1", "Dark mode flashes on launch", .build)] {
                model.feed.apply(job(id, title, kind: kind, status: .done, issue: id.hasPrefix("i") ? 488 : nil, ago: 7200))
            }
        }
        for n in 0..<8 { model.feed.apply(job("d\(n)", "Done issue \(470 - n)", status: .done, issue: 470 - n, ago: 4000 + Double(n) * 3000)) }
        model.feed.apply(GitHubWork.busy(now: now))
        return model
    }

    /// The page with the To do, Running and Completed tabs (#794, #814), on each tab.
    @Test(arguments: ["issues-running", "issues-todo", "review-todo", "tasks-done"])
    func tasksPage(_ screen: String) async throws {
        let state = ChatState(defaults: .scratch)
        state.trail.start(.group(screen.hasPrefix("issues") ? .issues : screen.hasPrefix("review") ? .review : .tasks))
        try await shoot("mac-tasks-\(screen)", model: busy(open: screen.hasSuffix("running")), state: state)
    }

    /// The pointer on Issues' name in the side panel: the name lit as a link (the owner's addition, 2026-10-21).
    @Test func sidebarNameHovered() async throws {
        try await shoot("mac-sidebar-name-hover", model: busy(open: true), state: ChatState(defaults: .scratch), hover: CGPoint(x: 88, y: 342))
    }

    /// Home with the owner's work, the side panel open: the ways to the page.
    @Test func homeBusy() async throws {
        try await shoot("mac-home-busy", model: busy(open: true), state: ChatState(defaults: .scratch))
    }

    @Test func task() async throws {
        let state = ChatState(defaults: .scratch)
        state.trail.start(.group(.review), .job(id: "r2", local: false))
        try await shoot("mac-task", model: model(), state: state)
    }

    /// Archived (Sangam's ArchiveView): done tasks older than Archive completed's 3 days, with the
    /// side panel's Archived row at its foot.
    @Test func archived() async throws {
        let model = model()
        let day: TimeInterval = 86_400
        for old in [job("a1", "Webhook signature mismatch", status: .done, issue: 377, ago: 5 * day),
                    job("a2", "Job progress screen", status: .done, ago: 7 * day, agent: "codex"),
                    job("a3", "#388 Retry banner overlaps", kind: .review, status: .done, ago: 4 * day),
                    job("a4", "Weekly repo health", status: .done, ago: 10 * day)] { model.feed.apply(old) }
        let state = ChatState(defaults: .scratch)
        state.trail.start(.archived)
        try await shoot("mac-archived", model: model, state: state)
    }

    /// A task's page renaming it in place in the title bar (Sangam's `crumb-rename`).
    @Test func taskRenaming() async throws {
        let state = ChatState(defaults: .scratch)
        state.trail.start(.job(id: "i3", local: false))
        state.renaming = .init(id: SidebarSections.JobRow.id("i3", local: false), inBar: true)
        try await shoot("mac-task-rename", model: model(), state: state)
    }

    /// The talk key's pill with the window closed (#528), at each stage of a turn: Oby's reply in writing.
    @Test(arguments: [TalkStage.listening, .thinking, .replied])
    func pill(_ stage: TalkStage) async throws {
        let model = model()
        model.turn = stage
        if stage == .replied { model.reply = "The vault tests pass on dev. Two were slow; I opened a task to look at them." }
        let pill = TalkPillPanel(model: model)
        pill.place()
        pill.orderFrontRegardless()
        defer { pill.close() }
        try await Task.sleep(for: .milliseconds(500))
        try await save("mac-pill-\(stage)", window: pill)
    }

    /// Sangam's Settings building blocks (apps/shared/SettingsComponents.swift), on made-up settings:
    /// each control on and off, a meter at each fullness, the buttons.
    @Test func settingsComponents() async throws {
        let sheet = ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SetGroup("Runner", footer: "The runner is Oby's login item on this Mac, and Oby follows it on 127.0.0.1.") {
                    SetRow("Runner") { SetSegmented("Runner", selection: .constant(true), options: [(true, "This Mac"), (false, "Remote")]) }
                    SetRow("Status") { SetValue("Connected", connected: true) }
                    SetRow("URL") { SetField("Runner URL", text: .constant(""), prompt: "http://tetrix-lab:8790") }
                }
                SetGroup("Voice") {
                    SetRow("Keep my Mac available") { Toggle("Keep my Mac available", isOn: .constant(false)).toggleStyle(.set) }
                    SetRow("Speech language") { SetSelect("Speech language", selection: .constant("system"), options: [("system", "Mac language"), ("en-US", "English")]) }
                }
                SetGroup("Claude Code") {
                    ForEach([("Deskree", 36.0), ("Personal", 84.0), ("Team", 96.0)], id: \.0) { name, used in
                        SetRow(controlOnTop: true) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name)
                                SetAbout("Paid by Deskree · Resets Thursday")
                                SetMeter(used: used).padding(.top, 4)
                            }
                        } control: {
                            SetValue("\(Int(used))% used")
                            Button("Remove", role: .destructive) {}.buttonStyle(.set)
                        }
                    }
                }
                SetGroup("Add an account") {
                    SetRow("Name") { SetField("Account name", text: .constant("Personal"), prompt: "Personal") }
                    SetRow("Nothing yet", quiet: true)
                    SetRow("") { Button("Add Account") {}.buttonStyle(.set) }
                    SetRow("") { Button("Add Account") {}.buttonStyle(.set).disabled(true) }
                }
            }
            .frame(maxWidth: Tokens.column).padding(.horizontal, Tokens.gutter).padding(.top, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Tokens.bg)
        let window = ChatWindow.make(sheet, size: NSSize(width: 700, height: 1080))
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(800))
        try await save("mac-settings-components", window: window)
    }

    /// Each Settings page in the window (docs/mac-design.md A1), with the side panel on Settings; the
    /// pages the launch build hides with `showEverything` on.
    /// Nothing of this Mac's own shows: run it with `TEST_RUNNER_OBY_HOME` set to an empty folder (the
    /// desk's accounts and rules), and the pages read a defaults suite of their own, a made-up
    /// hostname and a vault in a temporary folder.
    @Test(arguments: SettingsPage.allCases)
    func settings(_ page: SettingsPage) async throws {
        let suite = try #require(UserDefaults(suiteName: "oby-screens-\(UUID().uuidString)"))
        if !SettingsPage.shown(everything: false).contains(page) { suite.set(true, forKey: Launch.everythingKey) }
        suite.set(true, forKey: "ObySidebarOpen")
        suite.set(Double(Tokens.sidebar), forKey: "ObySidebarWidth")
        suite.set(true, forKey: RunnerFeed.thisMacKey)
        suite.set("oby-7f3k.example.com", forKey: "remote.hostname")
        let secrets = FileManager.default.temporaryDirectory.appending(path: "oby-screens-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: secrets) }
        let vault = Vault(store: FileVault(folder: secrets))
        for name in ["figma-token", "sentry-dsn", "staging-api-key"] { try vault.add("made-up-value", as: name) }

        let model = model()
        model.remote = RemoteAccess(secrets: FileVault(folder: secrets), defaults: suite)
        model.vault = vault
        let state = ChatState(defaults: .scratch)
        state.openSettings(page)
        let character = ObyCharacter(query: "embed&size=1.23")
        let window = ChatWindow.make(ChatView(model: model, state: state, character: character).defaultAppStorage(suite),
                                     size: NSSize(width: 994, height: 900))
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        defer { window.close() }
        ChatWindow.measureLights(window, into: state)
        try await Task.sleep(for: .milliseconds(1500))
        try await save("mac-settings-\(page.rawValue)", window: window)
    }

    /// Settings › Accounts and Models with obid on this Mac (docs/mac-design.md C1, B2, C2): made-up
    /// accounts and models staged on the feed, no runner asked. Home's box with its gauge after them.
    @Test(arguments: ["accounts", "models", "home"])
    func obid(_ screen: String) async throws {
        let suite = try #require(UserDefaults(suiteName: "oby-screens-\(UUID().uuidString)"))
        suite.set(true, forKey: "ObySidebarOpen")
        suite.set(Double(Tokens.sidebar), forKey: "ObySidebarWidth")
        func account(_ id: String, _ agent: String, _ name: String, week: Double?, fiveHour: Double? = nil, signedIn: Bool = true,
                     running: Int = 0, tetrix: Bool? = nil) -> AccountState {
            AccountState(account: Account(id: id, agent: agent, name: name, payer: "", home: nil), label: nil,
                         fiveHour: fiveHour, sevenDay: week, fiveHourResets: now + 7200, sevenDayResets: now + 3 * 86_400,
                         running: running, tetrix: tetrix, runnerSignedIn: signedIn)
        }
        let model = model()
        let efforts = ["low", "medium", "high", "xhigh", "max"]
        model.feed.stage(
            accounts: [account("personal", "claude", "Personal", week: 0.36, running: 1, tetrix: true),
                       account("deskree", "claude", "Deskree", week: 0.84, fiveHour: 0.86, tetrix: true),
                       account("lab", "codex", "Lab", week: 0.12),
                       account("spare", "cursor", "Spare", week: nil, signedIn: false)],
            models: ModelSettings(claude: ModelChoice(model: "claude-opus-5-5", effort: "xhigh"), codex: ModelChoice(model: "gpt-6.1-sol", effort: "high"),
                                  cursor: CursorModelChoice(model: "auto")),
            options: ModelOptions(claude: .init(models: [.init(id: "claude-opus-5-5", name: "Opus 5.5"), .init(id: "claude-sonnet-5-5", name: "Sonnet 5.5")], efforts: efforts),
                                  codex: .init(models: [.init(id: "gpt-6.1-sol", name: "gpt-6.1-sol", efforts: ["low", "medium", "high", "xhigh"])]),
                                  cursor: .init(models: [.init(id: "claude-opus-5-5", name: "Opus 5.5")])))
        let state = ChatState(defaults: .scratch)
        if let page = SettingsPage(rawValue: screen) { state.openSettings(page) }
        let character = ObyCharacter(query: "embed&size=1.23")
        let window = ChatWindow.make(ChatView(model: model, state: state, character: character).defaultAppStorage(suite),
                                     size: NSSize(width: 994, height: 900))
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        defer { window.close() }
        ChatWindow.measureLights(window, into: state)
        for _ in 0..<50 where !character.ready { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(1500))
        try await save("mac-obid-\(screen)", window: window)
    }

    /// Tetrix held by obid for every agent (Settings › Connectors, ready and connected; Accounts'
    /// "used in" lines; a job's Tetrix section): staged on the feed, no runner asked.
    @Test(arguments: ["connectors-ready", "connectors-on", "accounts", "task"])
    func tetrix(_ screen: String) async throws {
        let suite = try #require(UserDefaults(suiteName: "oby-screens-\(UUID().uuidString)"))
        // The launch build hides Tetrix (`Launch`).
        suite.set(true, forKey: Launch.everythingKey)
        suite.set(true, forKey: "ObySidebarOpen")
        suite.set(Double(Tokens.sidebar), forKey: "ObySidebarWidth")
        let dogfood = TetrixStatus.Server(preset: "dogfood", name: "Tetrix Dogfood", url: URL(string: "https://mcp.tetrix.dev/mcp")!)
        func account(_ id: String, _ agent: String, _ name: String, week: Double, jobs: Int, used: Int) -> AccountState {
            AccountState(account: Account(id: id, agent: agent, name: name, payer: "", home: nil), label: nil, sevenDay: week,
                         sevenDayResets: now + 3 * 86_400, tetrix: true, tetrixJobs: jobs, tetrixUsed: used, runnerSignedIn: true)
        }
        let model = model()
        model.feed.stage(accounts: [account("personal", "claude", "Personal", week: 0.36, jobs: 12, used: 9),
                                    account("deskree", "codex", "Deskree", week: 0.62, jobs: 4, used: 4)],
                         models: ModelSettings(claude: ModelChoice(model: "claude-opus-5-5", effort: "xhigh"), codex: ModelChoice(model: "gpt-6.1-sol", effort: "high"),
                                               cursor: CursorModelChoice(model: "auto")),
                         options: ModelOptions(claude: .init(models: [], efforts: []), codex: .init(models: []), cursor: .init(models: [])))
        let on = screen != "connectors-ready"
        var report = RunnerJobExtras(id: "r3")
        report.tetrix = TetrixJobReport(connected: true, calls: ["search_entities": 2, "get_entity": 1, "save_session": 1], context: true,
                                        saved: ["ses_8f2a"],
                                        gaps: .init(noResults: ["deskree-inc/tetrix-ee#398"], unknownFiles: ["src/graph/fixtures.ts"],
                                                    sent: now, session: "ses_c41d"))
        model.feed.stage(tetrix: on ? TetrixStatus(connected: true, url: dogfood.url, preset: "dogfood", presets: [dogfood])
                                    : TetrixStatus(presets: [dogfood]),
                         lists: Connectors.Lists(plugins: [], connections: nil, gitHub: GitHubLogin(gh: true, signedIn: true, user: "you", signIn: nil)),
                         extras: ["r3": report])
        let state = ChatState()
        if screen == "task" { state.trail.start(.group(.review), .job(id: "r3", local: false)) }
        else { state.openSettings(screen == "accounts" ? .accounts : .connectors) }
        let character = ObyCharacter(query: "embed&size=1.23")
        let window = ChatWindow.make(ChatView(model: model, state: state, character: character).defaultAppStorage(suite),
                                     size: NSSize(width: 994, height: 900))
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        defer { window.close() }
        ChatWindow.measureLights(window, into: state)
        for _ in 0..<50 where !character.ready { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(1500))
        try await save("mac-tetrix-\(screen)", window: window)
    }

    /// Settings › Connectors as this Mac had it on 2026-10-20 (Sangam's SettingsView.tsx `Connectors`): obid
    /// on this Mac with Claude Code's Personal and Deskree and Codex's default login, while the Mac's own
    /// accounts.json names the same logins under other ids; Tetrix and GitHub connected. Made up, no runner asked.
    @Test func connectors() async throws {
        let suite = try #require(UserDefaults(suiteName: "oby-screens-\(UUID().uuidString)"))
        // Every row, as the launch build hides all but GitHub and Slack (`Launch`).
        suite.set(true, forKey: Launch.everythingKey)
        suite.set(true, forKey: "ObySidebarOpen")
        suite.set(Double(Tokens.sidebar), forKey: "ObySidebarWidth")
        let root = FileManager.default.temporaryDirectory.appending(path: "oby-screens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mac = [Account(id: "default", agent: "claude", name: "Personal", payer: "", home: nil),
                   Account(id: "32203c5b", agent: "claude", name: "Deskree", payer: "", home: root.appending(path: "accounts/32203c5b").path),
                   Account(id: "codex-default", agent: "codex", name: "Deskree", payer: "", home: nil)]
        try JSONEncoder().encode(mac).write(to: root.appending(path: "accounts.json"))
        func account(_ id: String, _ agent: String, _ name: String) -> AccountState {
            AccountState(account: Account(id: id, agent: agent, name: name, payer: "", home: nil), label: nil, tetrix: true, runnerSignedIn: true)
        }
        let feed = RunnerFeed()
        feed.stage(accounts: [account("default", "claude", "Personal"), account("deskree", "claude", "Deskree"), account("codex", "codex", "Codex")],
                   models: ModelSettings(claude: ModelChoice(model: "claude-opus-5-5", effort: "xhigh"), codex: ModelChoice(model: "gpt-6.1-sol", effort: "high"),
                                         cursor: CursorModelChoice(model: "auto")),
                   options: ModelOptions(claude: .init(models: [], efforts: []), codex: .init(models: []), cursor: .init(models: [])))
        let dogfood = TetrixStatus.Server(preset: "dogfood", name: "Tetrix Dogfood", url: URL(string: "https://mcp.tetrix.dev/mcp")!)
        feed.stage(tetrix: TetrixStatus(connected: true, url: dogfood.url, preset: "dogfood", presets: [dogfood]),
                   lists: Connectors.Lists(plugins: [], connections: nil, gitHub: GitHubLogin(gh: true, signedIn: true, user: "you", signIn: nil)))
        let desk = Desk(accounts: AccountStore(root: root), store: JobStore(url: root.appending(path: "oby.sqlite")))
        let model = IslandModel(desk: desk, feed: feed, availability: MacAvailability())
        let state = ChatState(defaults: .scratch)
        state.openSettings(.connectors)
        let character = ObyCharacter(query: "embed&size=1.23")
        let window = ChatWindow.make(ChatView(model: model, state: state, character: character).defaultAppStorage(suite),
                                     size: NSSize(width: 994, height: 900))
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        defer { window.close() }
        ChatWindow.measureLights(window, into: state)
        for _ in 0..<50 where !character.ready { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(1500))
        try await save("mac-connectors", window: window)
    }

    @Test func taskNeedingYou() async throws {
        let state = ChatState(defaults: .scratch)
        state.trail.start(.group(.review), .job(id: "r1", local: false))
        try await shoot("mac-task-needs", model: model(), state: state)
    }
}
