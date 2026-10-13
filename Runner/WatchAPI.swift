import Foundation
import HTTPTypes
import Hummingbird
@testable import ObyEngine

/// The Watch API: what the Apple Watch uses when its iPhone is out of reach (docs/runner-api.md,
/// "The Watch API"). It's a second listener on 127.0.0.1, which a Cloudflare Tunnel publishes
/// behind Cloudflare Access, and it serves only what the Watch does: the jobs, one job, the event
/// stream, planning, dispatch, a word to a job, Move, Publish, Dismiss, its push tokens and speech. It
/// never trusts `Tailscale-User-Login`: every request needs the Access JWT and a fresh signature
/// from a paired Watch's key (WatchGate). Pairing and unpairing are on the tailnet API, for the
/// iPhone (`pairing(on:)`).
@MainActor
final class WatchAPI {
    let api: API
    let watches: Watches
    nonisolated let access: AccessFile

    /// The largest body the Watch sends: a plan, a message, or a piece of a recording.
    nonisolated static let bodyLimit = 1 << 20
    /// The longest piece of a recording, as WatchConnectivity's (Shared/WatchWire.swift): 1 second
    /// of mono 16-bit PCM at 16 kHz.
    nonisolated static let chunkLimit = 32_000

    init(api: API, watches: Watches, access: AccessFile) {
        self.api = api
        self.watches = watches
        self.access = access
    }

    /// The Watch API's endpoints, behind WatchGate.
    nonisolated func router() -> Router<BasicRequestContext> {
        let router = Router()
        router.add(middleware: WatchGate(api: self))
        router.get("v1/jobs") { request, _ in await self.api.jobs(limit: request.uri.queryParameters.get("limit", as: Int.self) ?? 50) }
        router.get("v1/jobs/:id") { _, context in try await self.api.job(context.parameters.require("id")) }
        router.get("v1/events") { _, _ in await self.api.events() }
        router.post("v1/plans") { request, _ in try await self.api.plan(try await API.decode(PlanRequest.self, from: request)) }
        router.post("v1/conversation/stop") { _, _ in await self.api.stopConversation() }
        router.post("v1/jobs") { request, _ in try await self.api.dispatch(try await API.decode(DispatchRequest.self, from: request)) }
        router.post("v1/jobs/:id/messages") { request, context in
            try await self.api.message(context.parameters.require("id"), try await API.decode(NewMessage.self, from: request))
        }
        router.post("v1/jobs/:id/dismiss") { _, context in try await self.api.dismiss(context.parameters.require("id")) }
        router.post("v1/jobs/:id/start") { _, context in try await self.api.startNow(context.parameters.require("id")) }
        router.post("v1/jobs/:id/move") { request, context in
            try await self.api.move(context.parameters.require("id"), try await API.decode(MoveRequest.self, from: request))
        }
        router.post("v1/jobs/:id/mode") { request, context in
            try await self.api.mode(context.parameters.require("id"), try await API.decode(ModeJSON.self, from: request))
        }
        router.post("v1/jobs/:id/permission") { request, context in
            try await self.api.permission(context.parameters.require("id"), try await API.decode(PermissionAnswer.self, from: request))
        }
        router.get("v1/jobs/:id/publish") { _, context in try await self.api.publishAction(context.parameters.require("id")) }
        router.post("v1/jobs/:id/publish") { request, context in
            try await self.publish(context.parameters.require("id"), try await API.decode(WatchPublish.self, from: request))
        }
        router.post("v1/notifications") { request, _ in
            try await self.notifications(try await API.decode(WatchToken.self, from: request), watch: Self.watch(of: request))
        }
        router.post("v1/speech") { request, _ in try await self.speech(request) }
        return router
    }

    /// Pairing on the tailnet API, behind its owner check: the iPhone lists, pairs and removes Watches.
    nonisolated func pairing(on router: Router<BasicRequestContext>) {
        router.get("v1/watches") { _, _ in await self.list() }
        router.post("v1/watches") { request, _ in try await self.pair(try await API.decode(NewWatch.self, from: request)) }
        router.delete("v1/watches/:id") { _, context in try await self.remove(context.parameters.require("id")) }
    }

    // MARK: Pairing

    func list() -> Response {
        API.json(watches.watches.map { WatchJSON(id: $0.id, name: $0.name, registered: $0.registered) })
    }

    /// A Watch's key, with the phone's Face ID approval of exactly that key, and the Access service
    /// token, which goes to the vault. Answers the Watch's id and the address it calls.
    func pair(_ new: NewWatch, now: Date = .now) throws -> Response {
        guard let config = access.config else {
            throw APIError(.conflict, "Set up the Watch API on the runner first: \(access.file.path) (docs/runner-api.md).")
        }
        try api.devices.checkPairing(new.approval, publicKey: new.publicKey, now: now)
        let id = try watches.pair(name: new.name, publicKey: new.publicKey, clientID: new.accessClientId, clientSecret: new.accessClientSecret, now: now)
        return API.json(["id": id, "url": config.url.absoluteString], status: .created)
    }

    func remove(_ id: String) throws -> Response {
        try watches.remove(id)
        api.push?.forget(watch: id)
        return API.json(["removed": id])
    }

    // MARK: The Watch's own endpoints

    /// WatchGate let the request through: one of these signed it.
    func authorize(_ signed: Watches.Signed, now: Date = .now) throws -> String {
        try watches.check(signed, now: now)
    }

    /// Publishing by hand from the Watch, with the crown: the signed request is the approval, so
    /// only the runner's own sentence for the job, sent exactly, goes through to Publish.
    func publish(_ id: String, _ approval: WatchPublish) async throws -> Response {
        let (job, base) = try api.publishable(id)
        let action = Publish.action(for: job, base: base)
        guard approval.action == action else { throw APIError(.forbidden, "The Watch approved something else. Approve it again.") }
        do {
            let url = try await api.desk.publish(id) { asked in
                guard asked == action else { throw Shell.Failure(message: "Not published: the Watch approved something else.") }
            }
            return API.json(["url": url.absoluteString])
        } catch {
            throw APIError(.conflict, error.localizedDescription)
        }
    }

    /// The Watch's own device token (alerts) or its complications' (WidgetKit push).
    func notifications(_ token: WatchToken, watch: String) throws -> Response {
        let kind = token.kind ?? "alert"
        guard ["alert", "widget"].contains(kind) else { throw APIError(.unprocessableContent, "kind is alert or widget.") }
        guard let push = api.push else { return API.json(["push": false]) }
        return API.json(["push": try push.register(Push.Token(token: token.token, kind: kind, topic: token.topic,
                                                              environment: token.environment, watch: watch))])
    }

    /// A piece of a held recording: `?request=<id>&sequence=<n>`, the body mono 16-bit PCM at
    /// 16 kHz. The runner has no speech-to-text yet, so a well-formed piece is answered `501`
    /// and the Watch falls back to the system's dictation.
    // ponytail: the runner can't write speech down yet; when it can, pieces go to it in order here.
    nonisolated func speech(_ request: Request) async throws -> Response {
        var request = request
        let id = request.uri.queryParameters.get("request").map { String($0) } ?? ""
        guard id.wholeMatch(of: /[A-Za-z0-9-]{8,64}/) != nil,
              let sequence = request.uri.queryParameters.get("sequence", as: Int.self), (0...600).contains(sequence) else {
            throw APIError(.badRequest, "Send ?request=<the hold's id>&sequence=<0, 1, 2…>.")
        }
        let audio = try await request.collectBody(upTo: Self.bodyLimit)
        guard audio.readableBytes > 0, audio.readableBytes <= Self.chunkLimit, audio.readableBytes.isMultiple(of: 2) else {
            throw APIError(.unprocessableContent, "A piece is 2 to \(Self.chunkLimit) bytes of 16-bit PCM.")
        }
        throw APIError(.notImplemented, "Speech-to-text isn't set up on the runner yet. Dictate instead.")
    }

    /// The paired Watch WatchGate checked the request's signature against.
    nonisolated static func watch(of request: Request) -> String {
        request.headers[.obyWatch] ?? ""
    }
}

/// Lets a request into the Watch API only with both: the JWT Cloudflare Access adds to every
/// request it lets through, checked against the team's keys and the application's audience, and a
/// signature from a paired Watch's key over the request, with a time and a nonce, so replays fail.
/// `Tailscale-User-Login` means nothing here.
struct WatchGate<Context: RequestContext>: RouterMiddleware {
    let api: WatchAPI

    @concurrent func handle(_ request: Request, context: Context,
                            next: @concurrent (Request, Context) async throws -> Response) async throws -> Response {
        do {
            guard let config = api.access.config else {
                throw APIError(.serviceUnavailable, "The Watch API isn't set up on the runner.")
            }
            guard let jwt = request.headers[.cfAccessJwtAssertion] else {
                throw APIError(.unauthorized, "This answers only through Cloudflare Access.")
            }
            do {
                try AccessToken.check(jwt, config: config)
            } catch let failure as AccessToken.Failure {
                throw APIError(.unauthorized, "The Cloudflare Access token \(failure.reason).")
            }
            guard let watch = request.headers[.obyWatch], let time = request.headers[.obyTime],
                  let nonce = request.headers[.obyNonce], let signature = request.headers[.obySignature] else {
                throw APIError(.unauthorized, "Sign the request with a paired Watch's key: Oby-Watch, Oby-Time, Oby-Nonce and Oby-Signature.")
            }
            var request = request
            let body = try await request.collectBody(upTo: WatchAPI.bodyLimit)
            _ = try await api.authorize(Watches.Signed(watch: watch, method: request.method.rawValue, target: request.uri.string,
                                                       time: time, nonce: nonce, signature: signature, body: Data(body.readableBytesView)))
            return try await next(request, context)
        } catch let error as APIError {
            return error.response
        } catch let error as HTTPError {
            return APIError(error.status, error.body ?? error.status.reasonPhrase).response
        } catch {
            return APIError(.internalServerError, error.localizedDescription).response
        }
    }
}

extension HTTPField.Name {
    static let cfAccessJwtAssertion = Self("Cf-Access-Jwt-Assertion")!
    static let obyWatch = Self("Oby-Watch")!
    static let obyTime = Self("Oby-Time")!
    static let obyNonce = Self("Oby-Nonce")!
    static let obySignature = Self("Oby-Signature")!
}

// MARK: JSON

/// What `POST /v1/watches` takes from the iPhone.
struct NewWatch: Decodable {
    var name: String
    var publicKey: String
    var accessClientId: String
    var accessClientSecret: String
    var approval: PairingApproval
}

/// The phone's Face ID approval of one Watch's key (Devices.checkPairing).
struct PairingApproval: Decodable {
    var device: String
    var signedAt: String
    var signature: String
}

/// A paired Watch as `GET /v1/watches` lists it: never its key or the token.
struct WatchJSON: Encodable {
    var id: String
    var name: String
    var registered: Date
}

/// The Watch's Publish: the runner's sentence, sent back exactly.
struct WatchPublish: Decodable {
    var action: String
}

struct WatchToken: Decodable {
    var token: String
    var topic: String
    var environment: String
    /// "alert" (the default) or "widget".
    var kind: String?
}
