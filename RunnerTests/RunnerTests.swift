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

/// Writes `script` at `url` as an executable, through `install`, a process of its own. A file this
/// process writes is open for writing for a moment in any process another test starts just then,
/// until that one execs, and running the file in that moment fails with "Text file busy" (#193).
func executable(_ script: String, at url: URL) throws {
    let source = url.appendingPathExtension("source")
    try script.write(to: source, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: source) }
    let install = Process()
    install.executableURL = URL(filePath: "/usr/bin/install")
    install.arguments = ["-m", "700", source.path, url.path]
    try install.run()
    install.waitUntilExit()
    guard install.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
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
    let action = "Push oby/fix-ab12cd to deskree-inc/oby and open a pull request into dev."
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    init() throws {
        folder = try temporaryFolder()
        devices = Devices(file: folder.appending(path: "devices.json"))
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// Registers `key` (or another), with pairing opened first as the owner would.
    func register(_ publicKey: String? = nil) throws -> String {
        openPairing()
        return try devices.register(name: "Test iPhone", publicKey: publicKey ?? key.publicKey.x963Representation.base64EncodedString())
    }

    func openPairing(at date: Date = .now) {
        FileManager.default.createFile(atPath: devices.pairing.path, contents: nil, attributes: [.modificationDate: date])
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
        let other = "Push oby/fix-ab12cd to deskree-inc/oby and open a pull request into main."
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
        #expect(try register(other) != first)
    }

    /// Agents reach the API as the owner, so a new key needs the owner's `touch pairing` from the last
    /// 10 minutes, and uses it up. A known key needs nothing.
    @Test func newPhonesNeedPairing() throws {
        let mine = key.publicKey.x963Representation.base64EncodedString()
        let other = P256.Signing.PrivateKey().publicKey.x963Representation.base64EncodedString()
        let closed = { (key: String) in (#expect(throws: APIError.self) { try self.devices.register(name: "x", publicKey: key) })?.status }
        #expect(closed(mine) == .forbidden)
        openPairing(at: .now - 601)
        #expect(closed(mine) == .forbidden)
        openPairing()
        let id = try devices.register(name: "Test iPhone", publicKey: mine)
        #expect(!FileManager.default.fileExists(atPath: devices.pairing.path))
        #expect(closed(other) == .forbidden)
        #expect(try devices.register(name: "Test iPhone", publicKey: mine) == id)
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
                #expect(account["label"] is NSNull && account["fullUntil"] is NSNull)
                let claude = (status["models"] as? [String: Any])?["claude"] as? [String: Any]
                #expect(claude?["model"] as? String == AgentModels.value("claude", "model"))
                // No GitHub app here: the runner's own calls go with the owner's login.
                #expect(status["github"] as? String == "owner")
                // Nor any check runs: the owner can't write them, so reviews and Mac checks stay in Oby (#198).
                #expect(status["checks"] as? String == "no app")
                let cleanup = try #require(status["cleanup"] as? [String: Any])
                #expect(cleanup["path"] as? String == Workspace.root.appending(path: "jobs").path)
                #expect(cleanup["bytes"] is Int)
                #expect(cleanup["lastRun"] is NSNull)
            }
            try await client.execute(uri: "/v1/nowhere", method: .get, headers: owner) { response in
                #expect(response.status == .notFound)
                #expect(object(Data(response.body.readableBytesView))["error"] is String)
            }
        }
    }

    @Test func dispatchTakesOnlyWholeJobs() async throws {
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { [owner] client in
            // A plan's draft, from before Oby started planned work by itself (#269): gone.
            let draft = #"{"job": {"id": "9f08fd10", "branch": "oby/review-33", "account": "default"}}"#
            try await client.execute(uri: "/v1/jobs", method: .post, headers: owner, body: ByteBuffer(string: draft)) { response in
                #expect(response.status == .gone)
            }
            try await client.execute(uri: "/v1/jobs", method: .post, headers: owner, body: ByteBuffer(string: #"{"job": {"branch": "oby/review-33"}}"#)) { response in
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

    /// `POST /v1/jobs` takes a whole job (#269): repo, kind and task make one, with what the client
    /// sets; a draft's id alone is from before, and makes none.
    @Test func dispatchBodiesAreWholeJobs() throws {
        let decode = { (json: String) in try JSONDecoder().decode(DispatchRequest.self, from: Data(json.utf8)).job }
        let old = try decode(#"{"job": {"id": "a", "branch": "oby/fix-42", "account": "default"}}"#)
        #expect(old.id == "a" && old.new == nil)
        let whole = try decode(#"{"job": {"repo": "deskree-inc/oby", "kind": "fix", "task": "Fix #42", "issue": 42, "account": "default", "rounds": 3, "check": "swift test", "model": "claude-fable-5-1", "startWhen": []}}"#)
        let new = try #require(whole.new)
        #expect(new.repo == "deskree-inc/oby" && new.kind == "fix" && new.task == "Fix #42" && new.issue == 42 && new.pr == nil)
        #expect(new.account == "default" && new.rounds == 3 && new.check == "swift test" && new.model == "claude-fable-5-1")
        // An empty startWhen is none; files left out are nil, not none.
        #expect(new.startWhen == nil && new.files == nil && new.branch == nil)
        #expect(try decode(#"{"job": {"repo": "deskree-inc/oby", "kind": "fix"}}"#).new == nil)
        #expect(old.rounds == nil && old.check == nil)
        let cleared = try decode(#"{"job": {"id": "a", "branch": "oby/fix-42", "account": "default", "rounds": 3, "check": null}}"#)
        #expect(cleared.rounds == 3 && cleared.check == .some(nil))
        let set = try decode(#"{"job": {"id": "a", "branch": "oby/fix-42", "account": "default", "check": "swift test", "model": "claude-fable-5-1"}}"#)
        #expect(set.check == .some("swift test") && set.model == .some("claude-fable-5-1") && old.model == nil)
        let attached = try decode(#"{"job": {"id": "a", "branch": "oby/fix-42", "account": "default", "attachments": ["/tmp/screenshot.png"]}}"#)
        #expect(attached.attachments == ["/tmp/screenshot.png"])
    }

    @Test func plansMapToTheirKinds() throws {
        // A reply carries the jobs the turn started (#269), and `drafts` stays empty for older clients.
        let started = object(try API.encode(PlanAnswer(.reply("On it. Claude Code is reviewing oby PR #33 on Default."), started: [job])))
        #expect(started["kind"] as? String == "reply" && started["text"] as? String == "On it. Claude Code is reviewing oby PR #33 on Default.")
        let jobs = try #require(started["jobs"] as? [[String: Any]])
        #expect(jobs.count == 1 && jobs.first?["id"] as? String == job.id && jobs.first?["status"] as? String == "queued")
        #expect((started["drafts"] as? [Any])?.isEmpty == true)

        let question = Plan.Question(text: "Which repository is PR #12 in?", options: ["deskree-inc/oby", "deskree-inc/blok"])
        let asked = object(try API.encode(PlanAnswer(.question(said: "Review PR 12", question))))
        #expect(asked["kind"] as? String == "question" && asked["said"] as? String == "Review PR 12")
        #expect((asked["question"] as? [String: Any])?["text"] as? String == question.text)
        #expect((asked["question"] as? [String: Any])?["options"] as? [String] == question.options)
        #expect((asked["jobs"] as? [Any])?.isEmpty == true)

        #expect(String(decoding: try API.encode(PlanAnswer(.reply("Oby can't merge pull requests."))), as: UTF8.self)
                == #"{"drafts":[],"jobs":[],"kind":"reply","text":"Oby can't merge pull requests."}"#)
        #expect(String(decoding: try API.encode(PlanAnswer(.none)), as: UTF8.self) == #"{"drafts":[],"jobs":[],"kind":"none"}"#)
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
        for key in ["base", "session", "finished", "commits", "published", "pushed", "publishError", "summaries", "issue", "fromPR", "check", "model", "effort", "complexity", "notes", "pullRequest", "pullRequestError",
                    "dismissed", "reviewing", "review", "reviewError", "reviewOf", "files", "lead", "claim", "question", "limit", "startCommit", "firstSwiftBuildSeconds", "macCheck", "mergeError", "appleCheck", "appleRan", "tetrix", "xcodeCloud", "xcodeCloudError", "startWhen", "waiting", "permission"] { #expect(json.contains("\"\(key)\":null"), "\(key)") }
        let decoded = object(Data(json.utf8))
        #expect(decoded.count == 65)
        #expect(decoded["report"] as? Bool == false)
        #expect(decoded["cloudNeedsYou"] as? Bool == false)
        // A job from before modes ran as Bypass does.
        #expect(decoded["mode"] as? String == "bypass")
        #expect(json.contains(#""outgoing":[]"#) && json.contains(#""moves":[]"#) && json.contains(#""connectionUses":[]"#))
        #expect(decoded["pipeline"] is [String: Any])
        #expect(decoded["title"] as? String == "Review oby #33")
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

    /// Only a job that needs the user notifies, once per state; a newer state or a clear follows.
    @Test func onlyWhatNeedsYouNotifies() {
        var running = job, quiet = job, ready = job, failed = job, interrupted = job, stopped = job
        running.status = .running
        quiet.status = .done
        quiet.commits = 0
        quiet.base = "dev"
        ready.status = .done
        ready.kind = .fix
        ready.base = "dev"
        ready.commits = 2
        failed.status = .failed
        interrupted.status = .interrupted
        stopped.status = .stopped
        for (index, job) in [running, quiet, ready, failed, interrupted, stopped].enumerated() {
            #expect(Push.notice(for: { var job = job; job.id = "\(index)"; return job }()) == [nil, nil, .ready, .failed, .interrupted, nil][index])
        }

        let first = Push.notices([ready], after: [:])
        #expect(first.changes.map(\.1) == [.ready] && first.notified == [job.id: .ready])
        #expect(Push.notices([ready], after: first.notified).changes.isEmpty)
        // Published: the alert clears.
        var published = ready
        published.published = "https://github.com/deskree-inc/oby/pull/42"
        let cleared = Push.notices([published], after: first.notified)
        #expect(cleared.changes.count == 1 && cleared.changes[0].1 == nil && cleared.notified.isEmpty)
        // Failed after being ready: the newer state replaces it. A job the desk forgot is forgotten.
        let replaced = Push.notices([failed], after: [job.id: .ready, "gone": .failed])
        #expect(replaced.changes.map(\.1) == [.failed] && replaced.notified == [job.id: .failed])
    }

    /// Talking to a published job can make new commits: those can be published too, onto the same pull request.
    @Test func laterRoundsCommitsCanBePublished() throws {
        var done = job
        done.status = .done
        done.kind = .fix
        done.base = "dev"
        done.commits = 2
        #expect(done.canPublish && done.unpublished == 2 && done.needsYou)
        #expect(Publish.action(for: done, base: "dev") == "Push oby/review-33 to deskree-inc/oby and open a pull request into dev.")
        done.published = "https://github.com/deskree-inc/oby/pull/42"
        #expect(done.pushed == 2 && done.unpublished == 0 && !done.canPublish && Push.notice(for: done) == nil)
        // Another round made one more commit.
        done.commits = 3
        #expect(done.canPublish && done.unpublished == 1 && Push.notice(for: done) == .ready)
        #expect(Publish.action(for: done, base: "dev") == "Push the new commits on oby/review-33 to deskree-inc/oby, for its pull request into dev.")
        // Published again: the pull request has them all.
        done.published = "https://github.com/deskree-inc/oby/pull/42"
        #expect(done.pushed == 3 && !done.canPublish)

        // Loading a job doesn't count anything, and one published before Oby counted has nothing new.
        var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(done)) as? [String: Any])
        saved["pushed"] = nil
        let old = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(old.pushed == nil && old.published != nil && old.unpublished == 0 && !old.canPublish)
        let loaded = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(done))
        #expect(loaded.pushed == 3)
    }

    @Test func alertsSayWhatTheJobNeeds() throws {
        var ready = job
        ready.status = .done
        ready.base = "dev"
        ready.commits = 1
        ready.summary = "Fixed the review comments.\nMore below."
        let alert = object(try Push.notification(.ready, for: ready))
        let aps = try #require(alert["aps"] as? [String: Any])
        #expect(alert["job"] as? String == "9f08fd10" && aps["category"] as? String == "ready" && aps["timestamp"] == nil)
        #expect(aps["alert"] as? [String: String] == ["title": "Couldn't publish: Review oby #33", "body": "Fixed the review comments."])
        // Why Oby couldn't publish it by itself, when it knows.
        ready.publishError = "Couldn't push oby/review-33: the remote hung up."
        let why = try #require(object(try Push.notification(.ready, for: ready))["aps"] as? [String: Any])
        #expect(why["alert"] as? [String: String] == ["title": "Couldn't publish: Review oby #33", "body": "Couldn't push oby/review-33: the remote hung up."])

        var failed = job
        failed.status = .failed
        failed.summary = "Couldn't get oby ready: no network"
        let failure = try #require(object(try Push.notification(.failed, for: failed))["aps"] as? [String: Any])
        #expect(failure["category"] as? String == "job")
        #expect(failure["alert"] as? [String: String] == ["title": "Failed: Review oby #33", "body": "Couldn't get oby ready: no network"])

        let clear = object(try Push.notification(nil, for: ready))
        #expect(clear["clear"] as? String == "9f08fd10" && (clear["aps"] as? [String: Int]) == ["content-available": 1])
    }

    @Test func theAppHandsOverItsDeviceToken() async throws {
        let apns = folder.appending(path: "apns")
        try FileManager.default.createDirectory(at: apns, withIntermediateDirectories: true)
        try Data(#"{"team": "PQKAL8E36D", "key": "TESTKEY123"}"#.utf8).write(to: apns.appending(path: "apns.json"))
        try P256.Signing.PrivateKey().pemRepresentation.write(to: apns.appending(path: "AuthKey_TESTKEY123.p8"), atomically: true, encoding: .utf8)
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")), push: Push(desk: desk, folder: apns))
        let app = Application(router: api.router(owner: "well@example.com"))
        let device = #"{"token": "80a1f2c3d4e5f60718293a4b5c6d7e8f", "topic": "dev.wellprado.oby", "environment": "production"}"#
        let alertAsActivity = #"{"token": "80a1f2c3d4e5f60718293a4b5c6d7e8f", "kind": "alert", "topic": "dev.wellprado.oby", "environment": "production"}"#
        try await app.test(.router) { [owner] client in
            try await client.execute(uri: "/v1/notifications", method: .post, headers: owner, body: ByteBuffer(string: device)) { response in
                #expect(String(decoding: response.body.readableBytesView, as: UTF8.self) == #"{"push":true}"#)
            }
            try await client.execute(uri: "/v1/activities", method: .post, headers: owner, body: ByteBuffer(string: alertAsActivity)) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
        let saved = try JSONDecoder().decode([Push.Token].self, from: Data(contentsOf: apns.appending(path: "tokens.json")))
        #expect(saved == [Push.Token(token: "80a1f2c3d4e5f60718293a4b5c6d7e8f", kind: "alert", topic: "dev.wellprado.oby", environment: "production")])
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
        // Its death signal would follow the idle Dispatch thread that started bwrap.
        #expect(!argv.contains("--die-with-parent"))
        // Home is empty; only the tools, git's settings and Oby's own folder come back.
        #expect(at("--tmpfs", home, in: argv) != nil)
        #expect(at("--overlay-src", home, in: argv) == nil)
        let shown = Set(argv.filter { $0.hasPrefix("\(home)/") && !$0.hasPrefix(root) })
        #expect(shown.isSubset(of: Agents.tools.map { "\(home)/\($0)" } + ["\(home)/.gitconfig", "\(home)/.config/git"]), "\(shown)")
        for secret in [".tetrix-lab", ".config/gh", ".ssh", ".cache", ".claude", ".codex", ".aws", ".kube"] {
            #expect(!argv.contains { $0.hasPrefix("\(home)/\(secret)") }, "\(secret)")
        }
        // All of OBY_HOME (apns/, devices.json, other accounts) is empty, then the job's own pieces come back.
        let hidden = try #require(at("--tmpfs", root, in: argv))
        #expect(try #require(at("--bind", own, own, in: argv)) > hidden)
        #expect(try #require(at("--bind", worktree.path, worktree.path, in: argv)) > hidden)
        #expect(!argv.contains { $0.hasPrefix("\(root)/apns") || $0.hasPrefix("\(root)/accounts/other") })
        // Commits work; what Oby's own git reads later doesn't change.
        #expect(at("--ro-bind", "\(worktree.path)/.git", "\(worktree.path)/.git", in: argv) != nil)
        let shared = try #require(at("--ro-bind", common, common, in: argv))
        for kept in ["objects", "refs", "logs"] {
            #expect(try #require(at("--bind-try", "\(common)/\(kept)", "\(common)/\(kept)", in: argv)) > shared)
        }
        #expect(at("--bind", admin, admin, in: argv) != nil && at("--ro-bind", "\(admin)/commondir", "\(admin)/commondir", in: argv) != nil)
    }

    @Test func theDefaultClaudeAccountKeepsItsHomeAndConfig() {
        let argv = Agents.sandboxed(["claude"], in: nil, own: "\(home)/.claude", bubblewrap: true)
        #expect(at("--bind", "\(home)/.claude", "\(home)/.claude", in: argv) != nil)
        #expect(at("--bind-try", "\(home)/.claude.json", "\(home)/.claude.json", in: argv) != nil)
        #expect(!argv.contains { $0.hasPrefix("\(home)/.codex") || $0.hasPrefix("\(home)/.config/gh") })
    }

    @Test func checksKeepNoAccountAndTheMacRunsAsIs() {
        let argv = Agents.sandboxed(["sh", "-c", "swift test"], in: nil, own: nil, bubblewrap: true)
        #expect(!argv.contains { $0.hasPrefix("\(home)/.claude") || $0.hasPrefix("\(home)/.codex") })
        #expect(!argv.contains("--bind"))
        #expect(Agents.sandboxed(["sh", "-c", "swift test"], in: nil, own: nil, bubblewrap: false) == ["sh", "-c", "swift test"])
    }

    /// Where bwrap runs (the runner's `swift test` on Linux, outside a job), home really shows only that list.
    @Test(.enabled(if: bubblewrapRuns))
    func homeShowsOnlyTheToolsInsideBubblewrap() throws {
        let process = Process(), out = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = Agents.sandboxed(["ls", "-A", home], in: nil, own: nil)
        process.standardOutput = out
        try process.run()
        let listed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        process.waitUntilExit()
        // The first folder of each path that comes back, and of OBY_HOME when it's in home.
        let paths = Agents.tools + [".gitconfig", ".config/git"] + [Workspace.root.path].filter { $0.hasPrefix("\(home)/") }.map { String($0.dropFirst(home.count + 1)) }
        #expect(process.terminationStatus == 0)
        #expect(Set(listed).isSubset(of: paths.map { String($0.split(separator: "/")[0]) }), "\(listed)")
    }

    /// An agent started from a Dispatch worker, as Foundation starts processes, outlives that thread
    /// going idle (about 5 s); with bwrap's --die-with-parent it died with SIGKILL mid-turn.
    @Test(.enabled(if: bubblewrapRuns))
    func agentsOutliveTheThreadThatStartedThem() async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = Agents.sandboxed(["sleep", "30"], in: nil, own: nil)
        let group = try await withCheckedThrowingContinuation { (done: CheckedContinuation<ProcessGroup, any Error>) in
            DispatchQueue.global().async { done.resume(with: Result { try ProcessGroup.run(process) }) }
        }
        try await Task.sleep(for: .seconds(8))
        #expect(process.isRunning)
        group.end(after: Halt.stopping)
    }

    /// Codex's own bubblewrap can't nest inside Oby's, so it runs none and asks Oby about every command.
    @Test func codexAsksAboutEveryCommandInsideBubblewrap() {
        let params = CodexRPC.threadStart(worktree: URL(filePath: "/tmp/oby/jobs/9f08fd10"), git: "/tmp/oby/.git", bubblewrap: true)
        #expect(params["sandbox"] as? String == "danger-full-access" && params["approvalPolicy"] as? String == "untrusted")
        #expect(params["approvalsReviewer"] as? String == "user" && params["config"] == nil)
    }
}

/// Claude Code starts without the user's claude.ai connectors (Slack, Drive, Claude Docs), which
/// could act as the user, but keeps the account's own mcpServers like Tetrix.
struct ConnectorTests {
    let worktree = URL(filePath: "/tmp/oby/jobs/9f08fd10")

    @Test func agentsStartWithClaudeAIConnectorsOff() throws {
        for account in [nil, URL(filePath: "/tmp/oby/accounts/personal")] {
            let launch = try ClaudeAgent.launch(worktree: worktree, configDirectory: account, model: "opus", resume: nil)
            #expect(launch.environment["ENABLE_CLAUDEAI_MCP_SERVERS"] == "false")
            // Still the account's own login and config.
            #expect(launch.environment["CLAUDE_CONFIG_DIR"] == account?.path)
            // No settings file, the account's included (#134): its MCP servers come from the job's own file, and only they do.
            let arguments = launch.arguments
            let after = { (flag: String) in arguments.firstIndex(of: flag).map { arguments[arguments.index(after: $0)] } }
            #expect(after("--setting-sources") == "" && arguments.contains("--strict-mcp-config") && !arguments.contains("--bare"))
            #expect(after("--mcp-config") == ClaudeAgent.mcpFile(worktree: worktree).path)
            // In Oby's own folder, not the worktree the agent works in.
            #expect(!ClaudeAgent.mcpFile(worktree: worktree).path.hasPrefix(worktree.path + "/"))
            #expect(ClaudeAgent.mcpFile(worktree: worktree).path.hasPrefix(Workspace.root.path + "/"))
        }
    }

    /// The account's own servers, from its `.claude.json`, and nothing else from it: no header and
    /// no environment variable (a token) ever reaches the file the agent's box shows.
    @Test func theJobGetsTheAccountsOwnMCPServers() throws {
        let account = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: account) }
        let claude = #"""
            {"mcpServers": {"tetrix": {"type": "http", "url": "https://tetrix.example/mcp", "oauth": {"callbackPort": 3118}},
                            "github": {"type": "http", "url": "https://api.example/mcp", "headers": {"Authorization": "Bearer ghp_secret1"}},
                            "local": {"command": "npx", "args": ["server"], "env": {"API_TOKEN": "tok_secret2"}},
                            "files": {"command": "files-mcp", "args": ["--root", "."]}},
             "projects": {"/x": {"allowedTools": ["Bash"]}}}
            """#
        try Data(claude.utf8).write(to: account.appending(path: ".claude.json"))
        let data = ClaudeAgent.mcpConfig(configDirectory: account)
        let written = String(decoding: data, as: UTF8.self)
        for secret in ["ghp_secret1", "tok_secret2", "Authorization", "headers", "env", "oauth"] { #expect(!written.contains(secret), "\(secret)") }
        let config = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(config.keys.sorted() == ["mcpServers"])
        let servers = try #require(config["mcpServers"] as? [String: Any])
        // A server that needs a header or a variable is left out; the others keep what starts them.
        #expect(servers.keys.sorted() == ["files", "tetrix"])
        #expect((servers["tetrix"] as? [String: Any])?.keys.sorted() == ["type", "url"])
        #expect((servers["files"] as? [String: Any])?["args"] as? [String] == ["--root", "."])
        // Written for Oby alone.
        let file = account.appending(path: "mcp/job.json")
        try ClaudeAgent.writeMCP(data, to: file)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        let read = try Data(contentsOf: file)
        #expect(permissions?.intValue == 0o600 && read == data)
        // An account without the file has none.
        let none = try #require(JSONSerialization.jsonObject(with: ClaudeAgent.mcpConfig(configDirectory: account.appending(path: "missing"))) as? [String: Any])
        #expect((none["mcpServers"] as? [String: Any])?.isEmpty == true)
    }

    @Test func aResumedSessionKeepsThemOffToo() throws {
        let launch = try ClaudeAgent.launch(worktree: worktree, configDirectory: nil, model: nil, resume: "5f3c0d8e")
        #expect(launch.arguments.suffix(2) == ["--resume", "5f3c0d8e"])
        #expect(launch.environment["ENABLE_CLAUDEAI_MCP_SERVERS"] == "false")
    }

    @Test func theBrainHasNoConnectorsAndNoGitHubToken() throws {
        let env = try ClaudeBrain(home: "/tmp/oby/accounts/personal").environment()
        #expect(env["ENABLE_CLAUDEAI_MCP_SERVERS"] == "false")
        #expect(env["CLAUDE_CONFIG_DIR"] == "/tmp/oby/accounts/personal")
        #expect(env["GH_TOKEN"] == .some(nil) && env["GITHUB_TOKEN"] == .some(nil))
        #expect(try ClaudeBrain().environment()["CLAUDE_CONFIG_DIR"] == .some(nil))
    }
}

/// Claude Code's background commands and subagents outlive the turn Oby ends the session on,
/// so Policy sends them to the foreground.
struct BackgroundWorkTests {
    let worktree = URL(filePath: "/tmp/oby/jobs/9f08fd10")
    let foreground = "Run it in the foreground: Oby ends the session when your turn ends, and background work can't ask for permissions."

    @Test func backgroundCommandsAreDenied() {
        let input: [String: Any] = ["command": "pnpm dev", "run_in_background": true]
        #expect(Policy.deny(tool: "Bash", input: input, worktree: worktree) == foreground)
    }

    /// Claude Code runs a subagent in the background unless it's told not to, and always when it's remote.
    @Test func backgroundSubagentsAreDenied() {
        let subagent: [String: Any] = ["description": "Find callers", "prompt": "Find Policy's callers"]
        for tool in ["Agent", "Task"] {
            for extra in [["run_in_background": true], [:], ["run_in_background": false, "isolation": "remote"]] as [[String: Any]] {
                let input = subagent.merging(extra) { $1 }
                #expect(Policy.deny(tool: tool, input: input, worktree: worktree) == foreground, "\(tool) \(extra)")
            }
        }
    }

    @Test func foregroundCommandsAndSubagentsAreAllowed() {
        for background in [nil, false] as [Bool?] {
            var command: [String: Any] = ["command": "swift test"]
            if let background { command["run_in_background"] = background }
            #expect(Policy.deny(tool: "Bash", input: command, worktree: worktree) == nil)
        }
        for tool in ["Agent", "Task"] {
            for extra in [[:], ["isolation": "worktree"]] as [[String: Any]] {
                let input = ["description": "Find callers", "prompt": "Find Policy's callers", "run_in_background": false].merging(extra) { $1 }
                #expect(Policy.deny(tool: tool, input: input, worktree: worktree) == nil, "\(tool) \(extra)")
            }
        }
    }
}
