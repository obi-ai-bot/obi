import Crypto
import Foundation
import HTTPTypes

/// The short lived invitation used by the LAN gateway. The invitation contains no reusable
/// credential: redeeming it atomically consumes both the QR secret and its six digit fallback.
@MainActor
final class Pairing {
    struct Invitation: Codable, Equatable, Sendable {
        var url: String
        var name: String
        var hostname: String
        var link: String
        var secret: String
        var code: String
        var expiresAt: Date
    }

    /// What redeeming buys: the token (shown once) and its digest, and the Mac's name and tunnel
    /// hostname from the invitation, so a phone that typed the code learns them too.
    struct Redeemed: Codable, Equatable, Sendable {
        var token: String
        var digest: String
        var expiresAt: Date
        var deviceID: String? = nil
        var name: String? = nil
        var hostname: String? = nil
    }

    private struct Pending {
        var secretDigest: String
        var codeDigest: String
        var expiresAt: Date
        var attempts: Int
        var name: String
        var hostname: String
    }

    private struct Link: Encodable {
        var name: String
        var hostname: String
    }

    static let maximumAttempts = 5

    private var pending: Pending?
    private let random: () -> Data

    init(random: @escaping () -> Data = { Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }) }) {
        self.random = random
    }

    /// Makes a QR payload and its human fallback. Calling this replaces an earlier invitation.
    func makeInvitation(url: URL, name: String = Host.current().localizedName ?? "Mac", hostname: String? = nil, now: Date = .now) -> Invitation {
        let secret = random().base64URLEncoded
        let code = String(format: "%06d", UInt32.random(in: 0 ... 999_999))
        let expiresAt = now.addingTimeInterval(120)
        let advertisedHostname = hostname ?? url.host ?? "localhost"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let link = String(decoding: (try! encoder.encode(Link(name: name, hostname: advertisedHostname))), as: UTF8.self)
        pending = Pending(secretDigest: Self.digest(secret), codeDigest: Self.digest(code), expiresAt: expiresAt, attempts: 0,
                          name: name, hostname: advertisedHostname)
        return Invitation(url: url.absoluteString, name: name, hostname: advertisedHostname, link: link, secret: secret, code: code, expiresAt: expiresAt)
    }

    /// Redeems an invitation exactly once. The returned token is shown to the phone only once;
    /// callers persist its digest on the Mac and keep the token in the phone's keychain.
    func redeem(_ credential: String, now: Date = .now) throws -> Redeemed {
        guard let pending else { throw APIError(.gone, "That pairing invitation has expired or was already used.") }
        guard now <= pending.expiresAt else {
            self.pending = nil
            throw APIError(.gone, "That pairing invitation has expired or was already used.")
        }
        let digest = Self.digest(credential)
        guard digest == pending.secretDigest || digest == pending.codeDigest else {
            self.pending?.attempts += 1
            if self.pending?.attempts ?? 0 >= Self.maximumAttempts { self.pending = nil }
            throw APIError(.unauthorized, "That pairing code is not valid.")
        }
        self.pending = nil
        let token = random().base64URLEncoded + random().base64URLEncoded
        return Redeemed(token: token, digest: Self.digest(token), expiresAt: .distantFuture, name: pending.name, hostname: pending.hostname)
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
