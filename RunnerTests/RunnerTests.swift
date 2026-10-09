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

    @Test func plansMapToTheirKinds() throws {
        let draft = Desk.Draft(said: "Review oby PR #33", reply: "Oby will review PR #33 in oby.", job: job, guessed: true)
        let plan = object(try API.encode(PlanAnswer(.plan(draft))))
        #expect(plan["kind"] as? String == "plan")
        let body = try #require(plan["draft"] as? [String: Any])
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

    @Test func jobsHaveISODatesAndEveryKey() throws {
        var job = job
        job.started = job.created + 2
        let json = String(decoding: try API.encode(JobJSON(job: job)), as: UTF8.self)
        #expect(json.contains(#""created":"2026-10-09T21:42:53Z""#))
        #expect(json.contains(#""started":"2026-10-09T21:42:55Z""#))
        for key in ["base", "session", "finished", "commits", "published"] { #expect(json.contains("\"\(key)\":null"), "\(key)") }
        let decoded = object(Data(json.utf8))
        #expect(decoded.count == 19)
        #expect(decoded["kind"] as? String == "review" && decoded["pr"] as? Int == 33 && decoded["status"] as? String == "queued")
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
