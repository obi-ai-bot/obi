import Foundation
import HTTPTypes

/// The public surface of the gateway: exactly the routes the iPhone (Shared/Runner.swift,
/// iOS/JobWaiter.swift) and the Watch through it use. This is deliberately separate from
/// API.router(): adding a runner endpoint never silently makes it available to a phone.
///
/// Kept off on purpose:
/// - `/v1/checks/…`: the Mac's own Apple checks, run by the app on the same Mac over loopback.
/// - `/v1/agent/…`: an agent's own calls from its sandbox, with its job's token, on loopback.
/// - `/v1/connections…`: the Mac app manages connected apps; the phone has no screen for them.
/// - `/v1/speech`: the runner's transcription, which the Watch reaches through its own API
///   (Runner/WatchAPI.swift) and the iPhone does on its own CPU.
/// - `/v1/settings/jobs` (`PUT`) and `/v1/pairing/invite`, `/v1/pairing/devices`: set on the Mac,
///   never from a phone. A paired device can't mint invitations or revoke other devices.
enum GatewayRoutes {
    static let port = 8810

    private static let routes: [(HTTPRequest.Method, String)] = [
        (.get, "/v1/status"), (.get, "/v1/events"),
        // The conversation and its plans.
        (.get, "/v1/conversation"), (.post, "/v1/conversation/stop"),
        (.post, "/v1/plans"), (.post, "/v1/plans/cancel"),
        // Jobs: the list, one job, and what the phone does to it.
        (.get, "/v1/jobs"), (.post, "/v1/jobs"), (.get, "/v1/jobs/*"), (.get, "/v1/jobs/*/wait"),
        (.post, "/v1/jobs/*/stop"), (.post, "/v1/stop-all"),
        (.post, "/v1/jobs/*/dismiss"), (.post, "/v1/jobs/*/move"), (.post, "/v1/jobs/*/start"),
        (.post, "/v1/jobs/*/start-when"), (.post, "/v1/jobs/*/mode"),
        (.post, "/v1/jobs/*/permission"), (.post, "/v1/jobs/*/messages"),
        // Publishing by hand: what to approve, and the phone's signed approval.
        (.get, "/v1/jobs/*/publish"), (.post, "/v1/jobs/*/publish"),
        (.post, "/v1/clear"),
        // The inbox, failures, and an account's weekly reserve.
        (.get, "/v1/inbox"), (.post, "/v1/inbox/*/answer"),
        (.get, "/v1/failures"), (.get, "/v1/failures/*"), (.post, "/v1/failures/*/fix"),
        (.post, "/v1/accounts/*/reserve"),
        // Settings the phone shows and changes, and the permission rules it forgets.
        (.get, "/v1/settings/models"), (.put, "/v1/settings/models"), (.get, "/v1/settings/models/options"),
        (.get, "/v1/settings/jobs"),
        (.get, "/v1/settings/permissions"), (.put, "/v1/settings/permissions"),
        (.get, "/v1/permissions/rules"), (.delete, "/v1/permissions/rules/*"),
        // The phone's publishing key, its push tokens, and the Watch it pairs.
        (.post, "/v1/devices"), (.post, "/v1/activities"), (.post, "/v1/notifications"),
        (.get, "/v1/watches"), (.post, "/v1/watches"), (.delete, "/v1/watches/*")
    ]

    static func allows(method: HTTPRequest.Method, path: String) -> Bool {
        routes.contains { $0.0 == method && matches($0.1, path) }
    }

    private static func matches(_ pattern: String, _ path: String) -> Bool {
        let expected = pattern.split(separator: "/").map(String.init)
        let actual = path.split(separator: "/").map(String.init)
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).allSatisfy { $0 == "*" || $0 == $1 }
    }
}
