import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

func object(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "oby-runner-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// The job from docs/runner-api.md.
let job = Job(id: "9f08fd10", request: "Review oby PR #33", agent: "claude", account: "default", repo: "deskree-inc/oby",
              branch: "oby/review-33", pr: 33, kind: .review, task: "Review pull request #33 in deskree-inc/oby.",
              created: Date(timeIntervalSince1970: 1_791_582_173))

@MainActor
final class DevicesTests {
    let folder: URL
    let devices: Devices
    let key = P256.Signing.PrivateKey()
    let action = "Push oby/fix-ab12cd to deskree-inc/oby and open a draft pull request into dev."
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    init() throws {
        folder = try temporaryFolder()
        devices = Devices(file: folder.appending(path: "devices.json"))
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func register() throws -> String {
        try devices.register(name: "Test iPhone", publicKey: key.publicKey.x963Representation.base64EncodedString())
    }

    /// What the phone sends: the runner's sentence for the job, signed at `signedAt`.
    func approval(device: String, action: String? = nil, signedAt: Date? = nil, key: P256.Signing.PrivateKey? = nil) throws -> Approval {
        let action = action ?? self.action, signedAt = (signedAt ?? now).formatted(.iso8601)
        let signature = try (key ?? self.key).signature(for: Data("oby-publish\nab12cd34\n\(action)\n\(signedAt)".utf8))
        return Approval(device: device, action: action, signedAt: signedAt, signature: signature.derRepresentation.base64EncodedString())
    }

    func refusal(_ approval: Approval, at now: Date? = nil) -> HTTPResponse.Status? {
        do {
            try devices.check(approval, job: "ab12cd34", action: action, now: now ?? self.now)
            return nil
        } catch {
            return (error as? APIError)?.status
        }
    }

    @Test func aFreshSignatureFromARegisteredDevicePasses() throws {
        #expect(refusal(try approval(device: try register())) == nil)
    }

    @Test func theActionMustBeTheRunnersOwn() throws {
        let other = "Push oby/fix-ab12cd to deskree-inc/oby and open a draft pull request into main."
        #expect(refusal(try approval(device: try register(), action: other)) == .forbidden)
    }

    @Test func signaturesExpireAfterTwoMinutes() throws {
        let device = try register()
        #expect(refusal(try approval(device: device, signedAt: now - 121)) == .forbidden)
        #expect(refusal(try approval(device: device, signedAt: now + 121)) == .forbidden)
        #expect(refusal(try approval(device: device, signedAt: now - 119)) == nil)
    }

    @Test func anApprovalWorksOnceEvenAfterARestart() throws {
        let device = try register()
        let approval = try approval(device: device)
        #expect(refusal(approval) == nil)
        #expect(refusal(approval, at: now + 30) == .forbidden)
        let restarted = Devices(file: folder.appending(path: "devices.json"))
        #expect(throws: APIError.self) { try restarted.check(approval, job: "ab12cd34", action: self.action, now: self.now + 60) }
    }

    @Test func unknownDevicesAndOtherKeysAreRefused() throws {
        #expect(refusal(try approval(device: "d7c1")) == .forbidden)
        #expect(refusal(try approval(device: try register(), key: P256.Signing.PrivateKey())) == .forbidden)
        var garbled = try approval(device: try register())
        garbled.signature = "MEUCIQ"
        #expect(refusal(garbled) == .forbidden)
    }

    /// The app registers every time it connects; the same key keeps one id, and other keys get their own.
    @Test func registeringAgainKeepsTheId() throws {
        let first = try register()
        #expect(try register() == first)
        let other = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        #expect(try devices.register(name: "Other iPhone", publicKey: other) != first)
    }

    @Test func malformedKeysDontRegister() {
        for key in ["BJ3x", "not base64!", Data(repeating: 4, count: 65).base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString()] {
            let error = #expect(throws: APIError.self) { try self.devices.register(name: "x", publicKey: key) }
            #expect(error?.status == .unprocessableContent)
        }
    }
}

@MainActor
final class APITests {
    let folder: URL
    let api: API
    let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]

    init() throws {
        folder = try temporaryFolder()
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    @Test func onlyTheOwnerGetsIn() async throws {
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { client in
            let strangers: [HTTPFields] = [[:], [.tailscaleUserLogin: "someone@example.com"], [.tailscaleUserLogin: "WELL@example.com"]]
            for headers in strangers {
                for uri in ["/v1/status", "/v1/jobs", "/v1/nowhere"] {
                    try await client.execute(uri: uri, method: .get, headers: headers) { response in
                        #expect(response.status == .unauthorized)
                        #expect(object(Data(response.body.readableBytesView))["error"] as? String == "This runner answers only its owner.")
                    }
                }
            }
        }
    }

    @Test func statusAnswersTheOwner() async throws {
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { [owner] client in
            try await client.execute(uri: "/v1/status", method: .get, headers: owner) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json")
                let status = object(Data(response.body.readableBytesView))
                #expect((status["runner"] as? [String: Any])?["version"] as? String == "0.2.0")
                let account = try #require((status["accounts"] as? [[String: Any]])?.first)
                #expect(account["id"] as? String == "default")
                #expect(account["signedIn"] as? Bool == false)
                #expect(account["label"] is NSNull)
                let claude = (status["models"] as? [String: Any])?["claude"] as? [String: Any]
                #expect(claude?["model"] as? String == AgentModels.value("claude", "model"))
            }
            try await client.execute(uri: "/v1/nowhere", method: .get, headers: owner) { response in
                #expect(response.status == .notFound)
                #expect(object(Data(response.body.readableBytesView))["error"] is String)
            }
        }
    }

    @Test func dispatchTakesOnlyPlansItMade() async throws {
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { [owner] client in
            let unknown = #"{"job": {"id": "9f08fd10", "branch": "oby/review-33", "account": "default"}}"#
            try await client.execute(uri: "/v1/jobs", method: .post, headers: owner, body: ByteBuffer(string: unknown)) { response in
                #expect(response.status == .unprocessableContent)
            }
            try await client.execute(uri: "/v1/jobs", method: .post, headers: owner, body: ByteBuffer(string: "{")) { response in
                #expect(response.status == .badRequest)
            }
            try await client.execute(uri: "/v1/jobs/9f08fd10/publish", method: .get, headers: owner) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test func dispatchKeepsTheBranchValidAndTheAccountSignedIn() throws {
        let work = AccountState(account: Account(id: "work", agent: "codex", name: "Work", payer: "Deskree", home: nil), label: "Plus · w@example.com")
        let edited = try Desk.edit(job, branch: "oby/review-33-again", account: work)
        #expect(edited.branch == "oby/review-33-again" && edited.account == "work" && edited.agent == "codex")
        #expect(edited.id == job.id && edited.repo == job.repo && edited.task == job.task)
        #expect(throws: Shell.Failure.self) { try Desk.edit(job, branch: "--upload-pack=sh", account: work) }
        #expect(throws: Shell.Failure.self) { try Desk.edit(job, branch: "oby/review 33", account: work) }
        #expect(throws: Shell.Failure.self) { try Desk.edit(job, branch: "oby/review-33", account: nil) }
        var signedOut = work
        signedOut.label = nil
        #expect(throws: Shell.Failure.self) { try Desk.edit(job, branch: "oby/review-33", account: signedOut) }
    }

    /// An older app sends the job back without rounds or check: the plan's values stay. A newer
    /// one may change them, and `"check": null` clears the check.
    @Test func dispatchBodiesMayLeaveTheLoopOut() throws {
        let decode = { (json: String) in try JSONDecoder().decode(DispatchRequest.self, from: Data(json.utf8)).job }
        let old = try decode(#"{"job": {"id": "a", "branch": "oby/fix-42", "account": "default"}}"#)
        #expect(old.rounds == nil && old.check == nil)
        let cleared = try decode(#"{"job": {"id": "a", "branch": "oby/fix-42", "account": "default", "rounds": 3, "check": null}}"#)
        #expect(cleared.rounds == 3 && cleared.check == .some(nil))
        let set = try decode(#"{"job": {"id": "a", "branch": "oby/fix-42", "account": "default", "check": "swift test", "model": "claude-fable-5-1"}}"#)
        #expect(set.check == .some("swift test") && set.model == .some("claude-fable-5-1") && old.model == nil)
    }

    @Test func plansMapToTheirKinds() throws {
        let draft = Desk.Draft(said: "Review oby PR #33", reply: "Oby will review PR #33 in oby.", job: job, guessed: true)
        let plan = object(try API.encode(PlanAnswer(.plan([draft]))))
        #expect(plan["kind"] as? String == "plan")
        // Every job in `drafts`, and the first again in `draft` for apps that know only one.
        #expect((plan["drafts"] as? [[String: Any]])?.count == 1)
        let body = try #require(plan["draft"] as? [String: Any])
        #expect(body["suggestedModel"] is NSNull)
        #expect(body["said"] as? String == "Review oby PR #33" && body["reply"] as? String == "Oby will review PR #33 in oby.")
        #expect(body["guessed"] as? Bool == true)
        #expect((body["job"] as? [String: Any])?["status"] as? String == "queued")

        let question = Plan.Question(text: "Which repository is PR #12 in?", options: ["deskree-inc/oby", "deskree-inc/blok"])
        let asked = object(try API.encode(PlanAnswer(.question(said: "Review PR 12", question))))
        #expect(asked["kind"] as? String == "question" && asked["said"] as? String == "Review PR 12")
        #expect((asked["question"] as? [String: Any])?["text"] as? String == question.text)
        #expect((asked["question"] as? [String: Any])?["options"] as? [String] == question.options)

        #expect(String(decoding: try API.encode(PlanAnswer(.reply("Oby can't merge pull requests."))), as: UTF8.self)
                == #"{"kind":"reply","text":"Oby can't merge pull requests."}"#)
        #expect(String(decoding: try API.encode(PlanAnswer(.none)), as: UTF8.self) == #"{"kind":"none"}"#)
        #expect(Desk.answered("Review PR 12", question: question.text, option: "deskree-inc/oby")
                == "Review PR 12\n\n(Oby asked: Which repository is PR #12 in? The user answered: deskree-inc/oby)")
    }

    /// What the iPhone's background download gets back: the job, once it ended.
    @Test func waitAnswersWithTheJobOnceItEnded() async throws {
        var ended = job
        ended.status = .done
        ended.finished = .now
        let store = JobStore(url: folder.appending(path: "ended.sqlite"))
        store.save(ended)
        let desk = Desk(accounts: AccountStore(root: folder), store: store)
        let app = Application(router: API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json"))).router(owner: "well@example.com"))
        try await app.test(.router) { [owner] client in
            try await client.execute(uri: "/v1/jobs/9f08fd10/wait", method: .get, headers: owner) { response in
                #expect(response.status == .ok)
                let body = String(decoding: response.body.readableBytesView, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                #expect(object(Data(body.utf8))["status"] as? String == "done")
            }
            try await client.execute(uri: "/v1/jobs/nobody/wait", method: .get, headers: owner) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test func jobsHaveISODatesAndEveryKey() throws {
        var job = job
        job.started = job.created + 2
        let json = String(decoding: try API.encode(JobJSON(job: job)), as: UTF8.self)
        #expect(json.contains(#""created":"2026-10-09T21:42:53Z""#))
        #expect(json.contains(#""started":"2026-10-09T21:42:55Z""#))
        for key in ["base", "session", "finished", "commits", "published", "issue", "check", "model", "notes"] { #expect(json.contains("\"\(key)\":null"), "\(key)") }
        let decoded = object(Data(json.utf8))
        #expect(decoded.count == 25)
        #expect(decoded["rounds"] as? Int == 1 && decoded["round"] as? Int == 1)
        #expect(decoded["kind"] as? String == "review" && decoded["pr"] as? Int == 33 && decoded["status"] as? String == "queued")
    }

    /// Talking to a job: 404 for an unknown one, 422 for bad words or a job that can't take them,
    /// and a finished one with a session runs again under the same id.
    @Test func messagesReachOnlyJobsThatCanTakeThem() async throws {
        let store = JobStore(url: folder.appending(path: "talk.sqlite"))
        var never = job
        never.id = "neverran"
        never.status = .failed
        // Gemini can't run jobs yet, so the resumed job fails at once, without starting a process.
        var finished = job
        finished.id = "finished"
        finished.agent = "gemini"
        finished.status = .done
        finished.session = "e6a24229"
        finished.rounds = 3
        finished.round = 2
        store.save(never)
        store.save(finished)
        let api = API(desk: Desk(accounts: AccountStore(root: folder), store: store), devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { [owner] client in
            func post(_ id: String, _ body: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                try await client.execute(uri: "/v1/jobs/\(id)/messages", method: .post, headers: owner, body: ByteBuffer(string: body)) { response in
                    (response.status, object(Data(response.body.readableBytesView)))
                }
            }
            #expect(try await post("nowhere", #"{"text": "hi"}"#).0 == .notFound)
            #expect(try await post("finished", #"{"words": "hi"}"#).0 == .badRequest)
            #expect(try await post("finished", #"{"text": " \n "}"#).0 == .unprocessableContent)
            #expect(try await post("finished", #"{"text": "\#(String(repeating: "x", count: 2001))"}"#).0 == .unprocessableContent)
            let (status, refusal) = try await post("neverran", #"{"text": "hi"}"#)
            #expect(status == .unprocessableContent && (refusal["error"] as? String)?.contains("never started") == true)

            let (resumed, again) = try await post("finished", #"{"text": "rename notes.txt to hello.txt"}"#)
            #expect(resumed == .ok)
            #expect(again["id"] as? String == "finished" && again["branch"] as? String == "oby/review-33")
            #expect(again["notes"] as? [String] == ["rename notes.txt to hello.txt"])
            #expect(again["round"] as? Int == 3 && again["rounds"] as? Int == 4)
            #expect(again["status"] as? String == "failed" && again["summary"] as? String == "gemini can't run jobs yet.")
        }
    }

    /// A result whose text holds U+2028 must arrive as one line, or the job never finishes.
    @Test func linesSplitOnNewlinesOnly() async throws {
        let pipe = Pipe()
        let result = #"{"type": "result", "subtype": "success", "result": "a\#u{2028}b"}"#
        try pipe.fileHandleForWriting.write(contentsOf: Data((result + "\n{}\n").utf8))
        try pipe.fileHandleForWriting.close()
        var lines: [Data] = []
        try await eachLine(of: pipe.fileHandleForReading) { lines.append($0) }
        #expect(lines.count == 2)
        let message = try #require(JSONSerialization.jsonObject(with: lines[0]) as? [String: Any])
        #expect(StreamJSON.events(message) == [.finished(summary: "a\u{2028}b", failed: false)])
    }
}

@MainActor
final class PushTests {
    let folder: URL
    let desk: Desk
    let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]
    let token = #"{"token": "80a1f2c3d4e5f60718293a4b5c6d7e8f", "kind": "update", "topic": "dev.wellprado.oby", "environment": "development"}"#

    init() throws {
        folder = try temporaryFolder()
        desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// ActivityKit decodes the content state with a plain JSONDecoder: `started` is a Date's
    /// default Codable, seconds since 2001.
    @Test func theContentStateIsTheAppsOwn() throws {
        struct ContentState: Decodable, Equatable {
            var working: Int, title: String, line: String, started: Date, status: String, agent: String
        }
        var running = job
        running.status = .running
        running.started = running.created + 2
        let payload = object(try Push.payload(["event": "update", "content-state": Push.State(running, working: 2)], now: running.created))
        let aps = try #require(payload["aps"] as? [String: Any])
        #expect(aps["event"] as? String == "update" && aps["timestamp"] as? Int == 1_791_582_173)
        let state = try JSONDecoder().decode(ContentState.self, from: JSONSerialization.data(withJSONObject: try #require(aps["content-state"])))
        #expect(state == ContentState(working: 2, title: "Review oby #33", line: "Starting…", started: running.created + 2, status: "running", agent: "claude"))

        var ended = job
        ended.status = .failed
        ended.pr = nil
        ended.request = "Fix the flaky test\nin JobStore"
        ended.summary = "The test still fails.\nDetails below."
        let end = Push.State(ended, working: 0)
        #expect(end.title == "Fix the flaky test" && end.line == "The test still fails." && end.started == job.created.timeIntervalSinceReferenceDate)
    }

    @Test func theProviderTokenVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let jwt = try Push.jwt(team: "PQKAL8E36D", keyID: "ABC123DEFG", key: key, now: job.created)
        let parts = jwt.split(separator: ".").map(String.init)
        try #require(parts.count == 3)
        func decoded(_ part: String) throws -> Data {
            var base64 = part.replacing("-", with: "+").replacing("_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            return try #require(Data(base64Encoded: base64))
        }
        #expect(!jwt.contains("=") && !jwt.contains("+") && !jwt.contains("/"))
        let header = object(try decoded(parts[0])), claims = object(try decoded(parts[1]))
        #expect(header["alg"] as? String == "ES256" && header["kid"] as? String == "ABC123DEFG")
        #expect(claims["iss"] as? String == "PQKAL8E36D" && claims["iat"] as? Int == 1_791_582_173)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try decoded(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func withoutAKeyThereIsNoPush() async throws {
        let push = Push(desk: desk, folder: folder.appending(path: "apns"))
        #expect(!push.isOn)
        for api in [API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")), push: push),
                    API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))] {
            let app = Application(router: api.router(owner: "well@example.com"))
            try await app.test(.router) { [owner, token] client in
                try await client.execute(uri: "/v1/activities", method: .post, headers: owner, body: ByteBuffer(string: token)) { response in
                    #expect(response.status == .ok)
                    #expect(String(decoding: response.body.readableBytesView, as: UTF8.self) == #"{"push":false}"#)
                }
            }
        }
    }

    @Test func aKeyTurnsItOnAndTokensAreChecked() throws {
        let apns = folder.appending(path: "apns")
        try FileManager.default.createDirectory(at: apns, withIntermediateDirectories: true)
        try Data(#"{"team": "PQKAL8E36D", "key": "TESTKEY123"}"#.utf8).write(to: apns.appending(path: "apns.json"))
        try P256.Signing.PrivateKey().pemRepresentation.write(to: apns.appending(path: "AuthKey_TESTKEY123.p8"), atomically: true, encoding: .utf8)
        let push = Push(desk: desk, folder: apns)
        #expect(push.isOn)
        let good = Push.Token(token: "80A1F2C3D4E5F60718293A4B5C6D7E8F", kind: "start", topic: "dev.wellprado.oby", environment: "production")
        #expect(try push.register(good))
        var other = good
        other.token = String(repeating: "1a", count: 40)
        #expect(try push.register(other))
        // The newer push-to-start token replaced the older one.
        let saved = try JSONDecoder().decode([Push.Token].self, from: Data(contentsOf: apns.appending(path: "tokens.json")))
        #expect(saved == [other])
        for bad in [Push.Token(token: "80a1f2c3d4e5f60718293a4b5c6d7e\"", kind: "update", topic: "dev.wellprado.oby", environment: "production"),
                    Push.Token(token: "80a1f2c3d4e5f60718293a4b5c6d7e8f", kind: "end", topic: "dev.wellprado.oby", environment: "production"),
                    Push.Token(token: "80a1f2c3d4e5f60718293a4b5c6d7e8f", kind: "update", topic: "dev.wellprado.oby\nurl = x", environment: "production"),
                    Push.Token(token: "80a1f2c3d4e5f60718293a4b5c6d7e8f", kind: "update", topic: "dev.wellprado.oby", environment: "staging")] {
            let error = #expect(throws: APIError.self) { try push.register(bad) }
            #expect(error?.status == .unprocessableContent)
        }
        #expect(Push.quoted(#"{"a":"b\n"}"#) == #""{\"a\":\"b\\n\"}""#)
    }
}

/// What bubblewrap shows an agent on the runner (docs: Agents.sandboxed).
struct SandboxTests {
    let home = Agents.home

    /// Where `run` starts in `argv`, as consecutive arguments.
    func at(_ run: String..., in argv: [String]) -> Int? {
        argv.indices.first { argv[$0...].starts(with: run) }
    }

    @Test func agentsSeeNoLoginsButTheirOwnAccount() throws {
        let worktree = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let common = "/srv/oby/repos/deskree-inc/oby/.git", admin = "\(common)/worktrees/9f08fd10"
        try "gitdir: \(admin)\n".write(to: worktree.appending(path: ".git"), atomically: true, encoding: .utf8)
        let root = Workspace.root.path, own = Workspace.root.appending(path: "accounts/personal").path
        let argv = Agents.sandboxed(["claude", "-p"], in: worktree, own: own, bubblewrap: true)

        #expect(argv.first == "bwrap" && argv.suffix(3) == ["--", "claude", "-p"])
        #expect(at("--ro-bind", "/", "/", in: argv) != nil && at("--unshare-pid", in: argv) != nil)
        for folder in [".config/gh", ".ssh", ".claude", ".codex"] { #expect(at("--tmpfs", "\(home)/\(folder)", in: argv) != nil) }
        for file in [".git-credentials", ".claude.json"] { #expect(at("--ro-bind", "/dev/null", "\(home)/\(file)", in: argv) != nil) }
        // All of OBY_HOME (apns/, devices.json, other accounts) is empty, then the job's own pieces come back.
        let hidden = try #require(at("--tmpfs", root, in: argv))
        #expect(try #require(at("--bind", own, own, in: argv)) > hidden)
        #expect(try #require(at("--bind", worktree.path, worktree.path, in: argv)) > hidden)
        #expect(!argv.contains { $0.hasPrefix("\(root)/apns") || $0.hasPrefix("\(root)/accounts/other") })
        // Commits work; what Oby's own git reads later doesn't change.
        #expect(at("--ro-bind", "\(worktree.path)/.git", "\(worktree.path)/.git", in: argv) != nil)
        let copy = try #require(at("--overlay-src", common, "--tmp-overlay", common, in: argv))
        for kept in ["objects", "refs", "logs", "packed-refs"] {
            #expect(try #require(at("--bind-try", "\(common)/\(kept)", "\(common)/\(kept)", in: argv)) > copy)
        }
        #expect(at("--bind", admin, admin, in: argv) != nil && at("--ro-bind", "\(admin)/commondir", "\(admin)/commondir", in: argv) != nil)
    }

    @Test func theDefaultClaudeAccountKeepsItsHomeAndConfig() {
        let argv = Agents.sandboxed(["claude"], in: nil, own: "\(home)/.claude", bubblewrap: true)
        #expect(at("--bind", "\(home)/.claude", "\(home)/.claude", in: argv) != nil)
        #expect(at("--tmpfs", "\(home)/.claude", in: argv) == nil && !argv.contains("\(home)/.claude.json"))
        #expect(at("--tmpfs", "\(home)/.codex", in: argv) != nil && at("--tmpfs", "\(home)/.config/gh", in: argv) != nil)
    }

    @Test func checksKeepNoAccountAndTheMacRunsAsIs() {
        let argv = Agents.sandboxed(["sh", "-c", "swift test"], in: nil, own: nil, bubblewrap: true)
        #expect(at("--tmpfs", "\(home)/.claude", in: argv) != nil && at("--tmpfs", "\(home)/.codex", in: argv) != nil)
        #expect(!argv.contains("--bind"))
        #expect(Agents.sandboxed(["sh", "-c", "swift test"], in: nil, own: nil, bubblewrap: false) == ["sh", "-c", "swift test"])
    }

    /// Codex's own bubblewrap can't nest inside Oby's, so it runs none and asks Oby about every command.
    @Test func codexAsksAboutEveryCommandInsideBubblewrap() {
        let params = CodexRPC.threadStart(worktree: URL(filePath: "/tmp/oby/jobs/9f08fd10"), git: "/tmp/oby/.git", bubblewrap: true)
        #expect(params["sandbox"] as? String == "danger-full-access" && params["approvalPolicy"] as? String == "untrusted")
        #expect(params["approvalsReviewer"] as? String == "user" && params["config"] == nil)
    }
}
