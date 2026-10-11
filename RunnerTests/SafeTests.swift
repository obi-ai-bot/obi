import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

// F3, safe when nobody is watching (#7): Stop all, the secret scan on encoded copies and on
// everything Oby posts, and every outgoing action in the job's report.

/// Fake secrets, built at runtime so this file holds no line the scan would flag, plain or encoded.
enum Fake {
    static let aws = "AKIA" + "ABCDEFGHIJKLMNOP"
    static let github = "ghp" + "_" + String(repeating: "aB3dE6", count: 6)
    static let password = "password" + " = \"" + "hunter2hunter2hunter2" + "\""

    static func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
    static func base64URL(_ text: String) -> String {
        base64(text).replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
    static func hex(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined() }
    static func percent(_ text: String) -> String { text.utf8.map { String(format: "%%%02X", $0) }.joined() }
}

struct EncodedSecretTests {
    @Test func base64HexAndURLEncodedCopiesAreCaught() {
        #expect(Publish.matches("let token = \"\(Fake.base64(Fake.aws))\"") == ["AWS access key, base64"])
        #expect(Publish.matches("token: \(Fake.base64URL("token " + Fake.github))") == ["GitHub token, base64"])
        #expect(Publish.matches("key=0x\(Fake.hex(Fake.aws))") == ["AWS access key, hex"])
        #expect(Publish.matches("key=\(Fake.hex(Fake.aws).uppercased())") == ["AWS access key, hex"])
        #expect(Publish.matches("https://example.com/?q=\(Fake.percent(Fake.password))") == ["password or secret, URL-encoded"])
        // Encoded twice: hex inside base64.
        #expect(Publish.matches("blob \(Fake.base64(Fake.hex(Fake.aws)))") == ["AWS access key, hex in base64"])
        // A plain match is named plainly, once.
        #expect(Publish.matches("key \(Fake.aws)") == ["AWS access key"])
    }

    @Test func ordinaryCodeIsClean() {
        let clean = [
            "let publishOnItsOwnAgainAndAgain = PublishStep.pullRequest",
            "\"revision\" : \"17dfa72e3c1d1f0a9b8c7d6e5f4a3b2c1d0e9f8a\",",
            "image: data:image/png;base64,\(Fake.base64("a picture of Oby in the notch, nothing else"))",
            "https://github.com/deskree-inc/oby/pull/80?tab=files%20changed",
            "let id = \"9f08fd10\" // \(UUID().uuidString)",
        ]
        for line in clean { #expect(Publish.matches(line).isEmpty, Comment(rawValue: line)) }
    }

    @Test func aDiffNamesTheFileAndLineOfAnEncodedKey() {
        let diff = """
            diff --git a/Engine/Keys.swift b/Engine/Keys.swift
            --- a/Engine/Keys.swift
            +++ b/Engine/Keys.swift
            @@ -10,2 +10,3 @@
             import Foundation
            +let key = "\(Fake.base64(Fake.aws))"
             // end
            """
        #expect(Publish.findings(inDiff: diff) == [Publish.Finding(file: "Engine/Keys.swift", line: 11, rule: "AWS access key, base64")])
    }

    @Test func aCommentOrReviewReplyWithAKeyIsBlocked() async throws {
        let reply = "### Oby review\n\nThanks.\nThe config has \(Fake.hex(Fake.github)) in it.\n"
        let findings = try await Review.scan(reply)
        #expect(findings.contains(Publish.Finding(file: "review", line: 4, rule: "GitHub token, hex")))
        #expect(try await Review.scan("### Oby review\n\nLooks right.\n\nVERDICT: APPROVED").isEmpty)
    }

    /// The pull request's title and description are scanned too: an agent's summary can carry a key.
    @Test func thePullRequestsTextIsScanned() async throws {
        var leaky = job
        leaky.kind = .fix
        leaky.summaries = ["Fixed the login.\nUsed \(Fake.aws) to test it."]
        let body = Publish.body(for: leaky)
        let line = try #require(body.split(separator: "\n", omittingEmptySubsequences: false).firstIndex { $0.contains(Fake.aws) }) + 1
        let findings = try await Publish.scan(texts: [("pull request title", "fix: the login"), ("pull request description", body),
                                                      ("commit message", "fix: the login\n\nkey \(Fake.base64(Fake.aws))")])
        #expect(findings.contains(Publish.Finding(file: "pull request description", line: line, rule: "AWS access key")))
        #expect(findings.contains(Publish.Finding(file: "commit message", line: 3, rule: "AWS access key, base64")))
        #expect(!findings.contains { $0.file == "pull request title" })
        #expect(Publish.blocked(by: findings).hasPrefix("Not published: possible secret in pull request description:\(line) (AWS access key)"))
    }
}

/// Stop all: every agent ends within 2 seconds, and nothing half-done goes out.
@MainActor
final class StopAllTests {
    /// An agent whose events the test sends, counting stops.
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var stopped = 0
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws { self.onEvent = onEvent }
        func send(_ text: String) {}
        func end() {}
        func stop() { stopped += 1 }
        func kill() {}
    }

    let folder: URL
    let desk: Desk
    let agent = Agent()
    let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]

    init() throws {
        folder = try temporaryFolder()
        desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.makeAgent = { [agent] _, _, _ in agent }
        desk.prepare = { $0 }
        desk.countCommits = { _, _ in 1 }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func running(_ id: String) async throws {
        var work = job
        work.id = id
        work.kind = .fix
        work.pr = nil
        work.issue = 7
        work.base = "dev"
        work.branch = "oby/fix-7-\(id)"
        desk.dispatch(Desk.Draft(said: "work on oby #7", reply: "", job: work, guessed: false))
        for _ in 0..<500 where desk.job(id)?.status != .running { try await Task.sleep(for: .milliseconds(10)) }
        agent.onEvent(.session("s-\(id)"))
    }

    /// The agent says it's done: the job counts its commits and starts publishing.
    func finishing(_ id: String) async throws {
        agent.onEvent(.turnEnded(summary: "fix: the thing", failed: false))
        agent.onEvent(.finished(summary: "fix: the thing", failed: false))
    }

    func waitUntilEnded(_ id: String) async throws {
        for _ in 0..<500 where desk.job(id)?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theRunnerStopsEveryJob() async throws {
        try await running("one")
        try await running("two")
        let app = Application(router: API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json"))).router(owner: "well@example.com"))
        try await app.test(.router) { [owner] client in
            try await client.execute(uri: "/v1/stop-all", method: .post, headers: owner) { response in
                #expect(response.status == .ok)
                let answer = object(Data(response.body.readableBytesView))
                #expect(answer["stopped"] as? Int == 2)
                let jobs = answer["jobs"] as? [[String: Any]] ?? []
                #expect(Set(jobs.compactMap { $0["id"] as? String }) == ["one", "two"])
                #expect(jobs.allSatisfy { $0["status"] as? String == "stopped" })
            }
            try await client.execute(uri: "/v1/stop-all", method: .post, headers: owner) { response in
                let answer = object(Data(response.body.readableBytesView))
                #expect(answer["stopped"] as? Int == 0 && (answer["jobs"] as? [Any])?.isEmpty == true)
            }
        }
        #expect(desk.active.isEmpty && agent.stopped == 2)
    }

    /// Stopped after the push and before the pull request: the pull request isn't opened, and the
    /// push that did go out is in the report.
    @Test func stoppedWhilePublishingSendsNothingMore() async throws {
        let (pushed, pushedDone) = AsyncStream<Void>.makeStream()
        let (stopped, stoppedDone) = AsyncStream<Void>.makeStream()
        final class Seen { var pullRequest = false; var refused: (any Error)? }
        let seen = Seen()
        desk.publishOnItsOwn = { job, _, hooks in
            try hooks.proceed()
            hooks.sent(Outgoing(action: .push, repo: job.repo, id: "1a2b3c4d5e", branch: job.branch))
            pushedDone.finish()
            for await _ in stopped {}
            do {
                try hooks.proceed()
            } catch {
                seen.refused = error
                throw error
            }
            seen.pullRequest = true
            return URL(string: "https://github.com/deskree-inc/oby/pull/80")!
        }
        try await running("half")
        try await finishing("half")
        for await _ in pushed {}
        #expect(desk.stopAll() == 1)
        stoppedDone.finish()
        try await Task.sleep(for: .milliseconds(100))

        let ended = try #require(desk.job("half"))
        #expect(ended.status == .stopped && ended.published == nil)
        #expect(!seen.pullRequest && seen.refused is Publish.Stopped)
        #expect(ended.outgoing?.map(\.action) == [.push])
        #expect(ended.sentLines == "Sent by Oby:\n- Pushed 1a2b3c4 to oby/fix-7-half in deskree-inc/oby")
    }

    /// Stopped before the push: nothing goes out at all.
    @Test func stoppedBeforeThePushSendsNothing() async throws {
        let (scanned, scannedDone) = AsyncStream<Void>.makeStream()
        let (stopped, stoppedDone) = AsyncStream<Void>.makeStream()
        desk.publishOnItsOwn = { job, _, hooks in
            scannedDone.finish()
            for await _ in stopped {}
            try hooks.proceed()
            hooks.sent(Outgoing(action: .push, repo: job.repo, id: "1a2b3c4d5e", branch: job.branch))
            return URL(string: "https://github.com/deskree-inc/oby/pull/80")!
        }
        try await running("early")
        try await finishing("early")
        for await _ in scanned {}
        desk.stopAll()
        stoppedDone.finish()
        try await Task.sleep(for: .milliseconds(100))
        let ended = try #require(desk.job("early"))
        #expect(ended.status == .stopped && ended.published == nil && ended.outgoing == nil)
    }

    /// A job that publishes as usual lists the push and the pull request, and the API says so.
    @Test func everyOutgoingActionIsInTheReport() async throws {
        desk.publishOnItsOwn = { job, _, hooks in
            try hooks.proceed()
            hooks.sent(Outgoing(action: .push, repo: job.repo, id: "1a2b3c4d5e", branch: job.branch))
            try hooks.proceed()
            hooks.sent(Outgoing(action: .pullRequest, repo: job.repo, id: "https://github.com/deskree-inc/oby/pull/80"))
            return URL(string: "https://github.com/deskree-inc/oby/pull/80")!
        }
        try await running("sent")
        try await finishing("sent")
        try await waitUntilEnded("sent")
        let ended = try #require(desk.job("sent"))
        #expect(ended.status == .done && ended.published == "https://github.com/deskree-inc/oby/pull/80")
        #expect(ended.sentLines == """
            Sent by Oby:
            - Pushed 1a2b3c4 to oby/fix-7-sent in deskree-inc/oby
            - Opened pull request https://github.com/deskree-inc/oby/pull/80
            """)
        let json = object(try API.encode(JobJSON(job: ended)))
        let outgoing = json["outgoing"] as? [[String: Any]] ?? []
        #expect(outgoing.compactMap { $0["action"] as? String } == ["push", "pullRequest"])
        #expect(outgoing.first?["id"] as? String == "1a2b3c4d5e" && outgoing.first?["branch"] as? String == "oby/fix-7-sent")
        // Nothing sent yet: an empty list, never missing.
        #expect((object(try API.encode(JobJSON(job: job)))["outgoing"] as? [Any])?.isEmpty == true)
    }

    /// Publishing by hand is for a job that has ended: its push goes on, and is in the report too.
    @Test func publishingByHandGoesOnAndIsReported() async throws {
        desk.publishOnItsOwn = { _, _, _ in throw Shell.Failure(message: "Couldn't push oby/fix-7-hand: the remote hung up.") }
        try await running("hand")
        try await finishing("hand")
        try await waitUntilEnded("hand")
        #expect(desk.job("hand")?.canPublish == true && desk.job("hand")?.outgoing == nil)
        desk.publishByHand = { job, _, approve, hooks in
            try await approve("Push it.")
            try hooks.proceed()
            hooks.sent(Outgoing(action: .push, repo: job.repo, id: "9f8e7d6c5b", branch: job.branch))
            try hooks.proceed()
            hooks.sent(Outgoing(action: .pullRequestEdit, repo: job.repo, id: "https://github.com/deskree-inc/oby/pull/80"))
            return URL(string: "https://github.com/deskree-inc/oby/pull/80")!
        }
        try await desk.publish("hand") { _ in }
        let published = try #require(desk.job("hand"))
        #expect(published.published == "https://github.com/deskree-inc/oby/pull/80")
        #expect(published.outgoing?.map(\.line) == ["Pushed 9f8e7d6 to oby/fix-7-hand in deskree-inc/oby",
                                                     "Updated the description of https://github.com/deskree-inc/oby/pull/80"])
    }
}

/// Halt: an agent that ignores SIGTERM, and what it started, still end within Stop all's 2 seconds.
@MainActor
struct HaltTests {
    @Test func anAgentThatIgnoresTermEndsWithinTwoSeconds() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = folder.appending(path: "child.pid")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; sleep 30 & echo $! > '\(child.path)'; wait"]
        try process.run()
        for _ in 0..<200 where (try? String(contentsOf: child, encoding: .utf8))?.isEmpty ?? true { try await Task.sleep(for: .milliseconds(10)) }
        let sleeper = try #require(Int32((try String(contentsOf: child, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))

        // As ClaudeAgent.stop and CodexAgent.stop do: the grace, then Halt.
        let start = ContinuousClock.now
        let leads = getpgid(process.processIdentifier) == process.processIdentifier
        try await Task.sleep(for: .seconds(Halt.grace))
        Halt.end(process)
        for _ in 0..<200 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!process.isRunning)
        #expect(ContinuousClock.now - start < .seconds(2))
        // What it started ends too, when it leads its own process group.
        if leads {
            for _ in 0..<100 where kill(sleeper, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(kill(sleeper, 0) != 0)
        }
        _ = kill(sleeper, SIGKILL)
    }

    /// On Linux agents run in bubblewrap (no --die-with-parent): Halt reaches inside the box too.
    @Test func anAgentInBubblewrapEndsWithWhatItStarted() async throws {
        // Only where bubblewrap can make its box (user namespaces allowed), as on the runner.
        let box = ["bwrap", "--unshare-pid", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc"]
        guard (try? await Shell.run(box + ["true"]))?.status == 0 else { return }
        let mark = "31.\(Int.random(in: 100_000...999_999))"
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/bwrap")
        process.arguments = box.dropFirst() + ["sh", "-c", "trap '' TERM; sleep \(mark) & wait"]
        try process.run()
        // The box, the shell in it, and the sleep it started: every one names the mark.
        func alive() async -> Bool { (try? await Shell.run(["pgrep", "-f", "sleep \(mark)"]))?.status == 0 }
        var tries = 0
        while await !alive(), tries < 200 { try await Task.sleep(for: .milliseconds(10)); tries += 1 }
        #expect(await alive())

        let start = ContinuousClock.now
        Halt.end(process)
        tries = 0
        while tries < 200 {
            let left = await alive()
            if !process.isRunning && !left { break }
            try await Task.sleep(for: .milliseconds(10))
            tries += 1
        }
        #expect(!process.isRunning)
        #expect(await !alive())
        #expect(ContinuousClock.now - start < .seconds(2) - .seconds(Halt.grace))
    }
}
