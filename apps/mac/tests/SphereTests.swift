import AppKit
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Oby

/// The owner's side of the Obysphere (apps/mac/app/Sphere.swift): what the owner key signs, and
/// the invite link. obid and the Sphere check the signatures; these keep the bytes they check.
/// Serialized: Host your own puts a fake Obysphere in `SphereServer.session` for a moment.
@Suite(.serialized)
struct SphereTests {
    @Test func canonicalJSONIsRFC8785ForTheProtocolsValues() {
        let value: [String: Any] = ["b": [true, false, NSNull()], "a": 1, "é": "x", "c": ["z": "\"\\\n\u{1}/é"]]
        #expect(String(decoding: Canonical.json(value), as: UTF8.self) == #"{"a":1,"b":[true,false,null],"c":{"z":"\"\\\n\u0001/é"},"é":"x"}"#)
    }

    @Test func aSignedCardVerifiesWithTheOwnerKey() throws {
        let key = OwnerKey(pair: Curve25519.Signing.PrivateKey())
        let signed = try key.sign(card: ["name": "Wellington's Oby", "card_seq": 1, "signatures": "old"])
        let signature = try #require((signed["signatures"] as? [[String: String]])?.first)
        let protected = try #require(signature["protected"])
        #expect(Data(base64url: protected).map { String(decoding: $0, as: UTF8.self) } == #"{"alg":"EdDSA","kid":"\#(key.keyId)","typ":"JOSE"}"#)
        let payload = Canonical.json(["name": "Wellington's Oby", "card_seq": 1]).base64url
        let encoded = try #require(signature["signature"])
        let bytes = try #require(Data(base64url: encoded))
        #expect(key.pair.publicKey.isValidSignature(bytes, for: Data("\(protected).\(payload)".utf8)))
        #expect(key.keyId.count == 51)
    }

    @Test func aDelegationLetsTheObiActForThirtyDays() throws {
        let key = OwnerKey(pair: Curve25519.Signing.PrivateKey())
        let jwt = try key.assertion(owner: "wellington", sphere: "deskree", scope: SphereModel.obiScopes, mayAct: "obi-wellington",
                                    now: Date(timeIntervalSince1970: 1_000))
        let parts = jwt.split(separator: ".").map(String.init)
        let payload = try #require(Data(base64url: parts[1]))
        let claims = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(claims["aud"] as? String == "obi-sphere:deskree" && claims["exp"] as? Int == 1_000 + 2_592_000)
        #expect((claims["may_act"] as? [String: String])?["sub"] == "obi-wellington")
        let signature = try #require(Data(base64url: parts[2]))
        #expect(key.pair.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func anInviteLinkReadsBackAndKeepsItsSecretAfterTheHash() throws {
        let invite = InviteLink(server: URL(string: "https://obysphere.deskree.com")!, sphere: "deskree", name: "Deskree & co",
                                by: "wellington", owner: "ernesto", obi: "obi-ernesto", id: "inv-1", secret: "a+b/c=")
        let url = try #require(URL(string: invite.link))
        #expect(url.path() == "/join" && url.query() == nil)
        #expect(InviteLink(invite.link) == invite)
        #expect(InviteLink("https://example.com/join") == nil)
        #expect(InviteLink("not a link") == nil)
    }

    @Test func anOpenLinkIsForAnyoneAndMaySayItsWorkspace() throws {
        let open = InviteLink(server: URL(string: "https://obysphere.deskree.com")!, sphere: "deskree", name: "Deskree",
                              by: "wellington", id: "inv-2", secret: "s", domain: "deskree.com")
        let read = try #require(InviteLink(open.link))
        #expect(read == open && read.owner == nil && read.obi == nil && read.domain == "deskree.com")
        #expect(read.mismatch(owner: "sangam") == nil, "an open link is for whoever has it")
        // A named link names both its owner and its Obi.
        #expect(InviteLink("https://obysphere.deskree.com/join#sphere=deskree&for=ernesto&id=i&secret=s") == nil)
        #expect(InviteLink("https://obysphere.deskree.com/join#sphere=deskree&obi=obi-ernesto&id=i&secret=s") == nil)
    }

    @Test func onlyAWorkAddressOffersAnyoneThereCanJoin() {
        #expect(CreateSphereSheet.workDomain("Doti@Deskree.com") == "deskree.com")
        for personal in ["doti@gmail.com", "doti@icloud.com", "123+doti@users.noreply.github.com", "doti", nil] {
            #expect(CreateSphereSheet.workDomain(personal) == nil, "\(personal ?? "nil")")
        }
        #expect(CreateSphereSheet.isEmail("ernesto@deskree.com") && !CreateSphereSheet.isEmail("ernesto") && !CreateSphereSheet.isEmail("a@b"))
    }

    @Test func onlyAPublicHTTPSAddressGetsTheOwnersSignatures() {
        // Deskree's builds come with Deskree's server (OBY_SPHERE_URL in apps/config/Signing.xcconfig).
        #expect(Bundle.main.object(forInfoDictionaryKey: "ObySphereURL") as? String == "https://obysphere.deskree.com")
        #expect(SphereServer.problem(URL(string: "https://obysphere.deskree.com")!) == nil)
        #expect(SphereServer.problem(URL(string: "https://deskree.obysphere.com")!) == nil)
        #expect(SphereServer.problem(URL(string: "https://deskree.obysphere.com/")!) == nil)
        for refused in ["http://obysphere.deskree.com", "https://localhost:8787", "https://127.0.0.1", "https://169.254.169.254",
                        "https://10.0.0.5", "https://100.100.100.100", "https://[::1]:8787", "https://2130706433", "https://sphere",
                        "https://studio.local", "https://mac.tail1234.ts.net", "https://sphere.internal", "https://a.0x7f",
                        "https://x.example.com/sphere", "https://x.example.com?a=b", "https://me:pw@x.example.com", "https://x.example.com#s"] {
            #expect(SphereServer.problem(URL(string: refused)!) != nil, "\(refused)")
        }
    }

    @Test func anInviteLinkToAnInternalOrPlainAddressIsntOne() {
        let fragment = "#sphere=deskree&for=ernesto&obi=obi-ernesto&id=i&secret=s"
        #expect(InviteLink("https://obysphere.deskree.com/join" + fragment) != nil)
        for server in ["http://obysphere.deskree.com", "https://127.0.0.1:8787", "https://169.254.169.254", "https://studio.local"] {
            #expect(InviteLink(server + "/join" + fragment) == nil, "\(server)")
        }
    }

    @Test func theJoinScreenShowsTheServerAndWarnsOfAnUnknownOne() throws {
        let known = try #require(InviteLink("https://obysphere.deskree.com/join#sphere=deskree&name=Deskree&by=wellington&for=ernesto&obi=obi-ernesto&id=i&secret=s"))
        #expect(known.host == "obysphere.deskree.com" && known.warning == nil)
        let lookalike = try #require(InviteLink("https://lookalike.workers.dev/join#sphere=deskree&name=Deskree&by=wellington&for=ernesto&obi=obi-ernesto&id=i&secret=s"))
        #expect(lookalike.host == "lookalike.workers.dev")
        #expect(lookalike.warning?.contains("lookalike.workers.dev") == true)
    }

    @Test func anInviteForSomeoneElseIsRefused() throws {
        let invite = try #require(InviteLink("https://obysphere.deskree.com/join#sphere=deskree&by=wellington&for=ernesto&obi=obi-ernesto&id=i&secret=s"))
        #expect(invite.mismatch(owner: "ernesto") == nil)
        #expect(invite.mismatch(owner: "sangam") == "This invite is for ernesto, and this Mac's Oby acts for sangam. Ask wellington for one for sangam.")
    }

    @Test func theSphereSessionFollowsNoRedirect() async throws {
        #expect(SphereServer.session.delegate is NoRedirects)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Redirecting.self]
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        let (_, response) = try await session.data(from: URL(string: "https://obysphere.deskree.com/v0.1/oauth/token")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 307)
        #expect(Redirecting.reachedElsewhere.withLock { $0 } == false)
    }

    @Test func anObyJoinLinkOpensTheInviteItCarries() throws {
        let invite = InviteLink(server: URL(string: "https://obi-sphere.acme.workers.dev")!, sphere: "acme", name: "Acme & co",
                                by: "wellington", id: "inv-1", secret: "a+b/c=")
        let fragment = try #require(invite.link.split(separator: "#", maxSplits: 1).last)
        let link = try #require(URL(string: "oby://join/obi-sphere.acme.workers.dev#\(fragment)"))
        let opened = try #require(InviteLink(opened: link))
        #expect(opened == invite)
        #expect(opened.warning?.contains("obi-sphere.acme.workers.dev") == true, "a server Oby doesn't know asks first")
        let port = try #require(URL(string: "oby://join/sphere.acme.com:8443#\(fragment)").flatMap(InviteLink.init(opened:)))
        #expect(port.server.absoluteString == "https://sphere.acme.com:8443")
        for other in ["oby://open/obi-sphere.acme.workers.dev#\(fragment)", "https://obi-sphere.acme.workers.dev/join#\(fragment)",
                      "oby://join/obi-sphere.acme.workers.dev", "oby://join/localhost:8787#\(fragment)", "oby://join/127.0.0.1#\(fragment)",
                      "oby://join/me@obi-sphere.acme.workers.dev#\(fragment)", "oby://join/obi-sphere.acme.workers.dev/x#\(fragment)",
                      "oby://join/obi-sphere.acme.workers.dev?a=b#\(fragment)", "oby://join/#\(fragment)", "oby://job/123"] {
            #expect(URL(string: other).flatMap(InviteLink.init(opened:)) == nil, "\(other)")
        }
    }

    /// Host your own, with a fake Obysphere and obid: Deploy's token, copied concealed (paste one, into
    /// Cloudflare); the address (paste two), asked nothing until Check, and then without the token;
    /// the token goes to that host only once it's confirmed, and is kept under it; then Create makes
    /// the Obysphere with it.
    @MainActor @Test func hostYourOwnGoesFromDeployToACreatedObysphereWithTwoPastes() async throws {
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.tests.\(UUID().uuidString)"))
        let board = NSPasteboard(name: .init("com.deskree.oby.tests.\(UUID().uuidString)"))
        let host = HostOwn(defaults: defaults, pasteboard: board)
        #expect(host.deploy() == HostOwn.deployPage)
        let token = try #require(host.made?.token)
        // The server's own order: the operator token first (401 wrong or missing), then the body.
        let server = RunnerStub { request in
            switch (request.method, request.path) {
            case ("GET", "/v0.1/health"): (200, #"{"ok": true, "protocol": "obi/0.1"}"#)
            case ("POST", "/v0.1/spheres"):
                request.authorization != "Bearer \(token)" ? (401, #"{"error": {"code": "unauthorized", "message": ""}}"#)
                    : request.json?["sphere"] == nil ? (400, #"{"error": {"code": "bad_request", "message": ""}}"#) : (201, #"{"sphere": "acme"}"#)
            case ("POST", "/v0.1/oauth/token"): (200, #"{"access_token": "owner-token"}"#)
            case ("PUT", "/v0.1/spheres/acme/policy"): (200, "{}")
            case ("POST", "/v0.1/spheres/acme/invitations"): (201, #"{"invitation_id": "inv-1", "secret": "s"}"#)
            default: (404, #"{"error": {"code": "not_found", "message": ""}}"#)
            }
        }
        let owner = "tester-\(UUID().uuidString.lowercased())"
        let obid = RunnerStub { request in
            switch request.path {
            case "/v1/obid/sphere": (200, #"{"state": "none", "owner": "\#(owner)"}"#)
            case "/v1/obid/sphere/card": (200, #"{"card": {"name": "x"}}"#)
            default: (200, "{}")
            }
        }
        let session = SphereServer.session
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RunnerStubProtocol.self] + (configuration.protocolClasses ?? [])
        SphereServer.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer {
            SphereServer.session = session
            try? SphereModel.operatorToken.remove(server.host)
            try? OwnerKey.store.remove(owner)
            board.releaseGlobally()
        }

        #expect(token.count == 43 && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) })
        #expect(board.string(forType: .string) == token && board.types?.contains(SphereSettingsView.concealed) == true)

        // Typed or pasted, an address asks nothing: not a prefix of it, not the whole of it.
        for typed in ["o", String(server.host.dropLast(3)), " \(server.host)/ "] { host.address = typed }
        try await Task.sleep(for: .milliseconds(800))
        #expect(server.requests.isEmpty && host.checked == nil)

        await host.check()
        let url = try #require(host.checked)
        #expect(url.absoluteString == "https://\(server.host)", "pasted as the dashboard shows it, without https://")
        #expect(server.requests.map { "\($0.method) \($0.path)" } == ["GET /v0.1/health", "POST /v0.1/spheres"])
        #expect(server.requests.allSatisfy { $0.authorization == nil }, "the token goes nowhere before the host is confirmed")
        #expect(defaults.string(forKey: SphereModel.serverKey) == nil)
        #expect(try SphereModel.operatorToken.value(server.host) == nil)

        // Refused: not public, and not an Obysphere. A new address takes back the check.
        host.address = "https://localhost:8787"
        #expect(host.checked == nil)
        await host.check()
        #expect(host.checked == nil && host.problem != nil)
        host.address = obid.host
        await host.check()
        #expect(host.checked == nil && host.problem != nil)

        // A server without this token keeps nothing: another Oby's Deploy… against the same server.
        let otherBoard = NSPasteboard(name: .init("com.deskree.oby.tests.\(UUID().uuidString)"))
        defer { otherBoard.releaseGlobally() }
        let other = HostOwn(defaults: defaults, pasteboard: otherBoard)
        _ = other.deploy()
        other.address = server.host
        await other.check()
        #expect(await other.use() == false && other.problem != nil && other.made != nil)
        #expect(defaults.string(forKey: SphereModel.serverKey) == nil)
        #expect(try SphereModel.operatorToken.value(server.host) == nil)

        // Confirmed: kept under that host, the server set, the clipboard cleared, the token forgotten.
        host.address = server.host
        await host.check()
        #expect(await host.use())
        #expect(try SphereModel.operatorToken.value(server.host) == token)
        #expect(defaults.string(forKey: SphereModel.serverKey) == url.absoluteString)
        #expect(board.string(forType: .string) == nil && host.made == nil && host.address.isEmpty)

        let feed = RunnerFeed()
        feed.stageAlerts(following: obid.runner)
        _ = try await SphereModel(feed: feed).create(id: "acme", name: "Acme", on: url)
        let created = server.requests.filter { $0.method == "POST" && $0.path == "/v0.1/spheres" && $0.json?["sphere"] != nil }
        #expect(created.count == 1 && created.first?.authorization == "Bearer \(token)")
        #expect(obid.requests.contains { $0.method == "POST" && $0.path == "/v1/obid/sphere/join" })
    }

    /// A Deploy… while the token is being used makes a new one: that one, and the clipboard holding
    /// it, stay.
    @MainActor @Test func aNewDeployWhileUsingKeepsTheNewToken() async throws {
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.tests.\(UUID().uuidString)"))
        let board = NSPasteboard(name: .init("com.deskree.oby.tests.\(UUID().uuidString)"))
        let host = HostOwn(defaults: defaults, pasteboard: board)
        _ = host.deploy()
        let first = try #require(host.made?.token)
        let server = RunnerStub { request in
            if request.path == "/v0.1/health" { return (200, #"{"ok": true}"#) }
            // While the first token is checked, the owner chooses Deploy… again.
            if request.authorization == "Bearer \(first)" { DispatchQueue.main.sync { MainActor.assumeIsolated { _ = host.deploy() } } }
            return (request.authorization == nil ? 401 : 400, "{}")
        }
        let session = SphereServer.session
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RunnerStubProtocol.self] + (configuration.protocolClasses ?? [])
        SphereServer.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer {
            SphereServer.session = session
            try? SphereModel.operatorToken.remove(server.host)
            board.releaseGlobally()
        }
        host.address = server.host
        await host.check()
        #expect(await host.use())
        let second = try #require(host.made?.token)
        #expect(second != first && board.string(forType: .string) == second)
        #expect(try SphereModel.operatorToken.value(server.host) == first)
    }

    /// The Join screen asks a server Oby doesn't know nothing until "I trust" is ticked.
    @MainActor @Test func anUnknownServersPreviewWaitsForTrust() async throws {
        let server = RunnerStub { request in
            request.path == "/v0.1/spheres/acme/invitations/inv-1/preview" ? (200, #"{"name": "Acme Inc", "member_count": 4}"#) : (404, "{}")
        }
        let session = SphereServer.session
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RunnerStubProtocol.self] + (configuration.protocolClasses ?? [])
        SphereServer.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { SphereServer.session = session }
        let link = try #require(URL(string: "oby://join/\(server.host)#sphere=acme&name=Acme&by=sangam&id=inv-1&secret=s"))
        let found = try #require(InviteLink(opened: link))
        #expect(found.warning != nil)
        let sphere = SphereModel(feed: RunnerFeed())
        #expect(await sphere.shown(found, trusted: false) == found)
        #expect(server.requests.isEmpty)
        let seen = await sphere.shown(found, trusted: true)
        #expect(seen.name == "Acme Inc" && seen.members == 4)
        #expect(server.requests.map(\.path) == ["/v0.1/spheres/acme/invitations/inv-1/preview"])
    }

    @Test func anObysphereIdComesFromItsName() {
        #expect(SphereSettingsView.slug("Deskree × Avenga") == "deskree-avenga")
        #expect(SphereSettingsView.slug("  Déskree  ") == "deskree")
    }
}

/// Answers every request to obysphere.deskree.com with a 307 to elsewhere.example, and notes
/// whether elsewhere.example was ever asked.
private final class Redirecting: URLProtocol {
    static let reachedElsewhere = Mutex(false)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host() == "obysphere.deskree.com" else {
            Self.reachedElsewhere.withLock { $0 = true }
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": "https://elsewhere.example/v0.1/oauth/token"])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://elsewhere.example/v0.1/oauth/token")!),
                            redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
