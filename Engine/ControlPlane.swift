import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Oby's control plane on Cloudflare (cloud/control-plane, #285), as the Mac talks to it: sign in
/// with Apple or Google, register this installation, and get its tunnel's hostname and run token. The Mac is
/// known by its P-256 key, and every call is signed with it (`Signer`), with a timestamp and a
/// nonce, so nothing the Mac sends works for anyone else or works twice; a new installation also
/// belongs to the Apple or Google account it signed in with. The control plane keeps the public
/// key and the account's `sub` (and a Google account's domain, never its email), and never the
/// tunnel token.
nonisolated struct ControlPlane: Sendable {
    var base: URL
    /// How a request goes out and what comes back (the body and the status): URLSession, or a
    /// test's stand-in.
    var transport: @Sendable (URLRequest) async throws -> (Data, Int)
    /// The clock the calls' timestamps come from.
    var now: @Sendable () -> Date = { Date() }

    /// The app's ObyControlPlaneURL (OBY_CONTROL_PLANE_URL in apps/config/Signing.xcconfig), else
    /// Deskree's own instance.
    static let defaultURL = (Bundle.main.object(forInfoDictionaryKey: "ObyControlPlaneURL") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? URL(string: "https://oby-control.deskree.com")!
    /// What's signed before the method, the path, the timestamp, the nonce and the body.
    static let signedPrefix = "oby-control-v1"

    init(base: URL = defaultURL, transport: @escaping @Sendable (URLRequest) async throws -> (Data, Int) = ControlPlane.urlSession) {
        self.base = base
        self.transport = transport
    }

    static func urlSession(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// This Mac's key: its public half (an uncompressed P-256 point, X9.63, 65 bytes) and a way to
    /// sign with the private half (ECDSA with SHA-256, the signature as r‖s, 64 bytes). The Mac
    /// app's lives in the Secure Enclave when there is one (apps/mac/app/RemoteAccess.swift); this
    /// file does no crypto, so it builds on Linux too.
    struct Signer: Sendable {
        var publicKey: Data
        var sign: @Sendable (Data) throws -> Data
    }

    /// The installation's tunnel: its hostname is what the iPhone connects to.
    struct Endpoint: Codable, Equatable, Sendable {
        var hostname: String
        var tunnelId: String
        var createdAt: Date
    }

    /// The account an installation signed in with: the provider (`apple` or `google`), and for
    /// Google the domain the control plane keeps (its Workspace's, else its email's), never an email.
    struct Account: Codable, Equatable, Sendable {
        var provider: String
        var domain: String?
    }

    struct Installation: Codable, Equatable, Sendable {
        var id: String
        var account: Account?
        var name: String
        var platform: String
        var createdAt: Date
        var lastSeenAt: Date?
        var endpoint: Endpoint?
    }

    /// What `cloudflared tunnel run` connects with, and the hostname it serves.
    struct TunnelToken: Codable, Equatable, Sendable {
        var token: String
        var hostname: String
    }

    /// What the control plane said when it refused, with its status.
    struct Failure: LocalizedError, Equatable {
        let message: String
        let status: Int
            var errorDescription: String? { message }
    }

    // MARK: This installation, signed by its key

    /// Who a new installation signs in with, on the web.
    enum Provider: String, CaseIterable, Sendable {
        case google, apple
        /// What Settings' button and messages call it: "Sign in with Apple".
        var name: String { self == .apple ? "Apple" : "Google" }
    }

    /// What this control plane takes before it signs anyone in (`GET /v1/auth`, unsigned): its
    /// providers, set up and allowed, and the Google Workspaces it's for when it's members-only.
    struct SignInOptions: Decodable, Equatable, Sendable {
        var providers: [String]
        var workspaces: [String]
    }

    func signInOptions() async throws -> SignInOptions {
        try await call("GET", "v1/auth", signer: nil)
    }

    /// A sign-in this Mac starts: the provider's authorization page, and the state that names it.
    /// The provider sends the result to the control plane, never to the Mac.
    struct SignIn: Codable, Equatable, Sendable {
        var url: URL
        var state: String
    }

    func startSignIn(_ signer: Signer, with provider: Provider) async throws -> SignIn {
        try await call("POST", "v1/auth/\(provider.rawValue)/start", signer: signer)
    }

    /// What registering gives: the installation, and the Mac the account gave up to make room for
    /// it, when it had as many as it may (the one it used longest ago).
    struct Registration: Decodable, Equatable, Sendable {
        struct Evicted: Decodable, Equatable, Sendable { var name: String }
        var installation: Installation
        var evicted: Evicted?
    }

    /// Registers this Mac by its key; the same key again keeps its installation and hostname. A
    /// new key brings the sign-in with Apple it finished: its `state`, and the `code` the sheet
    /// came back with.
    func register(_ signer: Signer, name: String, signIn: (state: String, code: String)? = nil, platform: String = "macos") async throws -> Registration {
        var body = ["name": name, "platform": platform]
        if let signIn {
            body["signIn"] = signIn.state
            body["signInCode"] = signIn.code
        }
        return try await call("POST", "v1/installations", body: body, signer: signer)
    }

    /// This installation, as the control plane has it. Any signed call keeps it from being
    /// removed as idle.
    func installation(_ signer: Signer) async throws -> Installation {
        struct Answer: Decodable { var installation: Installation }
        let answer: Answer = try await call("GET", "v1/installations/self", signer: signer)
        return answer.installation
    }

    /// The installation's tunnel and hostname, made on the first call and the same after.
    func createEndpoint(_ signer: Signer) async throws -> Endpoint {
        struct Answer: Decodable { var endpoint: Endpoint }
        let answer: Answer = try await call("POST", "v1/installations/self/endpoint", signer: signer)
        return answer.endpoint
    }

    func tunnelToken(_ signer: Signer) async throws -> TunnelToken {
        try await call("GET", "v1/installations/self/endpoint/token", signer: signer)
    }

    func removeEndpoint(_ signer: Signer) async throws {
        try await send("DELETE", "v1/installations/self/endpoint", signer: signer)
    }

    /// Forget This Mac: the installation goes, its tunnel and hostname with it.
    func forget(_ signer: Signer) async throws {
        try await send("DELETE", "v1/installations/self", signer: signer)
    }

    // MARK: Calls

    private func call<Answer: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil, signer: Signer?) async throws -> Answer {
        let data = try await send(method, path, body: body, signer: signer)
        do {
            return try Self.decoder.decode(Answer.self, from: data)
        } catch {
            throw Failure(message: "The control plane's answer couldn't be read.", status: 0)
        }
    }

    @discardableResult
    private func send(_ method: String, _ path: String, body: [String: String]? = nil, signer: Signer?) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let signer { try sign(&request, with: signer) }
        let (data, status) = try await transport(request)
        guard (200..<300).contains(status) else { throw Self.failure(data, status: status) }
        return data
    }

    /// The signature's headers (cloud/control-plane/src/app.ts, `signed`): the key, the time, a
    /// nonce used once, and the signature of all that with the method, the path and the body.
    func sign(_ request: inout URLRequest, with signer: Signer) throws {
        let timestamp = String(Int(now().timeIntervalSince1970))
        let nonce = UUID().uuidString
        let head = [Self.signedPrefix, request.httpMethod ?? "GET", request.url?.path ?? "/", timestamp, nonce, ""].joined(separator: "\n")
        let signature = try signer.sign(Data(head.utf8) + (request.httpBody ?? Data()))
        request.setValue(Self.base64url(signer.publicKey), forHTTPHeaderField: "Oby-Key")
        request.setValue(timestamp, forHTTPHeaderField: "Oby-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "Oby-Nonce")
        request.setValue(Self.base64url(signature), forHTTPHeaderField: "Oby-Signature")
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The control plane's own line (`{"error": …}`), or one about the status.
    static func failure(_ data: Data, status: Int) -> Failure {
        struct Said: Decodable { var error: String }
        if let said = try? JSONDecoder().decode(Said.self, from: data) { return Failure(message: said.error, status: status) }
        return Failure(message: status == 0 ? "The control plane didn't answer." : "The control plane answered \(status).", status: status)
    }

    /// Dates as the Worker writes them (`toISOString`, with milliseconds), or without a fraction.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
            }
            return date
        }
        return decoder
    }()

    static func date(from text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
