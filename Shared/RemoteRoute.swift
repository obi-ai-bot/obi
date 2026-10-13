import Foundation

/// How the iPhone reaches its Mac (#285): straight to the gateway (#284) on the home network,
/// where Bonjour finds it, and through the Mac's Cloudflare Tunnel from anywhere else. The
/// hostname comes with pairing (the QR code of #284 carries this link's JSON); until pairing
/// exists, Settings takes it typed.
nonisolated struct MacLink: Codable, Equatable, Sendable {
    /// What the Mac calls itself, as its Bonjour service is named.
    var name: String
    /// The tunnel's hostname: oby-<opaque>.tetrix.pro.
    var hostname: String
    /// The device id pinned by the Mac during pairing.
    var deviceID: String? = nil
    /// The Mac gateway's pinned X25519 public key, carried by pairing. Nil only for links created
    /// before E2E was introduced; a gateway that has paired keys refuses those legacy links.
    var publicKey: Data? = nil
    /// Where the tunnel answers.
    var tunnelURL: URL { URL(string: "https://\(hostname)")! }

    /// Whether `text` is a hostname the control plane makes: `oby-`, 16 or more lowercase letters
    /// or digits, then the zone. Never a deeper name: that would need another certificate.
    static func isHostname(_ text: String) -> Bool {
        text.wholeMatch(of: /oby-[a-z0-9]{16,}(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?){2,}/) != nil && text.count <= 253
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
        if let publicKey = link.publicKey, publicKey.count != 32 {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "The Mac's E2E public key isn't X25519."))
        }
        return link
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}

/// The short-lived payload shown by the Mac when it opens device pairing. The gateway key is
/// carried in the QR so the first cleartext response is pinned before it is accepted.
nonisolated struct PairingQR: Codable, Equatable, Sendable {
    var name: String
    var hostname: String
    var secret: String
    var gatewayPublicKey: Data

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}

/// The way to the Mac right now.
nonisolated enum RemoteRoute: Equatable, Sendable {
    /// On the home network: the gateway's address there, as Bonjour resolved it.
    case home(URL)
    /// Anywhere else: through the tunnel.
    case away(URL)

    var url: URL {
        switch self {
        case .home(let url), .away(let url): url
        }
    }

    /// Settings' word for it.
    var label: String {
        switch self {
        case .home: "At home, over the local network"
        case .away: "Away, through the tunnel"
        }
    }

    /// The route to a linked Mac: the local network when Bonjour found it, else its tunnel. With
    /// no Mac linked there's none, and the iPhone keeps talking to the runner it has.
    static func choose(lan: URL?, link: MacLink?) -> RemoteRoute? {
        guard let link else { return nil }
        if let lan { return .home(lan) }
        return .away(link.tunnelURL)
    }

    /// The gateway's address on the local network, from what Bonjour resolved. HTTP transport is
    /// acceptable here because the body is sealed end to end by the client session.
    static func lanURL(host: String, port: Int) -> URL? {
        URL(string: "http://\(host.contains(":") ? "[\(host)]" : host):\(port)")
    }
}
