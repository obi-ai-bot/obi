import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

/// No Dispatch card (#269): the work the brain plans starts as it's planned and joins Oby's turn,
/// with nothing to tap; a plan rules guessed waits in the inbox as Start/Cancel and starts nothing
/// by itself; `POST /v1/plans` answers the jobs it started; `POST /v1/jobs` takes a whole job, and
/// a draft's id from before is gone.
@MainActor
struct NoDispatchCardTests {
    let folder: URL
    let desk: Desk
    let brain: ConversationTests.FakeBrain
    let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]

    /// The brain's plan for "fix oby #12", with a line of its own.
    static let fix12 = #"{"action":"dispatch","reply":"On it: fixing #12 in oby.","question":null,"jobs":[],"dispatches":[{"agent":"auto","account":"auto","repo":"deskree-inc/oby","base_branch":null,"pr":null,"issue":12,"epic":null,"kind":"fix","title":"Login screen","task":"Fix #12","inputs":[],"rounds":1,"check":null,"complexity":"routine"}]}"#
    /// Two jobs from one message, with no line of the brain's: Oby says what started.
    static let twoJobs = #"{"action":"dispatch","reply":"","question":null,"jobs":[],"dispatches":[{"agent":"auto","account":"auto","repo":"deskree-inc/oby","base_branch":null,"pr":null,"issue":12,"epic":null,"kind":"fix","title":"Login screen","task":"Fix #12","inputs":[],"rounds":1,"check":null,"complexity":"routine"},{"agent":"auto","account":"auto","repo":"deskree-inc/oby","base_branch":null,"pr":33,"issue":null,"epic":null,"kind":"review","title":null,"task":"Review PR #33","inputs":[],"rounds":1,"check":null,"complexity":"routine"}]}"#

    init() throws {
        folder = try temporaryFolder()
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max · well@example.com", for: "default")
        desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        desk.prepare = { $0 }
        desk.makeAgent = { _, _, _ in ConversationTests.IdleAgent() }
        desk.issueFiles = { _, issue in issue == 12 ? ["iOS/Home.swift"] : nil }
        brain = ConversationTests.FakeBrain([Self.fix12])
        desk.makeBrain = { [brain] (_: String?, _: String?, _: Vault) in [brain] }
    }

    func until(_ what: String, tries: Int = 2000, _ condition: () -> Bool) async throws {
        // MacTests can run alongside the runner suite; allow its main actor to observe the
        // deliberately blocked read even when the host is busy.
        for _ in 0..<tries where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: what))
    }

    /// A dispatch plan enqueues its jobs as it's made, routed, with their issues' files and the
    /// request's attachments, and links them to Oby's turn: no tap, and nothing in the inbox.
    @Test func aPlanStartsItsJobsAndLinksThemToTheTurn() async throws {
        brain.plans = [Self.twoJobs]
        desk.ask("fix oby #12 and review PR 33", attachments: ["/tmp/shot.png"])
        try await until("the reply comes") { if case .reply = desk.talk { true } else { false } }
        let turn = try #require(desk.turns.last)
        #expect(turn.who == .oby)
        #expect(turn.text == "On it. Claude Code is fixing oby #12 (Login screen) on Default, and Claude Code is reviewing oby PR #33 on Default.")
        #expect(desk.talk == .reply(turn.text))
        let started = (turn.jobs ?? []).compactMap(desk.job)
        #expect(started.map(\.issue) == [12, nil] && started.map(\.pr) == [nil, 33])
        #expect(started.map(\.branch) == ["oby/fix-12", "oby/review-33"] && started.map(\.account) == ["default", "default"])
        #expect(started.first?.title == "Login screen" && started.first?.files == ["iOS/Home.swift"])
        #expect(started.map(\.attachments) == [["/tmp/shot.png"], ["/tmp/shot.png"]])
        #expect(desk.inbox.isEmpty && JobStore(url: folder.appending(path: "oby.sqlite")).conversation().last?.jobs == started.map(\.id))
        try await until("they run") { started.allSatisfy { desk.job($0.id)?.status == .running } }

        // The brain's own line, when it gave one.
        brain.plans = [Self.fix12]
        desk.ask("fix oby #12")
        try await until("the brain's line comes") { desk.turns.last?.text == "On it: fixing #12 in oby." }
        #expect(desk.turns.last?.jobs?.count == 1 && desk.jobs.count == 3)
    }

    /// A turn cancelled, or given up on, while the plan's jobs were being made (the issues' files
    /// take network time) starts nothing and asks nothing: `live` is checked again right before.
    @Test func aCancelledOrLateTurnStartsNothing() async throws {
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var state = (reading: false, open: false, finishedReads: 0)

            var reading: Bool {
                lock.lock(); defer { lock.unlock() }
                return state.reading
            }

            var open: Bool {
                get {
                    lock.lock(); defer { lock.unlock() }
                    return state.open
                }
                set {
                    lock.lock(); defer { lock.unlock() }
                    state.open = newValue
                }
            }

            func markReading() {
                lock.lock(); defer { lock.unlock() }
                state.reading = true
            }

            func markNotReading() {
                lock.lock(); defer { lock.unlock() }
                state.reading = false
                state.finishedReads += 1
            }

            var finishedReads: Int {
                lock.lock(); defer { lock.unlock() }
                return state.finishedReads
            }
        }
        let gate = Gate()
        desk.issueFiles = { [gate] _, _ in
            gate.markReading()
            defer { gate.markNotReading() }
            while !gate.open { try? await Task.sleep(for: .milliseconds(10)) }
            return ["iOS/Home.swift"]
        }
        desk.ask("fix oby #12")
        try await until("the files are being read") { gate.reading }
        desk.cancel()
        gate.open = true
        try await until("the plan is dead") { brain.answered.count == 1 }
        try await until("the cancelled file read finishes") { gate.finishedReads == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(desk.jobs.isEmpty && desk.inbox.isEmpty && desk.turns.isEmpty && desk.talk == .none)

        // Past its time while the files are still being read: the turn ends with "didn't answer
        // in time", and the plan, when the files come, starts nothing.
        gate.open = false
        // Leave enough time for the plan to reach the blocked read before the timeout: under load
        // (the whole suite, a Mac check) it took over 3 seconds, the turn gave up first, and the
        // read never came.
        desk.patience = .seconds(8)
        brain.plans = [Self.fix12]
        desk.ask("fix oby #12")
        try await until("the files are being read again") { gate.reading }
        #expect(desk.talk == .thinking("fix oby #12"))
        try await until("the turn gives up", tries: 1200) { desk.talk == .reply(Conversation.timedOut) }
        gate.open = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(desk.jobs.isEmpty && desk.inbox.isEmpty && desk.turns.count == 2 && desk.turns.last?.jobs == nil)
        // A rules-only acting guess is refused before it can start anything.
        brain.plans = ["not a plan"]
        desk.ask("fix oby #12")
        try await until("the rules guess is refused") { desk.talk == .reply("Oby couldn't think that through: say it again") }
        gate.open = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(desk.jobs.isEmpty && desk.inbox.isEmpty)
    }

    /// The permission mode the user named ("plan first", #134) goes with the job a plan starts;
    /// without one, Settings' default. `POST /v1/jobs` takes one too, and refuses any other.
    @Test func startedJobsKeepTheirMode() async throws {
        brain.plans = [Self.fix12.replacingOccurrences(of: #""complexity":"routine"}"#, with: #""complexity":"routine","mode":"plan"}"#), Self.fix12]
        _ = await desk.converse("fix oby #12, plan first")
        #expect(desk.jobs.first?.mode == .plan)
        _ = await desk.converse("fix oby #12")
        #expect(desk.jobs.first?.mode == desk.defaultMode && desk.jobs.count == 2)

        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { [owner] client in
            func post(_ body: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                try await client.execute(uri: "/v1/jobs", method: .post, headers: owner, body: ByteBuffer(string: body)) { response in
                    (response.status, (try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]) ?? [:])
                }
            }
            let (status, started) = try await post(#"{"job": {"repo": "deskree-inc/oby", "kind": "fix", "task": "Fix #12", "issue": 12, "mode": "acceptEdits"}}"#)
            #expect(status == .created && started["mode"] as? String == "acceptEdits")
            let (_, defaulted) = try await post(#"{"job": {"repo": "deskree-inc/oby", "kind": "fix", "task": "Fix #12", "issue": 12}}"#)
            #expect(defaulted["mode"] as? String == desk.defaultMode.rawValue)
            #expect(try await post(#"{"job": {"repo": "deskree-inc/oby", "kind": "fix", "task": "Fix #12", "mode": "sometimes"}}"#).0 == .unprocessableContent)
        }
    }

    /// When no brain answers, rules cannot guess an acting plan: the reply refuses it and nothing
    /// starts or waits in the inbox.
    @Test func aRulesGuessAsksBeforeAnythingStarts() async throws {
        brain.plans = ["not a plan"]
        let talk = await desk.converse("fix oby #12")
        #expect(talk == .reply("Oby couldn't think that through: say it again"))
        #expect(desk.jobs.isEmpty && desk.inbox.isEmpty && desk.turns.last?.jobs == nil)
    }

    /// `POST /v1/plans` answers the jobs it started, in full, with `drafts` empty; `POST /v1/jobs`
    /// takes a whole job, checked like a plan, and answers `410` to a draft's id from before.
    @Test func theAPIAnswersTheJobsItStartedAndRefusesDrafts() async throws {
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { [owner, desk] client in
            func post(_ path: String, _ body: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                try await client.execute(uri: path, method: .post, headers: owner, body: ByteBuffer(string: body)) { response in
                    (response.status, (try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]) ?? [:])
                }
            }
            let (status, plan) = try await post("/v1/plans", #"{"said": "fix oby #12"}"#)
            #expect(status == .ok && plan["kind"] as? String == "reply" && plan["text"] as? String == "On it: fixing #12 in oby.")
            let jobs = try #require(plan["jobs"] as? [[String: Any]])
            #expect(jobs.count == 1 && jobs.first?["issue"] as? Int == 12 && jobs.first?["status"] as? String == "queued")
            #expect(jobs.first?["files"] as? [String] == ["iOS/Home.swift"] && jobs.first?["title"] as? String == "Login screen")
            #expect((plan["drafts"] as? [Any])?.isEmpty == true)
            let id = try #require(jobs.first?["id"] as? String)
            #expect(desk.turns.last?.jobs == [id])

            // A draft's id, from a client from before: gone, and told where to go.
            let (gone, error) = try await post("/v1/jobs", #"{"job": {"id": "\#(id)", "branch": "oby/fix-12", "account": "default"}}"#)
            #expect(gone == .gone && (error["error"] as? String)?.hasPrefix("Oby starts planned work by itself now") == true)
            #expect(try await post("/v1/jobs", #"{"job": {"repo": "deskree-inc/oby"}}"#).0 == .unprocessableContent)

            // A whole job: routed, checked like a plan, with what the client set.
            let (created, started) = try await post("/v1/jobs", #"{"job": {"repo": "deskree-inc/oby", "kind": "review", "task": "Review PR 33", "pr": 33, "title": "Cards review", "account": "Default", "rounds": 3, "check": "swift test", "model": "claude-fable-5-1", "files": ["Engine/Desk.swift"]}}"#)
            #expect(created == .created, "\(started)")
            #expect(started["kind"] as? String == "review" && started["pr"] as? Int == 33 && started["title"] as? String == "Cards review")
            #expect(started["account"] as? String == "default" && started["agent"] as? String == "claude" && started["branch"] as? String == "oby/review-33")
            #expect(started["rounds"] as? Int == 3 && started["check"] as? String == "swift test" && started["model"] as? String == "claude-fable-5-1")
            #expect(started["files"] as? [String] == ["Engine/Desk.swift"] && started["status"] as? String == "queued")

            // What a plan would be refused for, this is: an unknown repository or kind, a path
            // outside the repository, a model the tool hasn't, an account there isn't.
            for body in [#"{"job": {"repo": "deskree-inc/nope", "kind": "fix", "task": "x"}}"#,
                         #"{"job": {"repo": "deskree-inc/oby", "kind": "deploy", "task": "x"}}"#,
                         #"{"job": {"repo": "deskree-inc/oby", "kind": "fix", "task": "x", "files": ["/etc/passwd"]}}"#,
                         #"{"job": {"repo": "deskree-inc/oby", "kind": "fix", "task": "x", "model": "gpt-6-astra"}}"#,
                         #"{"job": {"repo": "deskree-inc/oby", "kind": "fix", "task": "x", "account": "Nobody"}}"#,
                         #"{"job": {"repo": "deskree-inc/oby", "kind": "fix", "task": "x", "branch": "-rf"}}"#] {
                #expect(try await post("/v1/jobs", body).0 == .unprocessableContent, Comment(rawValue: body))
            }
        }
        try await until("both run") { desk.jobs.filter { $0.status == .running }.count == 2 }
        #expect(desk.jobs.count == 2)
    }
}
