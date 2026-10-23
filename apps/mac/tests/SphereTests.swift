import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Oby

/// The owner's side of the Obysphere (apps/mac/app/Sphere.swift): what the owner key signs, and
/// the invite link. obid and the Sphere check the signatures; these keep the bytes they check.
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
        for refused in ["http://obysphere.deskree.com", "https://localhost:8787", "https://127.0.0.1", "https://169.254.169.254",
                        "https://10.0.0.5", "https://100.100.100.100", "https://[::1]:8787", "https://2130706433", "https://sphere",
                        "https://studio.local", "https://mac.tail1234.ts.net", "https://sphere.internal", "https://a.0x7f"] {
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
