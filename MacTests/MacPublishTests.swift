import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Oby

/// Publishing a runner's job from the Mac (#152): this Mac's key registers with the runner, the
/// runner's sentence is what Touch ID approves, and nothing goes out without a signature.
@MainActor
struct MacPublishTests {
    /// The runner's sentence, as it says it: shown and signed exactly so.
    let sentence = "Push oby/fix-152 to deskree-inc/oby and open a pull request into dev."

    /// The bytes this Mac's key signs must be exactly what the runner checks (Runner/Devices.swift).
    @Test func approvalMessage() {
        let message = Approval.message(job: "ab12cd34", action: sentence, signedAt: "2026-10-11T09:30:00Z")
        #expect(String(decoding: message, as: UTF8.self)
                == "oby-publish\nab12cd34\nPush oby/fix-152 to deskree-inc/oby and open a pull request into dev.\n2026-10-11T09:30:00Z")
        // Touch ID's prompt reads "Oby is trying to push …": only the prompt changes, never what's signed.
        #expect(TouchIDKey.reason(sentence) == "push oby/fix-152 to deskree-inc/oby and open a pull request into dev")
    }

    /// Each connection registers again, with this Mac's name and its key; the runner's id is kept.
    @Test func registersOnEachConnection() async throws {
        let stub = RunnerStub { _ in (200, #"{"id": "d7c1"}"#) }
        let key = FakeKey()
        let device = MacDevice(key: key, name: "Wellington's MacBook Air", defaults: stub.defaults)
        #expect(try await device.register(with: stub.runner) == "d7c1")
        #expect(try await device.register(with: stub.runner) == "d7c1")
        #expect(device.state == .registered && device.status == "Registered, Touch ID" && device.problem == nil)
        #expect(device.id(on: stub.runner) == "d7c1")
        let sent = stub.requests
        #expect(sent.map(\.method) == ["POST", "POST"] && sent.allSatisfy { $0.path == "/v1/devices" })
        let body = try #require(sent.first?.json)
        #expect(body["name"] as? String == "Wellington's MacBook Air")
        #expect(body["publicKey"] as? String == key.signing.publicKey.x963Representation.base64EncodedString())
    }

    /// Pairing closed: the runner's 403 line is kept for Settings › Runner, not swallowed.
    @Test func pairingClosedIsShown() async throws {
        let line = "To add this phone, run `touch /var/lib/oby/pairing` on the runner, then try again within 10 minutes."
        let stub = RunnerStub { _ in (403, #"{"error": "\#(line)"}"#) }
        let device = MacDevice(key: FakeKey(), name: "Mac", defaults: stub.defaults)
        let error = await #expect(throws: RunnerError.self) { try await device.register(with: stub.runner) }
        #expect(error?.status == 403)
        #expect(device.state == .needsPairing(line) && device.problem == line && device.status == "Not registered")
        #expect(device.id(on: stub.runner) == nil)
    }

    /// Publish shows the runner's sentence unchanged, and that sentence is what's signed and sent.
    @Test func publishSignsTheRunnersSentence() async throws {
        let stub = RunnerStub { [sentence] request in
            switch (request.method, request.path) {
            case ("GET", "/v1/jobs/ab12cd34/publish"): (200, #"{"action": "\#(sentence)"}"#)
            case ("POST", "/v1/devices"): (200, #"{"id": "d7c1"}"#)
            case ("POST", "/v1/jobs/ab12cd34/publish"): (200, #"{"url": "https://github.com/deskree-inc/oby/pull/200"}"#)
            default: (404, #"{"error": "No."}"#)
            }
        }
        let key = FakeKey()
        let device = MacDevice(key: key, name: "Mac", defaults: stub.defaults)
        let action = try await stub.runner.publishAction("ab12cd34")
        #expect(action == sentence)
        let url = try await device.publish("ab12cd34", action: action, with: stub.runner)
        #expect(url.absoluteString == "https://github.com/deskree-inc/oby/pull/200")

        let publish = try #require(stub.requests.last { $0.method == "POST" && $0.path == "/v1/jobs/ab12cd34/publish" })
        let approval = try #require(publish.json)
        #expect(approval["device"] as? String == "d7c1" && approval["action"] as? String == sentence)
        // The runner's check, as Runner/Devices.swift makes it: the signature over those exact bytes.
        let signedAt = try #require(approval["signedAt"] as? String)
        let der = try #require((approval["signature"] as? String).flatMap { Data(base64Encoded: $0) })
        let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
        #expect(key.signing.publicKey.isValidSignature(signature, for: Approval.message(job: "ab12cd34", action: sentence, signedAt: signedAt)))
    }

    /// A cancelled Touch ID sends nothing: no publish reaches the runner.
    @Test func cancelledTouchIDSendsNothing() async throws {
        let stub = RunnerStub { request in
            request.path == "/v1/devices" ? (200, #"{"id": "d7c1"}"#) : (200, #"{"url": "https://github.com/deskree-inc/oby/pull/200"}"#)
        }
        let device = MacDevice(key: FakeKey(cancels: true), name: "Mac", defaults: stub.defaults)
        let error = await #expect(throws: RunnerError.self) { try await device.publish("ab12cd34", action: sentence, with: stub.runner) }
        #expect(error?.message == "Not published: Touch ID didn't approve it.")
        #expect(!stub.requests.contains { $0.path.hasSuffix("/publish") })
    }

    /// A Mac without Touch ID neither registers nor publishes, and says why.
    @Test func noTouchIDNoKey() async {
        let stub = RunnerStub { _ in (200, #"{"id": "d7c1"}"#) }
        let device = MacDevice(key: FakeKey(isAvailable: false), name: "Mac", defaults: stub.defaults)
        await #expect(throws: RunnerError.self) { try await device.publish("ab12cd34", action: sentence, with: stub.runner) }
        #expect(stub.requests.isEmpty && device.status == "Needs Touch ID")
    }

    /// `Runner.call` / the same path `Phone.runner` uses: with an `E2E.Client`, requests carry
    /// `Oby-E2E-*` headers and a sealed body, and the authenticated response opens cleanly.
    @Test func runnerCallSealsRequestsAndOpensResponses() async throws {
        let mac = E2E.KeyPair()
        let phone = E2E.KeyPair()
        let counterKey = "oby-test-runner-call-\(UUID().uuidString)"
        let client = try E2E.Client(device: "mac-device", keys: phone, gatewayPublicKey: mac.publicKey, counterKey: counterKey)
        let stub = RunnerStub(dataAnswer: { request in
            #expect(request.headers["Oby-E2E-Version"] == E2E.version)
            #expect(request.headers["Oby-E2E-Device"] == "mac-device")
            let counter = UInt64(request.headers["Oby-E2E-Counter"] ?? "") ?? 0
            #expect(counter > 0)
            let metadata = E2E.Metadata(method: request.method, route: request.path, device: "mac-device", counter: counter)
            let clear = try! E2E.open(request.body, with: mac.privateKey, metadata: metadata,
                                      authenticatedBy: phone.privateKey.publicKey)
            #expect(clear.isEmpty || (try? JSONSerialization.jsonObject(with: clear)) != nil)
            let responseMetadata = E2E.Metadata(method: request.method, route: request.path, device: "mac-device",
                                                counter: counter, direction: .response)
            let sealed = try! E2E.seal(Data(#"{"id":"d7c1"}"#.utf8), to: phone.publicKey,
                                       metadata: responseMetadata, authenticatedBy: mac.privateKey)
            return (200, E2E.frame(sealed))
        })
        let runner = Runner(base: stub.runner.base, e2e: client)
        let id = try await runner.register(name: "Mac", publicKey: FakeKey().signing.publicKey.x963Representation)
        #expect(id == "d7c1")
        #expect(stub.requests.count == 1)
        #expect(stub.requests[0].headers["Oby-E2E-Version"] == E2E.version)
        #expect(stub.requests[0].json == nil)
    }

    /// A job older than the latest 50 (an inbox item's Open job, or an alert's Publish) is fetched
    /// by its id, so its screen and its Publish open; one already listed isn't asked for again.
    @Test func olderJobIsFetched() async throws {
        let job = #"{"account":"default","agent":"claude","base":"dev","branch":"oby/fix-152","commits":2,"created":"2026-10-01T09:00:00Z","finished":"2026-10-01T09:20:00Z","id":"0ld0b152","kind":"fix","publishError":"GitHub's rate limit","repo":"deskree-inc/oby","request":"fix oby #152","session":"s","status":"done","step":"","summary":"Done.","task":"Fix #152."}"#
        let stub = RunnerStub { request in request.path == "/v1/jobs/0ld0b152" ? (200, job) : (404, #"{"error": "No."}"#) }
        let feed = RunnerFeed()
        try await feed.fetch("0ld0b152", from: stub.runner)
        let fetched = try #require(feed.jobs.first { $0.id == "0ld0b152" })
        #expect(fetched.canPublish && fetched.publishError == "GitHub's rate limit")
        try await feed.fetch("0ld0b152", from: stub.runner)
        #expect(stub.requests.count == 1 && feed.jobs.count == 1)

        // Settings › Runner changes while a fetch is on its way: the old runner's job doesn't land
        // in the new runner's list, where its actions would go to the new runner.
        let gate = DispatchSemaphore(value: 0)
        let slow = RunnerStub { _ in gate.wait(); return (200, job.replacingOccurrences(of: "0ld0b152", with: "07he7152")) }
        let switching = RunnerFeed()
        let fetching = Task { try await switching.fetch("07he7152", from: slow.runner) }
        for _ in 0..<500 where slow.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(slow.requests.count == 1)
        switching.forget()
        gate.signal()
        try await fetching.value
        #expect(switching.jobs.isEmpty)
    }
}

/// Signs as the Touch ID key does, with a software key, or cancels as the user would.
nonisolated struct FakeKey: PublishingKey {
    var isAvailable = true
    var cancels = false
    let signing = P256.Signing.PrivateKey()

    func publicKey() throws -> Data { signing.publicKey.x963Representation }

    func approve(job: String, action: String, device: String) async throws -> Approval {
        if cancels { throw RunnerError(message: "Not published: Touch ID didn't approve it.") }
        let signedAt = ISO8601DateFormatter().string(from: .now)
        let signature = try signing.signature(for: Approval.message(job: job, action: action, signedAt: signedAt))
        return Approval(device: device, action: action, signedAt: signedAt, signature: signature.derRepresentation.base64EncodedString())
    }
}

/// A runner on a host of its own, answered by `answer`, that keeps every request it got.
/// URLSession.shared asks RunnerStub, registered once, for every request: it takes only stubs' hosts.
nonisolated final class RunnerStub: Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var body: Data
        var headers: [String: String]

        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    }

    let host = "\(UUID().uuidString.lowercased()).runner.test"
    let answer: @Sendable (Request) -> (Int, Data)
    private let got = Mutex<[Request]>([])

    var runner: Runner { Runner(base: URL(string: "https://\(host)")!) }
    var requests: [Request] { got.withLock { $0 } }
    /// Not the app's defaults: the device id is kept by the runner's host, each stub's its own.
    var defaults: UserDefaults { UserDefaults(suiteName: "com.deskree.oby.tests")! }

    init(answer: @escaping @Sendable (Request) -> (Int, String)) {
        self.answer = { request in
            let (status, text) = answer(request)
            return (status, Data(text.utf8))
        }
        _ = Self.registered
        Self.stubs.withLock { $0[host] = self }
    }

    init(dataAnswer: @escaping @Sendable (Request) -> (Int, Data)) {
        self.answer = dataAnswer
        _ = Self.registered
        Self.stubs.withLock { $0[host] = self }
    }

    fileprivate func take(_ request: URLRequest) -> (Int, Data) {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        var headers: [String: String] = [:]
        request.allHTTPHeaderFields?.forEach { headers[$0.key] = $0.value }
        let got = Request(method: request.httpMethod ?? "GET", path: request.url?.absoluteURL.path() ?? "",
                          body: body, headers: headers)
        self.got.withLock { $0.append(got) }
        return answer(got)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    fileprivate static let stubs = Mutex<[String: RunnerStub]>([:])
    private static let registered: Void = { URLProtocol.registerClass(RunnerStubProtocol.self) }()
}

private nonisolated final class RunnerStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host().map { host in RunnerStub.stubs.withLock { $0[host] != nil } } ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(), let stub = RunnerStub.stubs.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, data) = stub.take(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
