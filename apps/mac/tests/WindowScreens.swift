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

    func shoot(_ name: String, model: IslandModel, state: ChatState, sidebar: Bool = true) async throws {
        try await withPanel(open: sidebar) { try await picture(name, model: model, state: state) }
    }

    private func picture(_ name: String, model: IslandModel, state: ChatState) async throws {
        // Oby itself, from the app's bundled character, once it has drawn.
        let character = ObyCharacter(query: "embed&size=1.23")
        let window = ChatWindow.make(ChatView(model: model, state: state, character: character))
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        defer { window.close() }
        ChatWindow.measureLights(window, into: state)
        for _ in 0..<50 where !character.ready { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(1200))
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
        try await shoot("mac-home", model: model(), state: ChatState())
    }

    @Test func homeWithThePanelClosed() async throws {
        try await shoot("mac-home-closed", model: model(), state: ChatState(), sidebar: false)
    }

    @Test func group() async throws {
        let state = ChatState()
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
        let state = ChatState()
        state.trail.start(.talk)
        try await shoot("mac-convo", model: model, state: state)
    }

    @Test func task() async throws {
        let state = ChatState()
        state.trail.start(.group(.review), .job(id: "r2", local: false))
        try await shoot("mac-task", model: model(), state: state)
    }

    /// The talk key's pill with the window closed (#528), at each stage of a turn.
    @Test(arguments: [TalkStage.listening, .thinking, .speaking])
    func pill(_ stage: TalkStage) async throws {
        let model = model()
        model.turn = stage
        let pill = TalkPillPanel(model: model)
        pill.place()
        pill.orderFrontRegardless()
        defer { pill.close() }
        try await Task.sleep(for: .milliseconds(500))
        try await save("mac-pill-\(stage.word.lowercased())", window: pill)
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
                    SetRow("Speak replies to spoken requests") { Toggle("Speak replies", isOn: .constant(true)).toggleStyle(.set) }
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

    /// Each Settings page in the window (docs/mac-design.md A1), with the side panel on Settings.
    /// Nothing of this Mac's own shows: run it with `TEST_RUNNER_OBY_HOME` set to an empty folder (the
    /// desk's accounts and rules), and the pages read a defaults suite of their own, a made-up Oby
    /// account and a vault in a temporary folder.
    @Test(arguments: SettingsPage.allCases)
    func settings(_ page: SettingsPage) async throws {
        let suite = try #require(UserDefaults(suiteName: "oby-screens-\(UUID().uuidString)"))
        suite.set(true, forKey: "ObySidebarOpen")
        suite.set(Double(Tokens.sidebar), forKey: "ObySidebarWidth")
        suite.set(true, forKey: RunnerFeed.thisMacKey)
        suite.set("you@example.com", forKey: "remote.email")
        suite.set("oby-7f3k.example.com", forKey: "remote.hostname")
        let secrets = FileManager.default.temporaryDirectory.appending(path: "oby-screens-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: secrets) }
        let vault = Vault(store: FileVault(folder: secrets))
        for name in ["figma-token", "sentry-dsn", "staging-api-key"] { try vault.add("made-up-value", as: name) }

        let model = model()
        model.remote = RemoteAccess(secrets: FileVault(folder: secrets), defaults: suite)
        model.vault = vault
        let state = ChatState()
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

    @Test func taskNeedingYou() async throws {
        let state = ChatState()
        state.trail.start(.group(.review), .job(id: "r1", local: false))
        try await shoot("mac-task-needs", model: model(), state: state)
    }
}
