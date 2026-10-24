import Foundation

/// How the iPhone reaches its Mac (#285): straight to the gateway (#284) on the home network,
/// where Bonjour finds it, and through the Mac's Cloudflare Tunnel from anywhere else. The
/// hostname comes with pairing (the QR code of #284 carries this link's JSON); until pairing
/// exists, Settings takes it typed.
nonisolated struct MacLink: Codable, Equatable, Sendable {
    /// What the Mac calls itself, as its Bonjour service is named.
    var name: String
    /// The tunnel's hostname: oby-<opaque>.<the control plane's device domain>. Through an
    /// Obysphere, only the Mac's name.
    var hostname: String
    /// Paired through the Mac's Obysphere (#1278): the relay's id and the Mac's pinned key,
    /// `<id>.<key>` (neither is secret; the relay token is, and stays in the keychain). Such a Mac is
    /// reached through its relay alone, never by `hostname`, and isn't restored without the relay's
    /// keychain item. Only this iPhone's relay pairing sets it.
    var relayed: String? = nil

    /// Which Mac this is, for what's kept per Mac (its queued messages, its device id, what it pushes
    /// with): through an Obysphere its relay and pinned key, which an invitation can't copy as it can
    /// a name; else its hostname.
    var identity: String { relayed.map { "relay:\($0)" } ?? hostname }

    /// Where the tunnel answers.
    var tunnelURL: URL { URL(string: "https://\(hostname)")! }

    /// Whether `text` is a hostname the control plane makes: `oby-`, 16 or more lowercase letters
    /// or digits, then the zone. Never a deeper name: that would need another certificate. Or the
    /// Mac's Tailscale name, `<machine>.<tailnet>.ts.net` with the port `tailscale serve` gives
    /// obid's gateway (docs/runner-api.md, "obid only: the gateway"): Tailscale makes its certificate.
    static func isHostname(_ text: String) -> Bool {
        guard text.count <= 253 else { return false }
        return text.wholeMatch(of: /oby-[a-z0-9]{16,}(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?){2,}/) != nil
            || text.wholeMatch(of: /[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.[a-z0-9-]{1,63}\.ts\.net(?::[0-9]{1,5})?/) != nil
    }

    /// The hostname in `text` as typed or scanned (spaces around it, capitals, "https://", a path
    /// after it), or nil when there isn't one.
    static func hostname(from text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.firstRange(of: "://") { text = String(text[scheme.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        return isHostname(text) ? text : nil
    }

    /// The link as pairing hands it over, `{"name": …, "hostname": …}`; throws when the hostname
    /// isn't one of the control plane's.
    static func paired(_ data: Data) throws -> MacLink {
        let link = try JSONDecoder().decode(MacLink.self, from: data)
        guard isHostname(link.hostname) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "Not a remote access hostname: \(link.hostname)"))
        }
        return link
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}

/// A Mac reached through its owner's Obysphere (#1278; docs/runner-api.md, "obid only: the phone
/// relay"): what its pairing QR code adds as `link.relay`. The token and the Mac's key are this
/// iPhone's alone: kept in the keychain only (apps/ios/app/Phone.swift, RelayStore), never in the
/// defaults with the link.
nonisolated struct RelayLink: Codable, Equatable, Sendable {
    /// The Obysphere's address.
    var sphere: URL
    /// The relay's id on it: 16 to 32 random bytes, base64url.
    var id: String
    /// This phone's relay token, what its socket opens with: the Sphere keeps only its SHA-256.
    var token: String
    /// The Mac's X25519 public key, base64url: pinned at pairing, every session is sealed to it.
    var key: String

    /// What a link paired through it keeps as `MacLink.relayed`: the relay and the pinned key.
    var pinned: String { "\(id).\(key)" }

    /// The Mac's key as its 32 bytes, or nil when it isn't one.
    var macKey: Data? {
        var text = key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text).flatMap { $0.count == 32 && Self.isBase64URL(key) ? $0 : nil }
    }

    /// Every field as obid makes it (sphere-api.md 9.1), and an Obysphere over HTTPS: plain HTTP
    /// only on this device's own loopback (a Sphere run locally for tests).
    var isValid: Bool {
        let loopback = ["127.0.0.1", "localhost", "::1"].contains(sphere.host() ?? "")
        return (sphere.scheme == "https" || sphere.scheme == "http" && loopback) && sphere.host()?.isEmpty == false
            && (22...43).contains(id.count) && Self.isBase64URL(id) && token.count == 43 && Self.isBase64URL(token) && macKey != nil
    }

    /// Where the phone's socket opens: `GET <sphere>/v0.1/relay/{id}` as a WebSocket.
    var socketURL: URL {
        var parts = URLComponents(url: sphere.appending(path: "v0.1/relay/\(id)"), resolvingAgainstBaseURL: false)!
        parts.scheme = sphere.scheme == "http" ? "ws" : "wss"
        return parts.url!
    }

    private static func isBase64URL(_ text: String) -> Bool {
        text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

/// The way to the Mac right now.
nonisolated enum RemoteRoute: Equatable, Sendable {
    /// On the home network: the gateway's address there, as Bonjour resolved it.
    case home(URL)
    /// Anywhere else: through the tunnel.
    case away(URL)
    /// Through the Mac's Obysphere, every request sealed end to end (apps/shared/PhoneRelay.swift).
    case relay

    /// Where requests are addressed. Through the relay that's a name nothing answers to: what goes
    /// there goes sealed through PhoneRelay or not at all, never over plain HTTP to the Sphere.
    var url: URL {
        switch self {
        case .home(let url), .away(let url): url
        case .relay: Self.relayBase
        }
    }

    static let relayBase = URL(string: "oby-relay://mac")!

    /// Settings' word for it.
    var label: String {
        switch self {
        case .home: "At home, over the local network"
        case .away: "Away, through the tunnel"
        case .relay: "Through your Obysphere, sealed end to end"
        }
    }

    /// The route to a linked Mac: through its Obysphere when it paired through one (a Mac paired
    /// so takes this iPhone through it alone), else the local network when Bonjour found it, else
    /// its tunnel. With no Mac linked there's none, and the iPhone keeps talking to the runner it has.
    static func choose(lan: URL?, link: MacLink?, paired: Bool) -> RemoteRoute? {
        guard paired, let link else { return nil }
        if link.relayed != nil { return .relay }
        if let lan { return .home(lan) }
        return .away(link.tunnelURL)
    }

    /// The gateway's address on the local network, from what Bonjour resolved. Plain HTTP for
    /// now: the gateway (#284) decides what it speaks at home, and #287 encrypts end to end.
    static func lanURL(host: String, port: Int) -> URL? {
        URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)")
    }
}
