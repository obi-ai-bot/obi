import _CryptoExtras
import Crypto
import Foundation
import Synchronization
@testable import ObyEngine

/// How the Watch reaches the runner without its iPhone: watchOS has no Tailscale or VPN, so a
/// Cloudflare Tunnel publishes the Watch API (Runner/WatchAPI.swift), and Cloudflare Access lets
/// through only requests carrying the Access service token the iPhone handed the Watch. Access
/// signs each request it lets through (`Cf-Access-Jwt-Assertion`); the runner checks that JWT
/// against the team's public keys and the application's audience, both from `watch.json` in
/// `OBY_HOME`, which the owner writes on the runner's machine:
///
///     {"url": "https://oby-watch.example.com", "team": "example",
///      "audience": "4714c1358e65fe4b408ad6d432a5f878f08194bdb4752441fd56faefa9b2b6f2",
///      "keys": [{"kid": "…", "kty": "RSA", "alg": "RS256", "n": "…", "e": "AQAB"}]}
///
/// `keys` is the `keys` list of `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`.
struct AccessConfig: Decodable, Equatable, Sendable {
    /// One of the team's signing keys, as Cloudflare publishes them (JWK).
    struct Key: Decodable, Equatable, Sendable {
        var kid: String
        var kty: String
        var alg: String?
        var n: String
        var e: String
    }

    /// The Watch API's public address, through the tunnel: what the iPhone hands the Watch.
    var url: URL
    /// The Zero Trust team name: tokens come from `https://<team>.cloudflareaccess.com`.
    var team: String
    /// The Access application's audience (AUD) tag.
    var audience: String
    var keys: [Key]

    var issuer: String { "https://\(team).cloudflareaccess.com" }

    /// Why it can't be used, or nil.
    var problem: String? {
        if url.scheme != "https" || url.host() == nil { return "url isn't an https address." }
        if team.wholeMatch(of: /[A-Za-z0-9-]{1,63}/) == nil { return "team is the Zero Trust team name, like example for example.cloudflareaccess.com." }
        if audience.isEmpty { return "audience is the Access application's AUD tag." }
        if keys.isEmpty { return "keys is the keys list from https://\(team).cloudflareaccess.com/cdn-cgi/access/certs." }
        return nil
    }
}

/// `watch.json`, read again whenever it changes: Cloudflare rotates the team's keys every six
/// weeks, so the owner pastes the new list in without restarting the runner.
final class AccessFile: Sendable {
    let file: URL
    private let read = Mutex<(changed: Date, config: AccessConfig?)?>(nil)

    init(file: URL) {
        self.file = file
    }

    /// The config as the file says now, or nil when there's none or it can't be used (then the
    /// Watch API lets nothing through).
    var config: AccessConfig? {
        let changed = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        return read.withLock { read in
            guard let changed else {
                read = nil
                return nil
            }
            if let read, read.changed == changed { return read.config }
            var config: AccessConfig?
            do {
                let loaded = try JSONDecoder().decode(AccessConfig.self, from: Data(contentsOf: file))
                if let problem = loaded.problem {
                    Logger.runner.error("\(self.file.path, privacy: .public): \(problem, privacy: .public) The Watch API lets nothing through.")
                } else {
                    config = loaded
                }
            } catch {
                Logger.runner.error("can't read \(self.file.path, privacy: .public): the Watch API lets nothing through")
            }
            read = (changed, config)
            return config
        }
    }
}

/// Checks the JWT Cloudflare Access puts in every request it lets through.
enum AccessToken {
    struct Failure: Error, Equatable {
        var reason: String
    }

    /// Lets the token through when it's an RS256 JWT signed by one of the team's keys, for this
    /// application's audience, from the team's issuer, and current.
    static func check(_ token: String, config: AccessConfig, now: Date = .now) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = decode(parts[0]), let payloadData = decode(parts[1]),
              let signatureData = decode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw Failure(reason: "isn't a JWT")
        }
        // Only what Access signs with: never "none", never a shared-secret algorithm.
        guard header["alg"] as? String == "RS256" else { throw Failure(reason: "isn't signed with RS256") }
        guard let kid = header["kid"] as? String, let jwk = config.keys.first(where: { $0.kid == kid }),
              jwk.kty == "RSA", jwk.alg ?? "RS256" == "RS256",
              let n = decode(Substring(jwk.n)), let e = decode(Substring(jwk.e)),
              let key = try? _RSA.Signing.PublicKey(n: n, e: e) else {
            throw Failure(reason: "isn't signed by one of the team's keys")
        }
        let signed = Data(token.utf8.prefix(parts[0].utf8.count + 1 + parts[1].utf8.count))
        guard key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: signatureData), for: signed, padding: .insecurePKCS1v1_5) else {
            throw Failure(reason: "has a signature that doesn't match")
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(config.audience) else { throw Failure(reason: "is for another application") }
        guard claims["iss"] as? String == config.issuer else { throw Failure(reason: "comes from another team") }
        // A minute either way for clocks that differ.
        let time = now.timeIntervalSince1970
        guard let expires = (claims["exp"] as? NSNumber)?.doubleValue, time < expires + 60 else { throw Failure(reason: "has expired") }
        for claim in ["nbf", "iat"] {
            if let start = (claims[claim] as? NSNumber)?.doubleValue, start > time + 60 { throw Failure(reason: "isn't valid yet") }
        }
    }

    /// base64url, padding optional.
    static func decode(_ text: Substring) -> Data? {
        var base64 = text.replacing("-", with: "+").replacing("_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: String(base64))
    }
}
