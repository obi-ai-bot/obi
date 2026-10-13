import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Oby's control plane on Cloudflare (cloud/control-plane, #285), as the Mac talks to it: sign in
/// with an email code, register this installation, and get its tunnel's hostname and run token.
/// A call carries the user's session token or the installation's credential as a bearer; the
/// control plane keeps only their hashes, and never the tunnel token.
nonisolated struct ControlPlane: Sendable {
    var base: URL
    /// How a request goes out and what comes back (the body and the status): URLSession, or a
    /// test's stand-in.
    var transport: @Sendable (URLRequest) async throws -> (Data, Int)

    static let defaultURL = URL(string: "https://oby-control.tetrix.pro")!

    init(base: URL = defaultURL, transport: @escaping @Sendable (URLRequest) async throws -> (Data, Int) = ControlPlane.urlSession) {
        self.base = base
        self.transport = transport
    }

    static func urlSession(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    struct User: Codable, Equatable, Sendable {
        var id: String
        var email: String
    }

    /// What signing in gives: the session's bearer token, shown once.
    struct Session: Codable, Equatable, Sendable {
        var token: String
        var user: User
        var expiresAt: Date
    }

    /// The installation's tunnel: its hostname is what the iPhone connects to.
    struct Endpoint: Codable, Equatable, Sendable {
        var hostname: String
        var tunnelId: String
        var createdAt: Date
    }

    struct Installation: Codable, Equatable, Sendable {
        var id: String
        var clientId: String
        var name: String
        var platform: String
        var createdAt: Date
        var lastSeenAt: Date?
        var endpoint: Endpoint?
    }

    /// An installation with a credential just made for it, shown once.
    struct Registration: Codable, Equatable, Sendable {
        var installation: Installation
        var credential: String
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

    // MARK: Sign-in

    /// Emails a six-digit code to `email`.
    func requestCode(email: String) async throws {
        try await send("POST", "v1/auth/otp/request", body: ["email": email])
    }

    func verify(email: String, code: String) async throws -> Session {
        try await call("POST", "v1/auth/otp/verify", body: ["email": email, "code": code])
    }

    func me(session: String) async throws -> User {
        struct Answer: Decodable { var user: User }
        let answer: Answer = try await call("GET", "v1/me", bearer: session)
        return answer.user
    }

    func signOut(session: String) async throws {
        try await send("POST", "v1/auth/signout", bearer: session)
    }

    // MARK: Installations, with the user's session

    func installations(session: String) async throws -> [Installation] {
        struct Answer: Decodable { var installations: [Installation] }
        let answer: Answer = try await call("GET", "v1/installations", bearer: session)
        return answer.installations
    }

    /// Registers this Mac (its stable `clientID`) and gets its credential. The same Mac again
    /// keeps its installation and gets a fresh credential.
    func register(session: String, clientID: String, name: String, platform: String = "macos") async throws -> Registration {
        try await call("POST", "v1/installations", body: ["clientId": clientID, "name": name, "platform": platform], bearer: session)
    }

    /// A new credential for the installation; the one before stops working.
    func rotate(_ installation: String, session: String) async throws -> Registration {
        try await call("POST", "v1/installations/\(installation)/credential", bearer: session)
    }

    /// Removes the installation: its tunnel, its credential, and the session it registered with.
    func remove(_ installation: String, session: String) async throws {
        try await send("DELETE", "v1/installations/\(installation)", bearer: session)
    }

    // MARK: This installation, with its credential

    func installation(credential: String) async throws -> Installation {
        struct Answer: Decodable { var installation: Installation }
        let answer: Answer = try await call("GET", "v1/installations/self", bearer: credential)
        return answer.installation
    }

    /// The installation's tunnel and hostname, made on the first call and the same after.
    func createEndpoint(credential: String) async throws -> Endpoint {
        struct Answer: Decodable { var endpoint: Endpoint }
        let answer: Answer = try await call("POST", "v1/installations/self/endpoint", bearer: credential)
        return answer.endpoint
    }

    func tunnelToken(credential: String) async throws -> TunnelToken {
        try await call("GET", "v1/installations/self/endpoint/token", bearer: credential)
    }

    func removeEndpoint(credential: String) async throws {
        try await send("DELETE", "v1/installations/self/endpoint", bearer: credential)
    }

    // MARK: Calls

    private func call<Answer: Decodable>(_ method: String, _ path: String, body: [String: String]? = nil, bearer: String? = nil) async throws -> Answer {
        let data = try await send(method, path, body: body, bearer: bearer)
        do {
            return try Self.decoder.decode(Answer.self, from: data)
        } catch {
            throw Failure(message: "The control plane's answer couldn't be read.", status: 0)
        }
    }

    @discardableResult
    private func send(_ method: String, _ path: String, body: [String: String]? = nil, bearer: String? = nil) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, status) = try await transport(request)
        guard (200..<300).contains(status) else { throw Self.failure(data, status: status) }
        return data
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
