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
    /// Built from parts, so this file doesn't trip the scan it tests.
    static func assign(_ key: String, _ value: String) -> String { key + " = \"" + value + "\"" }
    static let password = "password" + " = \"" + "hunter2hunter2hunter2" + "\""

    static func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
    static func base64URL(_ text: String) -> String {
        base64(text).replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
    static func hex(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined() }
    static func percent(_ text: String) -> String { text.utf8.map { String(format: "%%%02X", $0) }.joined() }
}

extension String {
    /// The string in pieces of `size` characters, the last one shorter.
    func chunks(_ size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map { String(dropFirst($0).prefix(size)) }
    }
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

    /// What review 1 found: a stray %, hex as escapes, and base64 wrapped over lines.
    @Test func escapesAStrayPercentAndWrappedBase64AreCaught() {
        #expect(Publish.matches("https://example.com/?discount=50%&k=\(Fake.percent(Fake.aws))") == ["AWS access key, URL-encoded"])
        let escaped = Fake.hex(Fake.aws).chunks(2).map { "\\x\($0)" }.joined()
        #expect(Publish.matches("let key = \"\(escaped)\"") == ["AWS access key, hex"])
        let bytes = Fake.hex(Fake.github).chunks(2).map { "0x\($0)" }.joined(separator: ", ")
        #expect(Publish.matches("static const char key[] = { \(bytes) };") == ["GitHub token, hex"])

        // As `base64` wraps it, at 76: the token straddles the lines.
        let wrapped = Fake.base64("export GITHUB_TOKEN=" + Fake.github + "\nexport OTHER=1\n").chunks(76)
        #expect(wrapped.count > 1)
        let text = (["# config", "data: |"] + wrapped.map { "  " + $0 } + ["done"]).joined(separator: "\n")
        #expect(Publish.findings(inText: text, named: "comment") == [Publish.Finding(file: "comment", line: 3, rule: "GitHub token, base64")])
        // Its first part at the end of the line before.
        let led = (["token = \"" + wrapped[0] + "\""] + wrapped.dropFirst().map { "\"" + $0 + "\"" }).joined(separator: "\n")
        #expect(Publish.findings(inText: led, named: "comment").contains { $0.line == 2 && $0.rule == "GitHub token, base64" })
        // In a diff, only lines next to each other in one file are joined.
        let diff = """
            diff --git a/k.yml b/k.yml
            --- a/k.yml
            +++ b/k.yml
            @@ -1,0 +1,\(wrapped.count) @@
            \(wrapped.map { "+" + $0 }.joined(separator: "\n"))
            """
        #expect(Publish.findings(inDiff: diff) == [Publish.Finding(file: "k.yml", line: 1, rule: "GitHub token, base64")])
        let apart = Publish.wrapped(wrapped.enumerated().map { Publish.Line(file: "k.yml", number: $0.offset * 2 + 1, text: $0.element) })
        #expect(apart.isEmpty)
    }

    @Test func namesOfSecretsAreNotSecrets() {
        // The keys and vault entry names code uses for secrets: names, not secrets.
        #expect(Publish.matches("static let " + Fake.assign("client" + "Secret", "client" + "Secret")).isEmpty)
        #expect(Publish.matches("static let " + Fake.assign("access" + "Token", "watch-access-client-" + "token")).isEmpty)
        #expect(Publish.matches("case " + Fake.assign("api" + "Key", "api_" + "key")).isEmpty)
        // Weak passwords, passphrases and real-looking keys still count.
        #expect(Publish.matches(Fake.assign("pass" + "word", "hunter2" + "hunter2")) == ["password or secret"])
        #expect(Publish.matches(Fake.assign("pass" + "word", "correct-horse-" + "battery-staple")) == ["password or secret"])
        #expect(Publish.matches(Fake.assign("api_" + "key", "aB3dE6gH9jK2" + "mN5pQ8sT")) == ["password or secret"])
        #expect(Publish.matches(Fake.assign("sec" + "ret", "mysecretpass" + "word1")) == ["password or secret"])
        // Whole words only, and never one that holds a password (Codex's review of #121).
        #expect(Publish.matches(Fake.assign("pass" + "word", "my-secret-" + "password")) == ["password or secret"])
        #expect(Publish.matches(Fake.assign("pass" + "word", "monkeyForest" + "Tree")) == ["password or secret"])
        #expect(Publish.matches(Fake.assign("sec" + "ret", "blue-sky-" + "morning")) == ["password or secret"])
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
        desk.dispatch(work)
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
        // An action this build doesn't know still reads (an older Mac, a newer runner).
        let future = try JSONDecoder().decode(Outgoing.self, from: Data(#"{"action":"release","repo":"deskree-inc/oby","id":"https://github.com/deskree-inc/oby/pull/80","date":0}"#.utf8))
        #expect(future.line == "release https://github.com/deskree-inc/oby/pull/80")
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

/// Halt: an agent that ignores SIGTERM, and what it started, still end within Stop all's 2 seconds;
/// what an agent leaves behind when it ends is killed with it.
struct HaltTests {
    /// Whether anything still runs whose command line names `mark`.
    func alive(_ mark: String) async -> Bool { (try? await Shell.run(["pgrep", "-f", mark]))?.status == 0 }

    /// Waits up to two seconds for nothing naming `mark` to be left.
    func gone(_ mark: String) async throws -> Bool {
        for _ in 0..<100 {
            if await !alive(mark) { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// A sleep nobody else runs, to find it by: `sleep 31.123456`.
    func mark() -> String { "sleep 31.\(Int.random(in: 100_000...999_999))" }

    /// Inside an agent's box (a job's own `swift test`) this hung for 1.5 hours (2026-10-11): it runs
    /// on the Mac and on the runner outside a job.
    @Test(.disabled(if: insideBubblewrap, "inside an agent's bubblewrap"), .timeLimit(.minutes(1)))
    func anAgentThatIgnoresTermEndsWithinTwoSeconds() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = folder.appending(path: "child.pid")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; sleep 30 & echo $! > '\(child.path)'; wait"]
        // When it really ended, not when this test, waiting on a busy main actor, gets to see it.
        let ended = Ended()
        process.terminationHandler = { _ in ended.mark() }
        let group = try ProcessGroup.run(process)
        for _ in 0..<200 where (try? String(contentsOf: child, encoding: .utf8))?.isEmpty ?? true { try await Task.sleep(for: .milliseconds(10)) }
        let sleeper = try #require(Int32((try String(contentsOf: child, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = kill(sleeper, SIGKILL) }

        // As ClaudeAgent.stop and CodexAgent.stop do: the grace, then Halt, which gets the rest of the 2 seconds.
        try await Task.sleep(for: .seconds(Halt.grace))
        let start = ContinuousClock.now
        group.end(after: Halt.stopping)
        for _ in 0..<500 where ended.at == nil { try await Task.sleep(for: .milliseconds(10)) }
        let end = try #require(ended.at)
        #expect(!process.isRunning)
        #expect(end - start < .seconds(2) - .seconds(Halt.grace))
        // What it started ends too: it's in the agent's process group.
        for _ in 0..<100 where kill(sleeper, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(kill(sleeper, 0) != 0)
    }

    /// Every agent leads a process group of its own, which is how Halt reaches all it started.
    @Test(.timeLimit(.minutes(1)))
    func agentsLeadAProcessGroupOfTheirOwn() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["5"]
        let group = try ProcessGroup.run(process)
        defer { group.end(after: 0) }
        #expect(getpgid(process.processIdentifier) == process.processIdentifier)
        #expect(getpgid(process.processIdentifier) != getpgrp())
    }

    /// `ended` returns once the process has ended, and right away after that: a moved job's new agent
    /// waits on it for the one it replaces (#118).
    @Test(.timeLimit(.minutes(1)))
    func endedWaitsForTheProcess() async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["30"]
        let group = try ProcessGroup.run(process)
        let ended = Ended()
        let waiting = Task {
            await group.ended()
            ended.mark()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(ended.at == nil)
        group.end(after: Halt.stopping)
        await waiting.value
        #expect(ended.at != nil)
        await group.ended()
    }

    /// The process dies on SIGTERM, but a child that ignores it lives until `end`'s SIGKILL: `ended`
    /// waits for that child too, or a moved job's new agent would work beside it.
    @Test(.timeLimit(.minutes(1)))
    func endedWaitsForWhatTheProcessLeftInItsGroup() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = folder.appending(path: "child.pid")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // The child writes its pid once it ignores SIGTERM (and `sleep` keeps ignoring it): written by
        // the shell, the pid could come before the trap, and SIGTERM would end the child at once.
        process.arguments = ["-c", "sh -c 'trap \"\" TERM; echo $$ > \"\(child.path)\"; exec sleep 30' & wait"]
        let group = try ProcessGroup.run(process)
        for _ in 0..<200 where (try? String(contentsOf: child, encoding: .utf8))?.isEmpty ?? true { try await Task.sleep(for: .milliseconds(10)) }
        let sleeper = try #require(Int32((try String(contentsOf: child, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { _ = kill(sleeper, SIGKILL) }

        let start = ContinuousClock.now
        group.end(after: 0.5)
        await group.ended()
        // The shell went at once; its child only with the SIGKILL, half a second later.
        #expect(ContinuousClock.now - start >= .milliseconds(450))
        #expect(!ProcessGroup.running(group: process.processIdentifier))
        #if os(Linux)
        let state = (try? String(contentsOfFile: "/proc/\(sleeper)/stat", encoding: .utf8))
            .flatMap { $0.split(separator: ")").last?.split(separator: " ").first }
        #expect(state == nil || state == "Z", "the child is still running: \(state ?? "")")
        #endif
    }

    /// Started from a Dispatch worker, which blocks nearly every signal, a process still blocks none:
    /// SIGTERM reaches it.
    @Test(.timeLimit(.minutes(1)))
    func agentsStartedFromDispatchStillHearTerm() async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["30"]
        let group = try await withCheckedThrowingContinuation { (done: CheckedContinuation<ProcessGroup, any Error>) in
            DispatchQueue.global().async { done.resume(with: Result { try ProcessGroup.run(process) }) }
        }
        #if os(Linux)
        let status = try String(contentsOfFile: "/proc/\(process.processIdentifier)/status", encoding: .utf8)
        #expect(status.split(separator: "\n").contains("SigBlk:\t0000000000000000"), "\(status)")
        #endif
        group.end(after: Halt.dropping)
        for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!process.isRunning)
        #expect(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM)
    }

    /// SIGTERM comes first, and the agent gets `after` seconds to end on it before SIGKILL.
    @Test(.timeLimit(.minutes(1)))
    func endingSaysTermFirst() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let said = folder.appending(path: "said")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "trap 'echo term > \"\(said.path)\"; exit 0' TERM; echo > \"\(said.path)\"; while :; do sleep 0.05; done"]
        process.standardError = FileHandle.nullDevice
        let group = try ProcessGroup.run(process)
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: said.path) { try await Task.sleep(for: .milliseconds(10)) }
        group.end(after: Halt.dropping)
        // A second end changes nothing.
        group.end(after: 0)
        for _ in 0..<300 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!process.isRunning)
        #expect(process.terminationReason == .exit && process.terminationStatus == 0)
        #expect(try String(contentsOf: said, encoding: .utf8) == "term\n")
    }

    /// A leftover that says `leftover` on the output if it ends by itself, after its sleep: output
    /// without it was cut by the kill, however slow the machine (#193).
    func leftover(_ mark: String) -> String { "\(mark) && echo leftover & echo started" }

    /// The agent ended by itself, but a tool it started still runs and holds its output: that's
    /// killed, so reading the output ends (a review sat running for 2.5 hours on a test's leftover).
    @Test(.timeLimit(.minutes(1)))
    func whatAnAgentLeavesBehindDoesntHoldItsOutput() async throws {
        let mark = mark()
        let process = Process(), out = Pipe()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", leftover(mark)]
        process.standardOutput = out
        _ = try ProcessGroup.run(process)
        let start = ContinuousClock.now
        let read = try await Task.detached { try out.fileHandleForReading.readToEnd() }.value
        #expect(read.map { String(decoding: $0, as: UTF8.self) } == "started\n")
        // Under the leftover's 31 s: killed, not waited out, however busy the machine (13 s, #193).
        #expect(ContinuousClock.now - start < .seconds(30))
        #expect(try await gone(mark))
    }

    /// The same for a check Oby runs: `Shell.run` returns when the command ends, not when its leftovers do.
    @Test(.timeLimit(.minutes(1)))
    func aChecksLeftoversDontHoldItsOutput() async throws {
        let mark = mark()
        let start = ContinuousClock.now
        let result = try await Shell.run(["sh", "-c", leftover(mark)])
        #expect(result.text == "started" && result.status == 0)
        #expect(ContinuousClock.now - start < .seconds(30))
        #expect(try await gone(mark))
    }

    /// On Linux agents run in bubblewrap (no --die-with-parent). A command the agent started in a
    /// session of its own, as Claude Code starts them, that ignores SIGTERM ends with the box.
    @Test(.enabled(if: bubblewrapRuns), .timeLimit(.minutes(1)))
    func anAgentInBubblewrapEndsWithWhatItStarted() async throws {
        let mark = mark()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = Agents.sandboxed(["sh", "-c", "setsid sh -c \"trap '' TERM; \(mark)\" & trap '' TERM; wait"], in: nil, own: nil)
        let group = try ProcessGroup.run(process)
        var tries = 0
        while await !alive(mark), tries < 200 { try await Task.sleep(for: .milliseconds(10)); tries += 1 }
        #expect(await alive(mark))

        let start = ContinuousClock.now
        group.end(after: Halt.stopping)
        #expect(try await gone(mark))
        for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!process.isRunning)
        #expect(ContinuousClock.now - start < .seconds(2) - .seconds(Halt.grace))
    }

    /// The agent in the box ended, but a command it started in a session of its own still runs:
    /// the box's pid 1 waits for it, so it's killed, and the agent's output ends.
    @Test(.enabled(if: bubblewrapRuns), .timeLimit(.minutes(1)))
    func whatAnAgentLeavesInTheBoxDoesntHoldItsOutput() async throws {
        let mark = mark()
        let start = ContinuousClock.now
        let result = try await Shell.run(Agents.sandboxed(["sh", "-c", "setsid \(mark) & echo started"], in: nil, own: nil))
        #expect(result.text == "started")
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(try await gone(mark))
    }
}

/// When a process ended, from its termination handler's thread.
final class Ended: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: ContinuousClock.Instant?
    var at: ContinuousClock.Instant? { lock.withLock { instant } }
    func mark() { lock.withLock { instant = .now } }
}
