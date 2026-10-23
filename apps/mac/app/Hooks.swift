import Foundation
import OSLog

/// Webhooks into obid (#1128; docs/runner-api.md, "obid only: webhooks"): each hook has an address on
/// Oby's control plane, which passes deliveries through this Mac's tunnel to obid, and a secret only
/// obid holds, in its vault. There's no screen for hooks (the owner's decision of 2026-10-23, #1117):
/// a monitoring tool's row in Settings › Connectors makes its hook behind the scenes (#1311, #1312).
/// While this Mac is away, the control plane keeps a hook's deliveries sealed to obid's queue key,
/// and this Mac hands them to obid unopened when it's back (#1315, `HookQueue`).
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

    /// A delivery kept while this Mac was away (#1315), sealed to obid's queue key: only obid opens it.
    struct Kept: Decodable, Equatable, Sendable {
        var id: String
        var hook: String
        var sealed: String
    }

    /// Registers obid's queue key: from then on, a delivery while this Mac is away is kept sealed to it.
    func setQueueKey(_ key: String, _ signer: Signer) async throws {
        _ = try await hookCall("PUT", "v1/installations/self/queue-key", body: ["key": key], signer: signer)
    }

    /// What was kept for this Mac, oldest first, a batch at a time, and how many more there are.
    func kept(_ signer: Signer) async throws -> (items: [Kept], left: Int) {
        struct Answer: Decodable { var items: [Kept]; var left: Int }
        let answer = try Self.decoded(Answer.self, try await hookCall("GET", "v1/installations/self/hooks/queue", signer: signer))
        return (answer.items, answer.left)
    }

    /// obid answered one: it goes.
    func removeKept(_ id: String, _ signer: Signer) async throws {
        _ = try await hookCall("DELETE", "v1/installations/self/hooks/queue/\(id)", signer: signer)
    }

    /// A signed call, as the control plane's own (`send`, private to Engine/, which stays unchanged).
    private func hookCall(_ method: String, _ path: String, body: [String: String]? = nil, signer: Signer) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
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
            /// `accepted`, `duplicate`, `bad signature`, `too large`, `too many` or `unreadable`.
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

    /// obid's queue key's public half (#1315), X9.63 base64url: its private half never leaves obid.
    func queueKey() async throws -> String {
        struct Answer: Decodable { var key: String }
        let answer: Answer = try await call("GET", "v1/hooks/queue-key")
        return answer.key
    }

    /// Hands obid a kept delivery, unopened; obid opens it and checks it as a live one.
    func handOver(_ kept: ControlPlane.Kept) async throws {
        struct Body: Encodable { var hook: String; var sealed: String }
        try await send("POST", "v1/hooks/queued", body: Body(hook: kept.hook, sealed: kept.sealed))
    }
}

/// Deliveries the control plane kept while this Mac was away (#1315): obid's queue key registered
/// there, then what was kept handed to obid unopened, and removed once obid answered. One obid
/// refused (a wrong signature, a box that doesn't open) goes too, since it would be refused again;
/// with obid away or failing, the rest wait for the next try.
enum HookQueue {
    static func register(plane: ControlPlane, signer: ControlPlane.Signer, obid: Runner) async throws {
        try await plane.setQueueKey(try await obid.queueKey(), signer)
    }

    static func collect(plane: ControlPlane, signer: ControlPlane.Signer, obid: Runner) async throws {
        while true {
            let (items, left) = try await plane.kept(signer)
            for item in items {
                do {
                    try await obid.handOver(item)
                } catch let refused as RunnerError where (refused.status ?? 500) < 500 {
                    Logger.remote.notice("obid refused a kept delivery: \(refused.localizedDescription, privacy: .public)")
                }
                try await plane.removeKept(item.id, signer)
            }
            if items.isEmpty || left == 0 { return }
        }
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
        AlertingTool(id: "datadog", name: "Datadog", about: "Monitors from Datadog", source: "datadog", symbol: "pawprint"),
    ]

    /// PagerDuty makes the signing secret itself, once its webhook has Oby's address: the address
    /// comes first, then the secret it shows is pasted back (#1312).
    var secretFromTool: Bool { source == "pagerduty" }

    /// The project's label: PagerDuty's is always the incident's service, Datadog's its `service` tag.
    var asksLabel: Bool { !["pagerduty", "datadog"].contains(source) }

    /// What to paste where, for `url` and `secret` (shown once, then only in obid's vault; PagerDuty's
    /// is its own, so `secret` is empty there); `label` is the one that names the project.
    func steps(url: String, secret: String, label: String = "service") -> String {
        switch source {
        case "datadog":
            return """
            In Datadog: Integrations › Webhooks › New Webhook, named oby.
            URL: \(url)
            Payload, exactly:
            {"oby": 1, "id": "$ID", "monitor": "$ALERT_ID", "cycle": "$ALERT_CYCLE_KEY",
             "transition": "$ALERT_TRANSITION", "type": "$ALERT_TYPE", "priority": "$ALERT_PRIORITY",
             "service": "$TAGS[service]", "title": "$EVENT_TITLE", "link": "$LINK", "date": "$DATE"}
            Custom headers: {"X-Oby-Token": "$OBY_TOKEN"}
            Then Integrations › Webhooks › Variables › New: OBY_TOKEN, hidden from view, the value:
            \(secret)

            Add @webhook-oby to the monitors Oby should hear about. A triggered monitor comes once per
            cycle, P1 as critical, the rest as error; Warn and No Data don't. The project is the service tag.
            """
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
