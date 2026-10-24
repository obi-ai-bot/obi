import CryptoKit
import Foundation
import Synchronization

/// The phone's side of the envelope (#1278; docs/runner-api.md, "The envelope (version 1)"), what
/// obid's core/crates/obid/src/relay/envelope.rs opens and answers: a hello sealed to the Mac's
/// key from the QR code, the Mac's welcome, then one key per direction and an exact counter each
/// way. Only the Mac holding the pinned key can answer a hello; a changed, replayed or older
/// envelope doesn't open and spends nothing, and one past the next ends the session.
nonisolated enum RelayEnvelope {
    /// The versions this iPhone speaks.
    static let versions: [UInt8] = [1]
    /// The most bytes one envelope may be (sphere-api.md 9.3).
    static let largest = 262_144

    /// Why a welcome starts nothing.
    enum Refused: Error, Equatable {
        /// It doesn't open: not from the Mac whose key the QR code pinned (the Sphere in between,
        /// with a key of its own, or a Mac whose key changed).
        case notTheMac
        /// Not a welcome, or one choosing a version this iPhone didn't offer.
        case unreadable
    }

    /// A hello, and what reading its welcome takes.
    struct Hello {
        let bytes: Data
        private let ephemeral: Curve25519.KeyAgreement.PrivateKey
        private let es: Data
        private let offered: [UInt8]

        /// `01 01 ‖ E ‖ seal(k_hello, nonce(0), the versions offered)`, to the Mac whose public key
        /// is `mac`. `ephemeral` is new for each session; tests give the known answer's.
        init(to mac: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(), offering: [UInt8] = RelayEnvelope.versions) throws {
            let mine = ephemeral.publicKey.rawRepresentation
            es = try agree(ephemeral, mac)
            let head = Data([1, 1]) + mine
            bytes = head + seal(derive(salt: mac + mine, ikm: es, info: "oby relay v1 hello"), 0, Data(offering), aad: head)
            self.ephemeral = ephemeral
            offered = offering
        }

        /// The session, from the Mac's welcome: only the Mac with the pinned key could have made it.
        func welcomed(_ welcome: Data) throws -> Session {
            let welcome = [UInt8](welcome)
            guard welcome.count == 34 + 1 + 16, welcome[1] == 2, offered.contains(welcome[0]) else { throw Refused.unreadable }
            let version = welcome[0]
            let theirs = Data(welcome[2..<34])
            guard let ee = try? agree(ephemeral, theirs) else { throw Refused.notTheMac }
            let salt = Data(SHA256.hash(data: bytes + theirs))
            let key = { derive(salt: salt, ikm: es + ee, info: $0) }
            guard let said = try? open(key("oby relay v1 welcome"), 0, Data(welcome[34...]), aad: Data(welcome[..<34])) else {
                throw Refused.notTheMac
            }
            guard said == Data([version]) else { throw Refused.unreadable }
            return Session(version: version, sealing: key("oby relay v1 phone>mac"), opening: key("oby relay v1 mac>phone"))
        }
    }

    /// What opening one of the other side's envelopes gave.
    enum Opened: Equatable {
        case frame(Data)
        /// Changed, replayed, older, sent back the other way, another session's or no envelope at
        /// all: nothing spent.
        case dropped
        /// It opens, but one before it is missing: the session is over, say hello again.
        case gap
    }

    /// A session's two directions, each with its key and its exact counter.
    struct Session {
        let version: UInt8
        private let sealing: SymmetricKey
        private let opening: SymmetricKey
        private(set) var sent: UInt64 = 0
        private(set) var next: UInt64 = 0

        init(version: UInt8, sealing: SymmetricKey, opening: SymmetricKey) {
            self.version = version
            self.sealing = sealing
            self.opening = opening
        }

        /// `v 03 ‖ n ‖ seal(k, nonce(n), frame)`: the 10-byte header is the associated data.
        mutating func seal(_ frame: Data) -> Data {
            let head = Data([version, 3]) + counter(sent)
            let sealed = RelayEnvelope.seal(sealing, sent, frame, aad: head)
            sent += 1
            return head + sealed
        }

        /// Exactly the next envelope opens; one past it is a gap.
        mutating func open(_ envelope: Data) -> Opened {
            let bytes = [UInt8](envelope)
            guard bytes.count >= 26, bytes.count <= largest, bytes[1] == 3, bytes[0] == version else { return .dropped }
            let n = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard n >= next, let plain = try? RelayEnvelope.open(opening, n, Data(bytes[10...]), aad: Data(bytes[..<10])) else { return .dropped }
            guard n == next else { return .gap }
            next += 1
            return .frame(plain)
        }
    }

    /// X25519 (RFC 7748), refusing a key that agrees to all zeros (6.1).
    static func agree(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Data) throws -> Data {
        let shared = try mine.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirs)).withUnsafeBytes { Data($0) }
        guard shared.contains(where: { $0 != 0 }) else { throw Refused.notTheMac }
        return shared
    }

    /// HKDF-SHA256, 32 bytes.
    static func derive(salt: Data, ikm: Data, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: Data(info.utf8), outputByteCount: 32)
    }

    static func counter(_ n: UInt64) -> Data { withUnsafeBytes(of: n.bigEndian) { Data($0) } }

    /// ChaCha20-Poly1305 with 4 zero bytes then the counter as its nonce, the tag after the ciphertext.
    static func seal(_ key: SymmetricKey, _ n: UInt64, _ plain: Data, aad: Data) -> Data {
        // A 12-byte nonce and a frame under 256 KiB: sealing can't fail.
        let box = try! ChaChaPoly.seal(plain, using: key, nonce: try! ChaChaPoly.Nonce(data: Data(count: 4) + counter(n)), authenticating: aad)
        return box.ciphertext + box.tag
    }

    static func open(_ key: SymmetricKey, _ n: UInt64, _ sealed: Data, aad: Data) throws -> Data {
        let box = try ChaChaPoly.SealedBox(nonce: try ChaChaPoly.Nonce(data: Data(count: 4) + counter(n)), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }
}

/// What a sealed envelope holds (obi-sphere `protocol.md` section 13): a stream (4 bytes,
/// big-endian), a kind and its payload.
nonisolated struct RelayFrame: Equatable {
    enum Kind: UInt8 { case open, data, end, reset }

    var stream: UInt32
    var kind: Kind
    var payload = Data()

    init(stream: UInt32, kind: Kind, payload: Data = Data()) {
        self.stream = stream
        self.kind = kind
        self.payload = payload
    }

    init?(_ plain: Data) {
        let bytes = [UInt8](plain)
        guard bytes.count >= 5, let kind = Kind(rawValue: bytes[4]) else { return nil }
        stream = bytes[..<4].reduce(0) { $0 << 8 | UInt32($1) }
        self.kind = kind
        payload = Data(bytes[5...])
    }

    var encoded: Data { withUnsafeBytes(of: stream.bigEndian) { Data($0) } + [kind.rawValue] + payload }
}

/// A WebSocket as PhoneRelay uses it: URLSession's, or a test's.
nonisolated protocol RelaySocket: AnyObject, Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    /// The code the Sphere closed it with, once it's closed.
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    /// The answer to its upgrade: a 401 when the relay token opens nothing.
    var response: URLResponse? { get }
}

extension URLSessionWebSocketTask: RelaySocket {}

/// The relay route (#1278): one WebSocket to the Mac's Obysphere with this phone's relay token,
/// carrying sealed requests, their answers and the event stream (docs/runner-api.md, "obid only:
/// the phone relay"). Each socket starts a session with a hello and sends nothing before the Mac's
/// welcome; nothing ever goes unsealed, and nothing of a session outlives its socket. Runner sends
/// through it when the Mac paired through its Obysphere.
actor PhoneRelay {
    typealias Connect = @Sendable (URLRequest) -> any RelaySocket

    static let unreachable = RunnerError(message: "Your Mac isn't reachable.")
    static let forgotten = RunnerError(message: "This iPhone was removed from your Mac.", status: 401)
    static let replaced = RunnerError(message: "Another connection took this iPhone's place at your Obysphere. Open Oby again to reconnect.")
    /// No welcome to a hello: a Mac that's busy or just restarted, or one that can't open it.
    static let unanswered = RunnerError(message: "Your Mac isn't answering.")
    /// Several hellos in a row unanswered: obid answers nothing to a hello it can't open, so a Mac
    /// whose key changed looks like this, and only pairing again pins its new key.
    static let stillUnanswered = RunnerError(message: "Your Mac still isn't answering. If this keeps happening, pair again with the code in Oby on your Mac.")
    /// The most chunks of one answer held for a reader slower than the Mac (64 KiB each at most).
    static let held = 256

    nonisolated let link: RelayLink
    private let connect: Connect
    private var socket: (any RelaySocket)?
    /// Counts sockets: what an earlier one says or how it ends changes nothing any more.
    private var generation = 0
    private var hello: RelayEnvelope.Hello?
    private var session: RelayEnvelope.Session?
    /// Requests waiting for the session to start.
    private var waiting: [CheckedContinuation<Void, Error>] = []
    private var answers: [UInt32: Answer] = [:]
    private var lastStream: UInt32 = 0
    /// What goes out, one envelope at a time, each sealed as it goes: the counter is exact and each
    /// stream's id above every earlier one's, in the order the Mac reads them.
    private var outbox: Task<Void, Error>?
    /// Counts sessions: frames queued for one that ended are never sealed into the next.
    private var epoch = 0
    /// Why it opens nothing by itself any more (replaced, forgotten, another key), until `resume`.
    private var stopped: Error?
    /// After a 4008 (the Mac isn't connected) no socket opens before this, the wait doubling from
    /// 30 seconds to 5 minutes; `resume` (the person asks) opens one at once.
    private var notBefore = Date.distantPast
    private(set) var backoff: TimeInterval = 0
    /// How long a hello waits for its welcome once it's out.
    private let patience: TimeInterval
    /// Hellos in a row no welcome answered.
    private var unansweredInARow = 0

    private struct Answer {
        let url: URL
        var head: CheckedContinuation<HTTPURLResponse, Error>?
        let body: AsyncThrowingStream<Data, Error>.Continuation
        /// When the Mac last sent something on it.
        var heard = Date.now
    }

    init(_ link: RelayLink, connect: @escaping Connect = PhoneRelay.urlSession, patience: TimeInterval = 5) {
        self.link = link
        self.connect = connect
        self.patience = patience
    }

    static let urlSession: Connect = { request in
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return task
    }

    // MARK: Requests

    /// One request, sealed: its answer's status and headers, then its body as it comes (an event
    /// stream's as its events do). Ending the body early resets the stream, so the Mac stops.
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        guard let url = request.url, let parts = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        struct Head: Encodable { var method: String; var path: String; var headers: [String: String] }
        let path = (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath) + (parts.percentEncodedQuery.map { "?\($0)" } ?? "")
        let headers = Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }) { _, last in last }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let head = try encoder.encode(Head(method: request.httpMethod ?? "GET", path: path, headers: headers))
        let body = request.httpBody ?? Data()
        try await ready()
        let (answer, sink) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(Self.held))
        let asked = Mutex<UInt32>(0)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<HTTPURLResponse, Error>) in
                // Its id and its place in the outbox in one go, with no wait between.
                lastStream += 1
                let stream = lastStream
                asked.withLock { $0 = stream }
                sink.onTermination = { [weak self] end in
                    if case .cancelled = end { Task { await self?.stop(stream) } }
                }
                answers[stream] = Answer(url: url, head: waiting, body: sink)
                let parts = stride(from: 0, to: body.count, by: 65_536).map { body.subdata(in: $0..<min($0 + 65_536, body.count)) }
                let sent = post([RelayFrame(stream: stream, kind: .open, payload: head)]
                    + parts.map { RelayFrame(stream: stream, kind: .data, payload: $0) } + [RelayFrame(stream: stream, kind: .end)])
                Task { if case .failure(let error) = await sent.result { fail(stream, error) } }
                Task { await watch(stream, quiet: request.timeoutInterval) }
            }
        } onCancel: {
            let stream = asked.withLock { $0 }
            Task { await self.stop(stream) }
        }
        return (response, answer)
    }

    /// One request's whole answer, as URLSession's `data(for:)` gives it.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (response, body) = try await send(request)
        var data = Data()
        for try await chunk in body { data.append(chunk) }
        return (data, response)
    }

    /// The person asked (the app came to the front): a socket may open again at once, after a
    /// 4008, a 4003 or a key that didn't answer.
    func resume() {
        stopped = nil
        notBefore = .distantPast
    }

    /// The app went to the background: the socket closes, and with it the session.
    func hangUp() {
        drop(URLError(.cancelled))
    }

    // MARK: The session

    /// Waits until a session is up, opening a socket and saying hello if none is.
    private func ready() async throws {
        if let stopped { throw stopped }
        if session != nil { return }
        guard Date.now >= notBefore else { throw Self.unreachable }
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, Error>) in
            waiting.append(started)
            if hello == nil { sayHello() }
        }
    }

    private func sayHello() {
        guard let key = link.macKey, let hello = try? RelayEnvelope.Hello(to: key) else {
            stopped = RunnerError(message: "This pairing's key for your Mac can't be used. Pair again with the code in Oby on your Mac.")
            return drop(stopped!)
        }
        self.hello = hello
        let socket = socket ?? open()
        let current = generation
        Task {
            // Sent once the socket is up (URLSession gives up on an upgrade after its request's 60 seconds).
            do { try await socket.send(.data(hello.bytes)) } catch { return ended(current) }
            // No welcome within a few seconds of the hello going out: start over, on a new socket.
            try? await Task.sleep(for: .seconds(patience))
            if current == generation, session == nil, self.hello?.bytes == hello.bytes {
                unansweredInARow += 1
                drop(unansweredInARow >= 3 ? Self.stillUnanswered : Self.unanswered)
            }
        }
    }

    private func open() -> any RelaySocket {
        generation += 1
        var request = URLRequest(url: link.socketURL)
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        let socket = connect(request)
        self.socket = socket
        let current = generation
        Task {
            while let message = try? await socket.receive() { heard(message, current) }
            ended(current)
        }
        // The Sphere closes a socket silent for 2 minutes.
        Task {
            while true {
                try? await Task.sleep(for: .seconds(30))
                guard current == generation else { return }
                try? await socket.send(.string("ping"))
            }
        }
        return socket
    }

    /// Queues `frames` to go after everything queued before, each sealed with the next counter as
    /// it goes, in this session only.
    @discardableResult
    private func post(_ frames: [RelayFrame]) -> Task<Void, Error> {
        let previous = outbox
        let epoch = epoch
        let sending = Task {
            _ = await previous?.result
            for frame in frames {
                guard epoch == self.epoch, let socket, session != nil else { throw URLError(.networkConnectionLost) }
                try await socket.send(.data(session!.seal(frame.encoded)))
            }
        }
        outbox = sending
        return sending
    }

    private func heard(_ message: URLSessionWebSocketTask.Message, _ current: Int) {
        // The Sphere's only text is `pong`.
        guard current == generation, case .data(let envelope) = message else { return }
        guard session != nil else { return welcome(envelope) }
        switch session!.open(envelope) {
        case .dropped: break
        case .gap: over()
        case .frame(let plain):
            if let frame = RelayFrame(plain) { take(frame) }
        }
    }

    private func welcome(_ envelope: Data) {
        // Waiting for a welcome, what's left of a session before is dropped. obid answers nothing to
        // a hello it can't open, so a welcome that doesn't start this hello's session is an earlier
        // hello's, come late, or forged: it changes nothing, and the hello still waits for its own.
        guard let hello, envelope.count > 1, envelope[envelope.startIndex + 1] == 2,
              let started = try? hello.welcomed(envelope) else { return }
        session = started
        epoch += 1
        self.hello = nil
        backoff = 0
        unansweredInARow = 0
        for started in waiting { started.resume() }
        waiting = []
    }

    private func take(_ frame: RelayFrame) {
        // Stream 0 is the session's own: obid's `reset` there ends it.
        guard frame.stream != 0 else {
            if frame.kind == .reset { over() }
            return
        }
        guard var answer = answers[frame.stream] else { return }
        struct Head: Decodable { var status: Int; var headers: [String: String]? }
        answer.heard = .now
        answers[frame.stream] = answer
        switch frame.kind {
        case .open:
            guard let waiting = answer.head else { return }
            guard let head = try? JSONDecoder().decode(Head.self, from: frame.payload),
                  let response = HTTPURLResponse(url: answer.url, statusCode: head.status, httpVersion: "HTTP/1.1", headerFields: head.headers) else {
                return fail(frame.stream, RunnerError(message: "Your Mac's answer couldn't be read."))
            }
            answer.head = nil
            answers[frame.stream] = answer
            waiting.resume(returning: response)
        case .data:
            if case .dropped = answer.body.yield(frame.payload) {
                stop(frame.stream, RunnerError(message: "Your Mac's answer came faster than Oby could take it."))
            }
        case .end:
            guard answer.head == nil else { return fail(frame.stream, RunnerError(message: "Your Mac's answer couldn't be read.")) }
            answers[frame.stream] = nil
            answer.body.finish()
        case .reset:
            fail(frame.stream, RunnerError(message: String(decoding: frame.payload, as: UTF8.self)))
        }
    }

    /// The session is over (an envelope went missing, or obid said so): what was asked in it is
    /// lost, and the next request says hello again on the same socket.
    private func over() {
        session = nil
        epoch += 1
        hello = nil
        for stream in answers.keys { fail(stream, URLError(.networkConnectionLost)) }
    }

    private func fail(_ stream: UInt32, _ error: Error) {
        guard let answer = answers.removeValue(forKey: stream) else { return }
        answer.head?.resume(throwing: error)
        answer.body.finish(throwing: error)
    }

    /// The caller stopped waiting (left the events screen), or the answer can't go on: the Mac
    /// stops answering it.
    private func stop(_ stream: UInt32, _ error: Error = CancellationError()) {
        guard answers[stream] != nil else { return }
        fail(stream, error)
        post([RelayFrame(stream: stream, kind: .reset)])
    }

    /// Nothing from the Mac on a stream for `quiet` seconds (its request's timeout; an event stream
    /// and a wait send something every 15). Before its answer began, the session is stuck: a new
    /// hello, on a new socket. After, that answer alone ends.
    private func watch(_ stream: UInt32, quiet: TimeInterval) async {
        while true {
            try? await Task.sleep(for: .seconds(quiet))
            guard let answer = answers[stream] else { return }
            guard Date.now.timeIntervalSince(answer.heard) >= quiet else { continue }
            if answer.head != nil {
                fail(stream, URLError(.timedOut))
                return drop(URLError(.networkConnectionLost))
            }
            return stop(stream, URLError(.timedOut))
        }
    }

    /// The socket ended: why, as the Sphere's close code or its refusal of the upgrade says.
    private func ended(_ current: Int) {
        guard current == generation, let socket else { return }
        let status = (socket.response as? HTTPURLResponse)?.statusCode
        let error: Error
        switch (status, socket.closeCode.rawValue) {
        case (401, _), (_, 4001):
            error = Self.forgotten
            stopped = error
        case (_, 4003):
            // Another socket of this phone's took over: never open again by itself.
            error = Self.replaced
            stopped = error
        case (429, _), (_, 4008):
            backoff = min(max(backoff * 2, 30), 300)
            notBefore = .now + backoff
            error = Self.unreachable
        default:
            error = URLError(.networkConnectionLost)
        }
        drop(error)
    }

    /// Closes the socket: its session, what was asked in it and what waited for it end with `error`.
    private func drop(_ error: Error) {
        generation += 1
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        hello = nil
        session = nil
        epoch += 1
        for stream in answers.keys { fail(stream, error) }
        for started in waiting { started.resume(throwing: error) }
        waiting = []
    }
}
