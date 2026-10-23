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
        var projectLabel: String?
    }

    func hooks() async throws -> [HookRow] {
        try await call("GET", "v1/hooks")
    }

    /// Gives obid a hook the control plane made, with its secret, which obid keeps in its vault.
    func addHook(id: String, url: URL, name: String, source: String, secret: String, repo: String?, projectLabel: String? = nil) async throws -> HookRow {
        struct Body: Encodable { var id: String; var url: String; var name: String; var source: String; var secret: String; var repo: String?; var projectLabel: String? }
        return try await call("POST", "v1/hooks", body: Body(id: id, url: url.absoluteString, name: name, source: source, secret: secret,
                                                           repo: repo, projectLabel: projectLabel))
    }

    /// obid's hooks, or nil from a runner without them (404).
    func hooksIfAny() async throws -> [HookRow]? {
        do { return try await hooks() } catch let error as RunnerError where error.status == 404 { return nil }
    }

    /// obid's repositories, the ones a hook's alerts may be about (`GET /v1/obid/repos`).
    func repos() async throws -> [String] {
        try await call("GET", "v1/obid/repos")
    }

    func removeHook(_ id: String) async throws {
        try await send("DELETE", "v1/hooks/\(id)")
    }
}

/// The monitoring tools whose rows in Settings › Connectors make a hook (#1311, #1312): the row's id
/// and name, its line, obid's source, and how the tool is set up to send to the hook.
nonisolated struct AlertingTool: Equatable, Sendable {
    var id: String
    var name: String
    var about: String
    var source: String
    /// SF Symbol: none of these has a mark in Sangam's brands.tsx.
    var symbol: String

    static let all = [
        AlertingTool(id: "prometheus", name: "Prometheus", about: "Alerts from Alertmanager", source: "alertmanager", symbol: "flame"),
        AlertingTool(id: "grafana", name: "Grafana", about: "Alerts from Grafana", source: "grafana", symbol: "chart.xyaxis.line"),
        AlertingTool(id: "pagerduty", name: "PagerDuty", about: "Incidents from PagerDuty", source: "pagerduty", symbol: "bell.badge"),
    ]

    /// PagerDuty makes the signing secret itself, once its webhook has Oby's address: the address
    /// comes first, then the secret it shows is pasted back (#1312).
    var secretFromTool: Bool { source == "pagerduty" }

    /// The project's label: PagerDuty's is always the incident's service.
    var asksLabel: Bool { source != "pagerduty" }

    /// What to paste where, for `url` and `secret` (shown once, then only in obid's vault; PagerDuty's
    /// is its own, so `secret` is empty there); `label` is the one that names the project.
    func steps(url: String, secret: String, label: String = "service") -> String {
        switch source {
        case "pagerduty":
            return """
            In PagerDuty: Integrations › Generic Webhooks (v3) › New Webhook.
            Webhook URL: \(url)
            Scope: the service or team whose incidents Oby should hear about.
            Event subscription: incident.triggered, incident.reopened and incident.resolved.

            PagerDuty then shows its signing secret once: paste it below. High-urgency incidents come
            as critical, low as error; the project is the incident's service.
            """
        case "alertmanager":
            return """
            Alertmanager 0.28 or later. Add a receiver and route your alerts to it:

            receivers:
              - name: oby
                webhook_configs:
                  - url: \(url)
                    http_config:
                      http_headers:
                        X-Oby-Token:
                          secrets: ["\(secret)"]

            Critical and error alerts come to Oby; warnings don't. The project is the alert's \(label) label.
            """
        default:
            return """
            Grafana 12 or later: Alerting › Contact points › Add contact point › Webhook.
            URL: \(url)
            Optional settings › HMAC signature: Secret \(secret), Timestamp header X-Grafana-Alerting-Timestamp.
            Then send your alerts' notification policy to that contact point.

            Critical and error alerts come to Oby; warnings don't. The project is the alert's \(label) label.
            """
        }
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

    static func make(name: String, source: String, repo: String?, secret: String, projectLabel: String? = nil,
                     plane: ControlPlane, signer: ControlPlane.Signer, obid: Runner) async throws -> Runner.HookRow {
        let address = try await plane.createHook(signer)
        do {
            return try await obid.addHook(id: address.id, url: address.url, name: name, source: source, secret: secret, repo: repo,
                                          projectLabel: projectLabel)
        } catch {
            // In a task of its own, so a cancelled caller doesn't leave the address behind.
            await Task { try? await plane.removeHook(address.id, signer) }.value
            throw error
        }
    }

    /// obid keeps a hook whose address was made first (`reserve`, PagerDuty's), with the secret the
    /// tool showed.
    static func finish(_ address: ControlPlane.Hook, name: String, source: String, repo: String?, secret: String, obid: Runner) async throws -> Runner.HookRow {
        try await obid.addHook(id: address.id, url: address.url, name: name, source: source, secret: secret, repo: repo)
    }

    /// obid forgets it and its secret first, then the control plane its address. One obid no longer
    /// has (an earlier try got that far) goes on to the address.
    static func remove(id: String, plane: ControlPlane, signer: ControlPlane.Signer, obid: Runner) async throws {
        do {
            try await obid.removeHook(id)
        } catch let gone as RunnerError where gone.status == 404 {}
        try await plane.removeHook(id, signer)
    }
}
