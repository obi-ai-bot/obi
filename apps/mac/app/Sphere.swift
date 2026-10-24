import AppKit
import CryptoKit
import Foundation
import Observation

// The owner's side of the Obysphere (obi-sphere's spec/identity.md): the owner key, which only
// this app holds (obid holds the Obi key, never this one), what it signs (the Obi's card, the
// delegation, the admin's own short assertions), and the Sphere calls an owner makes. obid does
// the Obi's part: docs/runner-api.md, "obid only: Sphere membership".

// MARK: The owner key

/// The owner's Ed25519 key (identity.md section 1), made once and kept in the login keychain,
/// this Mac only. The Secure Enclave can't hold an Ed25519 key, so it's a generic password.
// ponytail: one owner key per Mac; the same person on a second Mac needs this key (the Sphere
// binds one per owner), which iCloud Keychain could carry later.
nonisolated struct OwnerKey: Sendable {
    static let store = KeychainVault(service: "com.deskree.oby.owner", label: "Oby owner")
    let pair: Curve25519.Signing.PrivateKey

    /// `owner`'s key, made and saved the first time.
    static func of(_ owner: String) throws -> OwnerKey {
        if let saved = try store.value(owner), let raw = Data(base64url: saved) {
            return OwnerKey(pair: try Curve25519.Signing.PrivateKey(rawRepresentation: raw))
        }
        let key = Curve25519.Signing.PrivateKey()
        try store.save(key.rawRepresentation.base64url, as: owner)
        return OwnerKey(pair: key)
    }

    var publicKey: String { pair.publicKey.rawRepresentation.base64url }
    /// `ed25519:` and base64url of SHA-256 over the public key (identity.md section 1).
    var keyId: String { Self.keyId(of: pair.publicKey.rawRepresentation) }
    static func keyId(of raw: Data) -> String { "ed25519:" + Data(SHA256.hash(data: raw)).base64url }

    /// A JWT signed with this key (identity.md 4.1).
    func jwt(_ claims: [String: Any]) throws -> String {
        let header = Canonical.json(["alg": "EdDSA", "kid": keyId, "typ": "JWT"]).base64url
        let input = header + "." + Canonical.json(claims).base64url
        return input + "." + (try pair.signature(for: Data(input.utf8))).base64url
    }

    /// An owner assertion for `sphere`: the owner's own for 300 seconds, or with `mayAct` a
    /// delegation to that Obi for 30 days, the longest a delegation lives.
    func assertion(owner: String, sphere: String, scope: String, mayAct: String? = nil, now: Date = .now) throws -> String {
        let iat = Int(now.timeIntervalSince1970)
        var claims: [String: Any] = ["iss": owner, "sub": owner, "aud": "obi-sphere:\(sphere)", "iat": iat,
                                     "exp": iat + (mayAct == nil ? 300 : 2_592_000), "jti": UUID().uuidString.lowercased(), "scope": scope]
        if let mayAct { claims["may_act"] = ["sub": mayAct] }
        return try jwt(claims)
    }

    /// `card` with this key's one signature (identity.md 2.1): a detached JWS over the canonical
    /// JSON of the card without `signatures`.
    func sign(card: [String: Any]) throws -> [String: Any] {
        var card = card
        card.removeValue(forKey: "signatures")
        let protected = Canonical.json(["alg": "EdDSA", "kid": keyId, "typ": "JOSE"]).base64url
        let input = protected + "." + Canonical.json(card).base64url
        card["signatures"] = [["protected": protected, "signature": (try pair.signature(for: Data(input.utf8))).base64url]]
        return card
    }
}

/// RFC 8785 canonical JSON for what the protocol uses: objects, arrays, strings, integers,
/// booleans and null (protocol.md has no fractions).
nonisolated enum Canonical {
    static func json(_ value: Any) -> Data { Data(text(value).utf8) }

    static func text(_ value: Any) -> String {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): number.boolValue ? "true" : "false"
        case let number as NSNumber: String(number.int64Value)
        case let string as String: quoted(string)
        case let list as [Any]: "[" + list.map(text).joined(separator: ",") + "]"
        case let object as [String: Any]:
            // Keys in order of their UTF-16 code units.
            "{" + object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
                .map { quoted($0) + ":" + text(object[$0]!) }.joined(separator: ",") + "}"
        default: "null"
        }
    }

    private static func quoted(_ string: String) -> String {
        var out = "\""
        for unit in string.unicodeScalars {
            switch unit {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(unit)
            }
        }
        return out + "\""
    }
}

extension Data {
    nonisolated var base64url: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated init?(base64url: String) {
        var text = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}

// MARK: The Sphere, as its owner calls it

/// The Sphere's HTTP API (spec/sphere-api.md) for what an owner does: create it (with the
/// operator token), get an owner's own token, invite, write the policy, read the directory.
nonisolated struct SphereServer: Sendable {
    let base: URL

    static let tokenExchange = "urn:ietf:params:oauth:grant-type:token-exchange"
    static let jwtType = "urn:ietf:params:oauth:token-type:jwt"

    /// Why the owner's signatures can't go to `url`, or nil: only https, to a public name. Not a
    /// name on this Mac, the network it's on or the tailnet, and never an IP address, so a link
    /// can't aim them at the Mac's own services. A public name that resolves to a private address
    /// still gets through: the TLS certificate has to match it.
    static func problem(_ url: URL) -> String? {
        guard url.scheme == "https" else { return "An Obysphere's address starts with https://." }
        // Just the origin: obid takes no path either, and links are made from it.
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, ["", "/"].contains(url.path()) else {
            return "An Obysphere's address is https:// and its name only, like https://sphere.example.com."
        }
        let host = (url.host() ?? "").lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let top = labels.last.map(String.init) ?? ""
        let named = labels.count >= 2 && !labels.contains(where: \.isEmpty)
            && (top.allSatisfy { $0 >= "a" && $0 <= "z" } && top.count >= 2 || top.hasPrefix("xn--"))
        let local = ["localhost", "local", "internal", "lan", "home.arpa", "ts.net"].contains { host == $0 || host.hasSuffix(".\($0)") }
        return named && !local ? nil : "\(host.isEmpty ? "That address" : host) isn't a public Obysphere address."
    }

    // ponytail: a var only so SphereTests can put a fake Obysphere in front (their suite is serialized).
    nonisolated(unsafe) static var session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    func call(_ method: String, _ path: String, bearer: String? = nil, json: Any? = nil,
              form: [String: String]? = nil) async throws -> [String: Any] {
        if let problem = Self.problem(base) { throw RunnerError(message: problem) }
        var request = URLRequest(url: base.appending(path: "v0.1").appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let form {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            request.httpBody = Data(form.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
                .joined(separator: "&").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw RunnerError(message: "The Obysphere at \(base.host() ?? base.absoluteString) can't be reached: \(error.localizedDescription)")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // The Sphere's error, or the token endpoint's OAuth one.
            let error = object["error"] as? [String: Any]
            let code = error?["code"] as? String ?? object["error"] as? String ?? "\(status)"
            let message = error?["message"] as? String ?? object["error_description"] as? String ?? ""
            throw RunnerError(message: "The Obysphere refused it: \(code)\(message.isEmpty ? "" : ": \(message)")", status: status)
        }
        return object
    }

    /// Signs the owner in with Google for `key` (spec sphere-api.md section 3.1): the Sphere's
    /// sign-in page in the system's web sheet, which comes back to `obi-sphere://signin` with the
    /// one-time code. Answers `{"state", "code"}`, for the one call that needs it.
    @MainActor
    func signIn(key: OwnerKey) async throws -> [String: String] {
        let started = try await call("POST", "signin/google", json: ["owner_key": key.publicKey])
        guard let page = (started["url"] as? String).flatMap(URL.init(string:)), page.scheme == "https",
              let state = started["state"] as? String else { throw RunnerError(message: "The Obysphere gave no sign-in page.") }
        let back = try await WebSignIn.run(page, scheme: "obi-sphere")
        let items = URLComponents(url: back, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == state, let code = value("code") else {
            throw RunnerError(message: "The sign-in didn't finish, or that account can't do this here.")
        }
        return ["state": state, "code": code]
    }

    /// The owner's own token for `sphere` (identity.md 4.3, no actor), for `scope`: `admin` only
    /// to invite or set the Sphere up, `directory:read` to read it.
    func ownerToken(owner: String, sphere: String, key: OwnerKey, scope: String) async throws -> String {
        let answer = try await call("POST", "oauth/token", form: [
            "grant_type": Self.tokenExchange, "subject_token_type": Self.jwtType,
            "subject_token": try key.assertion(owner: owner, sphere: sphere, scope: scope),
        ])
        guard let token = answer["access_token"] as? String else { throw RunnerError(message: "The Obysphere gave no token.") }
        return token
    }
}

/// Follows no redirect: one would carry the owner's signatures to another address.
// ponytail: the completion-handler form; Swift 6.4 crashes emitting the async one's ObjC thunk.
nonisolated final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: The invite link

/// An invitation to pass on, as a link (onboarding.md section 4, "Joining"): the Sphere's address,
/// with the rest after `#`, so the secret never reaches a server in a request. A named one is for
/// one person (`for`, `obi`); an open one is one link for a team (sphere-api.md section 4), maybe
/// only for one Google Workspace's people (`domain`, which the Sphere enforces with a sign-in).
nonisolated struct InviteLink: Equatable, Sendable {
    var server: URL
    var sphere: String
    var name: String
    var by: String
    var owner: String?
    var obi: String?
    var id: String
    var secret: String
    /// Only what the link says until the Sphere's preview says it (`SphereModel.preview`).
    var domain: String?
    var members: Int?

    var link: String {
        var parts = URLComponents()
        let named = owner.map { [("for", $0), ("obi", obi ?? "")] } ?? []
        parts.queryItems = ([("sphere", sphere), ("name", name), ("by", by)] + named + (domain.map { [("domain", $0)] } ?? []) + [("id", id), ("secret", secret)])
            .map { URLQueryItem(name: $0, value: $1) }
        return server.appending(path: "join").absoluteString + "#" + (parts.percentEncodedQuery ?? "")
    }

    init(server: URL, sphere: String, name: String, by: String, owner: String? = nil, obi: String? = nil, id: String, secret: String, domain: String? = nil) {
        (self.server, self.sphere, self.name, self.by, self.owner, self.obi, self.id, self.secret, self.domain) = (server, sphere, name, by, owner, obi, id, secret, domain)
    }

    /// The Sphere's address, as the Join screen shows it.
    var host: String { server.host() ?? server.absoluteString }

    /// What the Join screen warns of, or nil for the Obysphere server Oby knows. Everything else in
    /// the link (its name, who sent it) is only what the link says.
    // ponytail: one known server until `<name>.obysphere.com`; then any host under it.
    var warning: String? {
        server == SphereModel.server ? nil
            : "This link is for \(host), not the Obysphere server Oby knows. Joining lets that server act for your Oby for 30 days. Join only if you trust \(host)."
    }

    /// Why this Mac's Oby can't use this link, or nil: a named one is for one owner.
    func mismatch(owner mine: String) -> String? {
        guard let owner, owner != mine else { return nil }
        return "This invite is for \(owner), and this Mac's Oby acts for \(mine). Ask \(by.isEmpty ? "the admin" : by) for one for \(mine)."
    }

    /// The link an Obysphere's join page's Open in Oby stands for: `oby://join/<host>#<fragment>` is
    /// `https://<host>/join#<fragment>`. Nil for any other link, or a host that isn't a public https
    /// Obysphere's (the init below checks it with `SphereServer.problem`).
    init?(opened url: URL) {
        guard url.scheme == "oby", url.host() == "join", url.query() == nil, let fragment = url.fragment(percentEncoded: true) else { return nil }
        let host = String(url.path(percentEncoded: true).dropFirst())
        guard host.wholeMatch(of: /[A-Za-z0-9.-]+(:[0-9]{1,5})?/) != nil else { return nil }
        self.init("https://\(host)/join#\(fragment)")
    }

    /// The link as pasted, or nil when it isn't one, or its address isn't a public https one.
    init?(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" || url.scheme == "http",
              let host = url.host(), url.path() == "/join", let fragment = url.fragment(percentEncoded: true) else { return nil }
        var parts = URLComponents()
        parts.percentEncodedQuery = fragment
        let items = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        var origin = URLComponents()
        (origin.scheme, origin.host, origin.port) = (url.scheme, host, url.port)
        let owner = items["for"], obi = items["obi"]
        guard let server = origin.url, SphereServer.problem(server) == nil, let sphere = items["sphere"],
              let id = items["id"], let secret = items["secret"], ![sphere, id, secret].contains(where: \.isEmpty),
              (owner == nil) == (obi == nil), owner?.isEmpty != true, obi?.isEmpty != true else { return nil }
        self.init(server: server, sphere: sphere, name: items["name"].flatMap { $0.isEmpty ? nil : $0 } ?? sphere,
                  by: items["by"] ?? "", owner: owner, obi: obi, id: id, secret: secret, domain: items["domain"].flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// The invite an `oby://join` link opened (AppDelegate), until Settings › Obysphere shows it.
@MainActor @Observable
final class OpenedInvite {
    static let shared = OpenedInvite()
    var invite: InviteLink?
}

// MARK: Host your own

/// Settings › Obysphere › Host your own. Deploy… makes the operator token and copies it; the address
/// pasted back is checked only when asked (Return or Check), without the token; the token goes to
/// that host only once the owner confirms it's theirs, to check the server has it, and is then
/// kept under that host and nowhere else.
@MainActor @Observable
final class HostOwn {
    static let shared = HostOwn()
    static let deployPage = URL(string: "https://deploy.workers.cloudflare.com/?url=https://github.com/obi-ai-bot/obi-sphere/tree/main/server")!

    /// The token made for the deploy, and the clipboard's change count once Oby copied it. Only in
    /// memory: one never used is forgotten when Oby quits or Deploy… makes another.
    var made: (token: String, clipboard: Int)?
    /// What's typed or pasted: changing it asks nothing, and takes back a check.
    var address = "" { didSet { if address != oldValue { (checked, problem) = (nil, nil) } } }
    /// The address checked, waiting for the owner to say it's theirs.
    var checked: URL?
    var problem: String?
    private(set) var busy = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pasteboard: NSPasteboard

    init(defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general) {
        (self.defaults, self.pasteboard) = (defaults, pasteboard)
    }

    /// A new token, 32 random bytes in base64url (the server takes 32 characters or more), on this
    /// Mac's clipboard only; the page to open.
    func deploy() -> URL {
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64url
        made = (token, SphereSettingsView.copySecret(token, to: pasteboard))
        return Self.deployPage
    }

    /// Return or Check: `address` (https:// may be left out) is a public https address where an
    /// Obysphere answers, asked without the token. When a token was made, the server must have one:
    /// an empty `POST /v0.1/spheres` is 401 then, 403 with none set, and creates nothing.
    func check() async {
        (checked, problem) = (nil, nil)
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host() else {
            problem = "That isn't an address, like https://obi-sphere.you.workers.dev."
            return
        }
        if let refused = SphereServer.problem(url) {
            problem = refused
            return
        }
        busy = true
        defer { busy = false }
        do {
            let server = SphereServer(base: url)
            guard try await server.call("GET", "health")["ok"] as? Bool == true else { throw RunnerError(message: "\(host) answers, but not as an Obysphere.") }
            if made != nil {
                do {
                    _ = try await server.call("POST", "spheres", json: [String: Any]())
                } catch let error as RunnerError where error.status == 403 {
                    throw RunnerError(message: "\(host) has no operator token yet. Paste the one Oby copied as SPHERE_OPERATOR_TOKEN in your Worker's Settings › Variables and Secrets, then check again.")
                } catch let error as RunnerError where error.status == 401 {}
            }
            checked = url
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The owner said `checked` is theirs: the token goes there once, to check the server has it (an
    /// empty `POST /v0.1/spheres` with it is 400, with another 401), then it's kept under that host,
    /// the clipboard is cleared if it still holds it, and the address is the server. True when done.
    func use() async -> Bool {
        guard let url = checked, let host = url.host() else { return false }
        let token = made?.token
        busy = true
        defer { busy = false }
        do {
            if let token {
                do {
                    _ = try await SphereServer(base: url).call("POST", "spheres", bearer: token, json: [String: Any]())
                } catch let error as RunnerError where error.status == 401 || error.status == 403 {
                    throw RunnerError(message: "\(host) doesn't have the token Oby copied. Choose Deploy… for a new one (close the page it opens), paste it as SPHERE_OPERATOR_TOKEN in your Worker's Settings › Variables and Secrets, then check again.")
                } catch let error as RunnerError where error.status == 400 {}
                try SphereModel.operatorToken.save(token, as: host)
                // Deploy… may have made another meanwhile: that one stays.
                if let made, made.token == token {
                    if pasteboard.changeCount == made.clipboard { pasteboard.clearContents() }
                    self.made = nil
                }
            }
            defaults.set(url.absoluteString, forKey: SphereModel.serverKey)
            address = ""
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }
}

// MARK: The model

/// This Mac's place in its Obysphere: what obid says of its membership, the Sphere's name and
/// members as the owner reads them, the requests from other Obys waiting for the owner, and what
/// the owner does there (create it, invite, join, ask for a review, answer).
@MainActor @Observable
final class SphereModel {
    /// `GET /v1/obid/sphere`.
    struct Membership: Decodable, Equatable {
        var state: String
        var url: String?
        var sphere: String?
        var obiId: String?
        var owner: String
        var lastError: String?
    }

    /// One entry of the Sphere's directory.
    struct Member: Identifiable, Equatable {
        var obi: String
        var owner: String
        var name: String
        var active: Bool
        var accepts: [String]
        /// Their owner key's fingerprint as this Oby pinned it, and a different one the Obysphere
        /// shows since, waiting for your OK (obid's `GET /v1/obid/sphere/pins`).
        var fingerprint: String? = nil
        var changedTo: String? = nil
        /// Whether you compared their key with them and accepted it.
        var verified = false
        var id: String { obi }
    }

    /// An owner key obid pinned (docs/runner-api.md, "Pinned owner keys").
    struct Pin: Decodable, Equatable {
        var owner: String
        var fingerprint: String
        var changedTo: String?
        var verified: Bool?
    }

    /// An `obiRequest` inbox item (docs/runner-api.md, "Obi-to-Obi requests in the inbox"). Its
    /// title and text are obid's own words from typed fields; `quoted` is the other Oby's text,
    /// shown whole and as text only.
    struct Request: Identifiable, Equatable {
        var id: String
        var title: String
        var text: String
        var options: [String]
        var details: [String]
        var quoted: [(String, String)]
        static func == (a: Request, b: Request) -> Bool { a.id == b.id && a.options == b.options }
    }

    /// The Obysphere server this Oby makes Obyspheres on and trusts links from: Settings ›
    /// Obysphere's Server, else the app's ObySphereURL (OBY_SPHERE_URL in apps/config/Signing.xcconfig,
    /// Deskree's own in Deskree's builds), else none (obi-sphere's docs/run-your-own.md).
    nonisolated static var server: URL? {
        let set = UserDefaults.standard.string(forKey: serverKey) ?? ""
        let built = Bundle.main.object(forInfoDictionaryKey: "ObySphereURL") as? String ?? ""
        return [set, built].lazy.compactMap { $0.isEmpty ? nil : URL(string: $0) }.first { SphereServer.problem($0) == nil }
    }
    nonisolated static let serverKey = "sphereServer"
    /// What another Oby may ask this one (docs/runner-api.md, `POST /v1/obid/sphere/card`).
    nonisolated static let accepts = ["review_request", "question"]
    /// What each Obi's delegation grants it (identity.md 4.2).
    nonisolated static let obiScopes = "send:review_request send:question reply receive directory:read audit:read"
    /// The same, and sending a job to a teammate's Mac (#797): asked for only once the owner shares
    /// or sends one, since a Sphere from before it refuses a scope it doesn't know.
    nonisolated static let sharingScopes = "send:review_request send:question send:run_request send:share_offer reply receive directory:read audit:read"

    private let feed: RunnerFeed
    private(set) var membership: Membership?
    private(set) var name: String?
    private(set) var admin = false
    private(set) var members: [Member] = []
    /// Your owner key's fingerprint, for the others to compare.
    private(set) var ownFingerprint: String?
    private(set) var requests: [Request] = []
    var problem: String?
    var busy = false

    init(feed: RunnerFeed) { self.feed = feed }

    var joined: Bool { membership?.state == "joined" }
    /// Who this Mac's Oby acts for (obid's `owner`).
    var owner: String? { membership?.owner }
    /// The operator token's keychain item, on the Mac that deployed the Obysphere server (obi-sphere's
    /// scripts/deploy.mjs), its account the server's host: a token only ever goes to the server it was
    /// made for. Every other Mac creates an Obysphere by signing in with Google, when the server lets
    /// its Workspace (sphere-api.md section 3.1).
    nonisolated static let operatorToken = KeychainVault(service: "obi-sphere-operator-token", label: "obi-sphere operator token")
    /// The team link the admin made last, kept so Settings can copy it again (its secret is shown once).
    nonisolated static let teamLinks = KeychainVault(service: "com.deskree.oby.sphere-link", label: "Oby Obysphere link")
    /// Not in an Obysphere yet, with a server to make one on.
    var canCreate: Bool { membership != nil && !joined && Self.server != nil }
    /// The team link to copy (an admin's).
    private(set) var teamLink: InviteLink?

    private func runner() throws -> Runner {
        guard let runner = feed.runner else { throw RunnerError(message: "Oby's engine isn't running on this Mac yet.") }
        return runner
    }

    private var server: SphereServer? {
        membership?.url.flatMap(URL.init(string:)).map(SphereServer.init(base:))
    }

    /// Runs `work`, keeping its problem to show.
    func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// obid's membership, then the Sphere's name and members and the waiting requests.
    func refresh() async throws {
        let runner = try runner()
        membership = try await runner.call("GET", "v1/obid/sphere")
        guard joined, let server, let owner, let sphere = membership?.sphere else { return }
        teamLink = (try? Self.teamLinks.value(sphere)).flatMap { $0 }.flatMap(InviteLink.init)
        let token = try await server.ownerToken(owner: owner, sphere: sphere, key: try OwnerKey.of(owner), scope: "directory:read")
        let about = try await server.call("GET", "spheres/\(sphere)", bearer: token)
        name = about["name"] as? String
        admin = about["admin_owner"] as? String == owner
        let list = try await server.call("GET", "spheres/\(sphere)/members", bearer: token)["members"] as? [[String: Any]] ?? []
        members = list.compactMap { entry in
            guard let obi = entry["obi"] as? String, obi != membership?.obiId else { return nil }
            let params = ((entry["card"] as? [String: Any])?["capabilities"] as? [String: Any])
                .flatMap { ($0["extensions"] as? [[String: Any]])?.first?["params"] as? [String: Any] }
            return Member(obi: obi, owner: entry["owner"] as? String ?? "", name: (entry["card"] as? [String: Any])?["name"] as? String ?? obi,
                          active: entry["status"] as? String == "active", accepts: params?["accepts"] as? [String] ?? [])
        }
        // The fingerprints to compare with each person, from the keys obid pinned.
        let pins: [Pin] = (try? await runner.call("GET", "v1/obid/sphere/pins")) ?? []
        for index in members.indices {
            let pin = pins.first { $0.owner == members[index].owner }
            members[index].fingerprint = pin?.fingerprint
            members[index].changedTo = pin?.changedTo
            members[index].verified = pin?.verified ?? false
        }
        ownFingerprint = try? OwnerKey.of(owner).keyId
        let inbox = (try JSONSerialization.jsonObject(with: try await runner.send("GET", "v1/inbox"))) as? [[String: Any]] ?? []
        requests = inbox.compactMap(Self.request)
    }

    /// An open `obiRequest` item as the owner sees it, or nil for any other.
    nonisolated static func request(_ item: [String: Any]) -> Request? {
        guard item["kind"] as? String == "obiRequest", item["done"] == nil || item["done"] is NSNull,
              let id = item["id"] as? String else { return nil }
        let quoted = (item["obi"] as? [String: Any])?["quoted"] as? [String: Any] ?? [:]
        var lines: [(String, String)] = []
        for key in ["goal", "summary", "text"] {
            if let text = quoted[key] as? String { lines.append((key.capitalized, text)) }
        }
        for (index, condition) in (quoted["acceptance"] as? [[String: Any]] ?? []).enumerated() {
            for key in ["note", "text"] {
                if let text = condition[key] as? String { lines.append(("Condition \(index + 1)", text)) }
            }
        }
        for choice in quoted["choices"] as? [String] ?? [] { lines.append(("Choice", choice)) }
        return Request(id: id, title: item["title"] as? String ?? "", text: item["text"] as? String ?? "",
                       options: item["options"] as? [String] ?? [], details: item["details"] as? [String] ?? [], quoted: lines)
    }

    // MARK: Admin

    /// What creating made: the link for everyone at `domain`, and the one mailed to the people invited.
    struct Created { var team: InviteLink?; var mailed: InviteLink? }

    /// Creates the Obysphere with this Mac's owner as its admin (sphere-api.md section 3), lets
    /// everyone ask everyone for reviews and questions (section 5), and joins this Mac's Oby. It
    /// creates with the operator token when this Mac has it, else by signing in with Google. Then a
    /// link for everyone at `domain` (the Sphere checks each one's Workspace), and one for the
    /// `emails` invited, which Mail opens a message with for the owner to send.
    func create(id sphere: String, name: String, emails: [String] = [], domain: String? = nil, on url: URL? = SphereModel.server) async throws -> Created {
        guard let url else { throw RunnerError(message: "Set the Obysphere server first, in Settings › Obysphere.") }
        let runner = try runner()
        let membership: Membership = try await runner.call("GET", "v1/obid/sphere")
        // Before anything reaches the server: a joined Oby would make a Sphere it can't join.
        guard membership.state != "joined" else { throw RunnerError(message: "This Oby is in an Obysphere already.") }
        let owner = membership.owner
        let key = try OwnerKey.of(owner)
        let server = SphereServer(base: url)
        let body: [String: Any] = ["sphere": sphere, "name": name, "admin": ["owner": owner, "owner_key": key.publicKey]]
        var made = false
        if let host = url.host(), let operatorToken = try Self.operatorToken.value(host) {
            do {
                _ = try await server.call("POST", "spheres", bearer: operatorToken, json: body)
                made = true
            } catch let error as RunnerError where error.status == 401 {
                // The server's token was rotated since: sign in instead.
            }
        }
        if !made {
            let signin: [String: String]
            do {
                signin = try await server.signIn(key: key)
            } catch let error as RunnerError where error.status == 403 {
                throw RunnerError(message: "\(url.host() ?? "This Obysphere server") lets only its operator create Obyspheres. Ask them for an invite link, or run your own.")
            }
            do {
                _ = try await server.call("POST", "spheres", json: body.merging(["signin": signin]) { $1 })
            } catch let error as RunnerError where error.status == 403 {
                throw RunnerError(message: "\(url.host() ?? "This Obysphere server") doesn't let that Google account create Obyspheres. Sign in with your work account.")
            }
        }
        let token = try await server.ownerToken(owner: owner, sphere: sphere, key: key, scope: "admin")
        _ = try await server.call("PUT", "spheres/\(sphere)/policy", bearer: token, json: [
            "expected_version": 0,
            "rules": [["id": "everyone", "from_owner": "*", "to_owner": "*", "actions": ["review_request", "question"], "repos": ["*"]]],
        ])
        let mine = try await invitation(server: server, token: token, sphere: sphere, name: name, by: owner, for: owner)
        try await join(mine)
        var created = Created()
        if let domain {
            // A Sphere server without sign-in can't limit a link to a domain: no team link then.
            created.team = try? await invitation(server: server, token: token, sphere: sphere, name: name, by: owner, domain: domain)
            if let team = created.team { try? Self.teamLinks.save(team.link, as: sphere) }
        }
        if !emails.isEmpty {
            // The Sphere is made and joined by now: a failed invite mustn't undo that in the sheet.
            created.mailed = try? await invitation(server: server, token: token, sphere: sphere, name: name, by: owner, uses: emails.count)
        }
        try await refresh()
        return created
    }

    /// A link for anyone at `domain` (with a sign-in) for 30 days, or else one for up to 50 people
    /// for 7 days (sphere-api.md section 4, open invitations), kept for Settings to copy again.
    func makeTeamLink(domain: String?) async throws -> InviteLink {
        guard let server, let owner, let sphere = membership?.sphere else { throw RunnerError(message: "This Oby isn't in an Obysphere.") }
        let token = try await server.ownerToken(owner: owner, sphere: sphere, key: try OwnerKey.of(owner), scope: "admin")
        let link = try await invitation(server: server, token: token, sphere: sphere, name: name ?? sphere, by: owner, uses: domain == nil ? 50 : 1000, domain: domain)
        try? Self.teamLinks.save(link.link, as: sphere)
        teamLink = link
        return link
    }

    /// A named invitation `for` one owner, used once in 7 days; else an open one for `uses` Obis,
    /// for 30 days when it's limited to `domain`, else 7.
    private func invitation(server: SphereServer, token: String, sphere: String, name: String, by: String,
                            for person: String? = nil, uses: Int = 1000, domain: String? = nil) async throws -> InviteLink {
        var body: [String: Any] = ["expires_in": domain == nil ? 604_800 : 2_592_000]
        if let person { (body["owner"], body["obi"]) = (person, "obi-\(person)") } else { body["max_uses"] = min(max(uses, 1), 1000) }
        if let domain { body["domain"] = domain }
        let made = try await server.call("POST", "spheres/\(sphere)/invitations", bearer: token, json: body)
        guard let id = made["invitation_id"] as? String, let secret = made["secret"] as? String else {
            throw RunnerError(message: "The Obysphere's invitation came without its secret.")
        }
        return InviteLink(server: server.base, sphere: sphere, name: name, by: by, owner: person, obi: person.map { "obi-\($0)" },
                          id: id, secret: secret, domain: made["domain"] as? String)
    }

    /// A message in the owner's mail app to `emails` with `link`, for them to send.
    static func mail(_ link: InviteLink, to emails: [String]) {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = emails.joined(separator: ",")
        parts.queryItems = [
            URLQueryItem(name: "subject", value: "Join \(link.name) on Oby"),
            URLQueryItem(name: "body", value: "\(link.by.isEmpty ? "You're" : "\(link.by) has") invited you to \(link.name), where our Obys work together.\n\nIn Oby on your Mac, open Settings › Obysphere and paste this link:\n\n\(link.link)\n\nIt works for 7 days."),
        ]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }

    // MARK: Member

    /// What the Sphere says of `invite` (sphere-api.md section 4, "Preview"): its name, how many are
    /// in it, and the Workspace it's limited to; the link's own words are only a guess until then.
    func preview(_ invite: InviteLink) async throws -> InviteLink {
        let seen = try await SphereServer(base: invite.server).call("POST", "spheres/\(invite.sphere)/invitations/\(invite.id)/preview", json: ["secret": invite.secret])
        var invite = invite
        invite.name = seen["name"] as? String ?? invite.name
        invite.domain = seen["domain"] as? String
        invite.members = seen["member_count"] as? Int
        return invite
    }

    /// What the Join screen shows of `found`: the Sphere's own words once it may be asked (the server
    /// Oby knows, or one the owner said they trust), else only the link's. Nothing goes to a server
    /// before that.
    func shown(_ found: InviteLink, trusted: Bool) async -> InviteLink {
        guard found.warning == nil || trusted else { return found }
        return (try? await preview(found)) ?? found
    }

    /// Joins with `invite` (docs/runner-api.md, `POST /v1/obid/sphere/join`): obid's key, its card
    /// signed here with the owner key, and the owner's delegation to it; first a sign-in with Google
    /// when the link is for one Workspace's people.
    func join(_ invite: InviteLink) async throws {
        let runner = try runner()
        let membership: Membership = try await runner.call("GET", "v1/obid/sphere")
        if let mismatch = invite.mismatch(owner: membership.owner) { throw RunnerError(message: mismatch) }
        let key = try OwnerKey.of(membership.owner)
        let url = invite.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let obi = invite.obi ?? "obi-\(membership.owner)"
        var invitation: [String: Any] = ["id": invite.id, "secret": invite.secret]
        if invite.owner == nil, try await preview(invite).domain != nil {
            invitation["signin"] = try await SphereServer(base: invite.server).signIn(key: key)
        }
        _ = try await runner.send("POST", "v1/obid/sphere/key")
        let made = try await raw(runner, "POST", "v1/obid/sphere/card", [
            "url": url, "sphere": invite.sphere, "obiId": obi, "name": "\(membership.owner)'s Oby",
            "ownerKey": key.publicKey, "accepts": Self.accepts,
        ])
        guard let card = made["card"] as? [String: Any] else { throw RunnerError(message: "obid made no card.") }
        _ = try await raw(runner, "POST", "v1/obid/sphere/join", [
            "url": url, "sphere": invite.sphere, "invitation": invitation,
            "card": try key.sign(card: card),
            "delegation": try key.assertion(owner: membership.owner, sphere: invite.sphere, scope: Self.obiScopes, mayAct: obi),
        ])
        try await refresh()
    }

    /// A new card and delegation for this Mac's Oby (docs/runner-api.md, `PUT /v1/obid/sphere/membership`):
    /// a card that takes teammates' jobs when `sharing`, and a delegation that may send one (#808).
    func renew(sharing: Bool) async throws {
        let runner = try runner()
        let membership: Membership = try await runner.call("GET", "v1/obid/sphere")
        guard membership.state == "joined", let url = membership.url, let sphere = membership.sphere, let obi = membership.obiId else {
            throw RunnerError(message: "This Oby isn't in an Obysphere.")
        }
        let key = try OwnerKey.of(membership.owner)
        let made = try await raw(runner, "POST", "v1/obid/sphere/card", [
            "url": url, "sphere": sphere, "obiId": obi, "name": "\(membership.owner)'s Oby",
            "ownerKey": key.publicKey, "accepts": sharing ? Self.accepts + ["run_request", "share_offer"] : Self.accepts,
        ])
        guard let card = made["card"] as? [String: Any] else { throw RunnerError(message: "obid made no card.") }
        _ = try await raw(runner, "PUT", "v1/obid/sphere/membership", [
            "card": try key.sign(card: card),
            "delegation": try key.assertion(owner: membership.owner, sphere: sphere, scope: Self.sharingScopes, mayAct: obi),
        ])
        try await refresh()
    }

    /// Asks `member`'s Oby to review `job`'s pull request at the commit GitHub has as its head
    /// (docs/runner-api.md, `POST /v1/obid/sphere/requests`; the spec's review_request).
    func askForReview(_ member: Member, of job: Job) async throws {
        guard let pr = PublishedLink.url(job.published).flatMap({ Int($0.lastPathComponent) }),
              let head = job.pullRequest?.head, let base = job.pullRequest?.base else {
            throw RunnerError(message: "That job's pull request isn't read from GitHub yet: try again in a moment.")
        }
        var body: [String: Any] = [
            "goal": String((job.title ?? job.task).prefix(200)).replacingOccurrences(of: "\n", with: " "),
            "repo": job.repo, "pr": pr, "base_branch": base, "head_branch": job.branch, "head_sha": head,
            "acceptance": [["kind": "tests_pass"], ["kind": "no_blocker_findings"]],
        ]
        if !job.summary.isEmpty { body["summary"] = String(job.summary.prefix(2000)) }
        _ = try await raw(try runner(), "POST", "v1/obid/sphere/requests",
                          ["to": member.obi, "type": "review_request", "body": body, "expiresIn": 86_400])
    }

    /// Answers a request with one of its options (`POST /v1/inbox/{id}/answer`).
    /// You compared `member`'s new key with them: obid trusts it from now on.
    /// Accepts their changed key, or verifies the one pinned: only after you compared it with them.
    func acceptKey(_ member: Member) async throws {
        guard let fingerprint = member.changedTo ?? member.fingerprint else { return }
        _ = try await raw(try runner(), "POST", "v1/obid/sphere/pins/\(member.owner)", ["fingerprint": fingerprint])
        try await refresh()
    }

    func answer(_ request: Request, _ option: String) async throws {
        _ = try await raw(try runner(), "POST", "v1/inbox/\(request.id)/answer", ["answer": option])
        try await refresh()
    }

    /// The runner's call with a JSON body the protocol shapes (snake_case inside), unchanged.
    private func raw(_ runner: Runner, _ method: String, _ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let data = try await runner.send(method, path, json: try JSONSerialization.data(withJSONObject: body))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
