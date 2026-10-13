import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import NIOHTTP1
import NIOCore
@testable import ObyEngine

/// The LAN boundary for a Mac's runner (#284). The gateway owns device authentication and route
/// policy, then forwards an allowed request to the loopback API with the runner's own token. The
/// API stays loopback-only. Invitations are made there, never here (`POST /v1/pairing/invite`,
/// Runner/API.swift): a phone reaching the gateway can redeem one, not mint one.
@MainActor
final class Gateway {
    struct RedeemRequest: Decodable { var credential: String; var name: String? }

    let devices: Devices
    let pairing: Pairing
    let upstream: URL
    let owner: String
    /// The runner's own token (Engine/LocalRunner.swift), sent as `Authorization: Bearer` on every
    /// forwarded request: a Mac runner answers nothing without it. Nil for a tailnet runner, whose
    /// gate reads the login header instead.
    private let upstreamToken: String?
    private let vault: Vault
    /// The account homes, read when a response is scrubbed: Settings can add one while the runner runs.
    private let homes: @MainActor () -> [String]
    private let client: HTTPClient

    init(devices: Devices, pairing: Pairing? = nil, upstream: URL = URL(string: "http://127.0.0.1:7777")!, owner: String = "owner",
         upstreamToken: String? = nil, homes: @escaping @MainActor () -> [String] = { [] }, client: HTTPClient = .init(), vault: Vault = .shared) {
        self.devices = devices
        self.pairing = pairing ?? Pairing()
        self.upstream = upstream
        self.owner = owner
        self.upstreamToken = upstreamToken
        self.homes = homes
        self.client = client
        self.vault = vault
    }

    deinit {
        try? client.syncShutdown()
    }

    func router() -> Router<BasicRequestContext> {
        let router = Router()
        router.post("v1/pairing") { request, _ in try await self.redeem(request) }
        for method in [HTTPRequest.Method.get, .post, .put, .patch, .delete] {
            router.on("v1/**", method: method) { request, _ in try await self.forward(request, method: method) }
        }
        return router
    }

    func redeem(_ credential: String, name: String = "iPhone", now: Date = .now) throws -> Pairing.Redeemed {
        let redeemed = try pairing.redeem(credential, now: now)
        let device = try devices.addGatewayToken(digest: redeemed.digest, name: name, now: now)
        return Pairing.Redeemed(token: redeemed.token, digest: redeemed.digest, expiresAt: device.expiresAt, deviceID: device.id,
                                name: redeemed.name, hostname: redeemed.hostname)
    }

    private func redeem(_ request: Request) async throws -> Response {
        var request = request
        let body = try await request.collectBody(upTo: 64 * 1024)
        let value = try JSONDecoder().decode(RedeemRequest.self, from: Data(body.readableBytesView))
        let redeemed = try redeem(value.credential, name: value.name ?? "iPhone")
        let link: RedeemResponse.Link? = if let name = redeemed.name, let hostname = redeemed.hostname { .init(name: name, hostname: hostname) } else { nil }
        return API.json(RedeemResponse(token: redeemed.token, deviceID: redeemed.deviceID, expiresAt: redeemed.expiresAt, link: link))
    }

    /// What redeeming answers: the device token, and the Mac's link (its name and tunnel hostname)
    /// so a phone that typed the six digits learns where the Mac is away from home.
    private struct RedeemResponse: Encodable {
        struct Link: Encodable {
            var name: String
            var hostname: String
        }

        var token: String
        var deviceID: String?
        var expiresAt: Date
        var link: Link?
    }

    private func forward(_ request: Request, method: HTTPRequest.Method) async throws -> Response {
        let path = request.uri.path
        guard GatewayRoutes.allows(method: method, path: path) else {
            throw APIError(.notFound, "That route isn't available through the gateway.")
        }
        guard let authorization = request.headers[.authorization], authorization.hasPrefix("Bearer "),
              devices.acceptsGatewayToken(String(authorization.dropFirst(7))) else {
            throw APIError(.unauthorized, "Every gateway request needs a device token.")
        }

        var request = request
        let body = try await request.collectBody(upTo: 4 << 20)
        var components = URLComponents(url: upstream.appending(path: String(path.dropFirst())), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = request.uri.query
        let url = components.url!
        var headers = NIOHTTP1.HTTPHeaders()
        if let contentType = request.headers[.contentType] { headers.add(name: "content-type", value: String(contentType)) }
        // The runner's gate: its own token on a Mac, the owner's login on the tailnet.
        if let upstreamToken {
            headers.add(name: "authorization", value: "Bearer \(upstreamToken)")
        } else {
            headers.add(name: "Tailscale-User-Login", value: owner)
        }
        let httpMethod = NIOHTTP1.HTTPMethod(rawValue: method.rawValue)
        let forwarded = try HTTPClient.Request(url: url, method: httpMethod, headers: headers,
                                               body: body.readableBytes == 0 ? nil : .bytes(Array(body.readableBytesView)))
        let delegate = GatewayStreamDelegate(scrubber: GatewayScrubber(leaks: vault.redacting(), paths: homes()))
        let task = client.execute(request: forwarded, delegate: delegate)
        delegate.set(task: task)
        var headIterator = delegate.head.makeAsyncIterator()
        guard let head = try await headIterator.next() else {
            throw APIError(.serviceUnavailable, "The gateway got no response from the runner.")
        }
        var resultHeaders: HTTPFields = [.contentType: "application/json"]
        if let type = head.headers.first(name: "content-type") { resultHeaders[.contentType] = type }
        return Response(status: HTTPResponse.Status(code: Int(head.status.code)), headers: resultHeaders,
                        body: ResponseBody(asyncSequence: delegate.body))
    }
}

/// What never leaves the Mac in a gateway response: the vault's secrets, an agent's session id
/// (a job's `session`, which resumes the agent's own conversation) and the paths of the accounts'
/// homes. JSON is read and written back with the hidden keys null and the paths taken out, then
/// the vault's redaction runs over the text, as it does for logs.
nonisolated struct GatewayScrubber: Sendable {
    var leaks: Leaks
    var paths: [String]
    /// JSON keys whose values are an agent's session id: sent as null.
    static let hidden: Set<String> = ["session"]
    static let marker = "[home]"

    /// A whole body.
    func document(_ text: String) -> String {
        leaks.redact(withoutPaths(json(text)))
    }

    /// One server-sent event frame: each `data:` line's JSON, as a document.
    func frame(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("data:") else { return String(line) }
            let payload = line.dropFirst("data:".count).drop(while: { $0 == " " })
            return "data: " + json(String(payload))
        }
        return leaks.redact(withoutPaths(lines.joined(separator: "\n")))
    }

    /// `text` as JSON with the hidden keys null and the paths out of every string, or `text` as
    /// it came when it isn't JSON or nothing in it changes.
    private func json(_ text: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) else { return text }
        var changed = false
        func scrub(_ value: Any) -> Any {
            switch value {
            case let fields as [String: Any]:
                var clean: [String: Any] = [:]
                for (key, value) in fields {
                    if Self.hidden.contains(key), !(value is NSNull) {
                        clean[key] = NSNull()
                        changed = true
                    } else {
                        clean[key] = scrub(value)
                    }
                }
                return clean
            case let list as [Any]:
                return list.map(scrub)
            case let text as String:
                let clean = withoutPaths(text)
                if clean != text { changed = true }
                return clean
            default:
                return value
            }
        }
        let clean = scrub(object)
        guard changed, let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func withoutPaths(_ text: String) -> String {
        var text = text
        for path in paths where !path.isEmpty && text.contains(path) {
            text = text.replacingOccurrences(of: path, with: Self.marker)
        }
        return text
    }
}

/// Bridges AsyncHTTPClient's delegate callbacks to Hummingbird's streaming response body. A
/// finite body is scrubbed whole once it's in; an event stream frame by frame, so a secret split
/// across network chunks is held until its frame boundary instead of being sent in pieces.
private final class GatewayStreamDelegate: HTTPClientResponseDelegate, @unchecked Sendable {
    typealias Response = Void

    let head: AsyncThrowingStream<HTTPResponseHead, Error>
    let body: AsyncThrowingStream<ByteBuffer, Error>
    private let headContinuation: AsyncThrowingStream<HTTPResponseHead, Error>.Continuation
    private let bodyContinuation: AsyncThrowingStream<ByteBuffer, Error>.Continuation
    private let taskBox = TaskBox()
    private let scrubber: GatewayScrubber
    private var pending: [UInt8] = []
    private var streaming = false
    private static let maximumPendingBytes = 8 << 20

    init(scrubber: GatewayScrubber) {
        self.scrubber = scrubber
        (head, headContinuation) = AsyncThrowingStream.makeStream(of: HTTPResponseHead.self)
        (body, bodyContinuation) = AsyncThrowingStream.makeStream(of: ByteBuffer.self)
        headContinuation.onTermination = { [weak taskBox] _ in taskBox?.task?.cancel() }
        bodyContinuation.onTermination = { [weak taskBox] _ in taskBox?.task?.cancel() }
    }

    func set(task: HTTPClient.Task<Void>) {
        taskBox.task = task
    }

    func didReceiveHead(task: HTTPClient.Task<Void>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        streaming = head.headers.first(name: "content-type")?.lowercased().hasPrefix("text/event-stream") == true
        headContinuation.yield(head)
        return task.eventLoop.makeSucceededFuture(())
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        pending.append(contentsOf: buffer.readableBytesView)
        if pending.count > Self.maximumPendingBytes {
            bodyContinuation.finish(throwing: GatewayStreamError.frameTooLarge)
            task.cancel()
            return task.eventLoop.makeFailedFuture(GatewayStreamError.frameTooLarge)
        }
        guard streaming else { return task.eventLoop.makeSucceededFuture(()) }
        while let end = frameEnd() {
            let frame = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(..<end)
            bodyContinuation.yield(ByteBuffer(string: scrubber.frame(frame)))
        }
        return task.eventLoop.makeSucceededFuture(())
    }

    /// The index after the first blank line in `pending`: the end of a complete frame.
    private func frameEnd() -> Int? {
        guard pending.count >= 2 else { return nil }
        for index in 1..<pending.count where pending[index - 1] == 10 && pending[index] == 10 { return index + 1 }
        return nil
    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws -> Void {
        if !pending.isEmpty {
            let text = String(decoding: pending, as: UTF8.self)
            bodyContinuation.yield(ByteBuffer(string: streaming ? scrubber.frame(text) : scrubber.document(text)))
        }
        headContinuation.finish()
        bodyContinuation.finish()
    }

    func didReceiveError(task: HTTPClient.Task<Void>, _ error: Error) {
        headContinuation.finish(throwing: error)
        bodyContinuation.finish(throwing: error)
    }
}

private enum GatewayStreamError: Error {
    case frameTooLarge
}

private final class TaskBox: @unchecked Sendable {
    var task: HTTPClient.Task<Void>?
}
