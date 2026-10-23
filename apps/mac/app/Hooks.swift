import Foundation

/// Webhooks into obid (#1128; docs/runner-api.md, "obid only: webhooks"): each hook has an address on
/// Oby's control plane, which passes deliveries through this Mac's tunnel to obid, and a secret only
/// obid holds, in its vault. There's no screen for hooks (the owner's decision of 2026-10-23, #1117):
/// a monitoring tool's row in Settings › Connectors makes its hook behind the scenes (#1311, #1312).
extension ControlPlane {
    /// A hook's address, as the control plane answers it.
    struct Hook: Codable, Equatable, Sendable {
        var id: String
        var url: URL
        var createdAt: Date
    }

    /// A new hook address for this Mac.
    func createHook(_ signer: Signer) async throws -> Hook {
        struct Answer: Decodable { var hook: Hook }
        return try Self.decoded(Answer.self, try await hookCall("POST", "v1/installations/self/hooks", signer: signer)).hook
    }

    /// This Mac's hook addresses.
    func hooks(_ signer: Signer) async throws -> [Hook] {
        struct Answer: Decodable { var hooks: [Hook] }
        return try Self.decoded(Answer.self, try await hookCall("GET", "v1/installations/self/hooks", signer: signer)).hooks
    }

    /// Removes one: its address answers 404 from then on.
    func removeHook(_ id: String, _ signer: Signer) async throws {
        _ = try await hookCall("DELETE", "v1/installations/self/hooks/\(id)", signer: signer)
    }

    /// A signed call, as the control plane's own (`send`, private to Engine/, which stays unchanged).
    private func hookCall(_ method: String, _ path: String, signer: Signer) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try sign(&request, with: signer)
        let (data, status) = try await transport(request)
        guard (200..<300).contains(status) else { throw Self.failure(data, status: status) }
        return data
    }

    private static func decoded<Answer: Decodable>(_ type: Answer.Type, _ data: Data) throws -> Answer {
        do { return try decoder.decode(type, from: data) } catch {
            throw Failure(message: "The control plane's answer couldn't be read.", status: 0)
        }
    }
}

extension Runner {
    /// A hook as obid keeps it (`GET /v1/hooks`): never its secret.
    struct HookRow: Decodable, Equatable, Sendable {
        struct Delivery: Decodable, Equatable, Sendable {
            var at: Date
            /// `accepted`, `duplicate`, `bad signature`, `too large` or `too many`.
            var result: String
        }
        var id: String
        var name: String
        var source: String
        var repo: String?
        var url: String
        var lastDelivery: Delivery?
    }

    func hooks() async throws -> [HookRow] {
        try await call("GET", "v1/hooks")
    }

    /// Gives obid a hook the control plane made, with its secret, which obid keeps in its vault.
    func addHook(id: String, url: URL, name: String, source: String, secret: String, repo: String?) async throws -> HookRow {
        struct Body: Encodable { var id: String; var url: String; var name: String; var source: String; var secret: String; var repo: String? }
        return try await call("POST", "v1/hooks", body: Body(id: id, url: url.absoluteString, name: name, source: source, secret: secret, repo: repo))
    }

    func removeHook(_ id: String) async throws {
        try await send("DELETE", "v1/hooks/\(id)")
    }
}

/// Making and removing a hook takes both places: the control plane's address, then obid's registry
/// with the secret. If obid refuses, the address goes again, so nothing is left half made.
enum HookSetup {
    /// A new secret: 32 random bytes, hex.
    static func newSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    static func make(name: String, source: String, repo: String?, secret: String,
                     plane: ControlPlane, signer: ControlPlane.Signer, obid: Runner) async throws -> Runner.HookRow {
        let address = try await plane.createHook(signer)
        do {
            return try await obid.addHook(id: address.id, url: address.url, name: name, source: source, secret: secret, repo: repo)
        } catch {
            try? await plane.removeHook(address.id, signer)
            throw error
        }
    }

    /// obid forgets it and its secret first, then the control plane its address.
    static func remove(id: String, plane: ControlPlane, signer: ControlPlane.Signer, obid: Runner) async throws {
        try await obid.removeHook(id)
        try await plane.removeHook(id, signer)
    }
}
