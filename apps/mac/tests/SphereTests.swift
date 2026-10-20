import CryptoKit
import Foundation
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
        let invite = InviteLink(server: URL(string: "https://obi-sphere.well0cp.workers.dev")!, sphere: "deskree", name: "Deskree & co",
                                by: "wellington", owner: "ernesto", obi: "obi-ernesto", id: "inv-1", secret: "a+b/c=")
        let url = try #require(URL(string: invite.link))
        #expect(url.path() == "/join" && url.query() == nil)
        #expect(InviteLink(invite.link) == invite)
        #expect(InviteLink("https://example.com/join") == nil)
        #expect(InviteLink("not a link") == nil)
    }

    @Test func anObysphereIdComesFromItsName() {
        #expect(SphereSettingsView.slug("Deskree × Avenga") == "deskree-avenga")
        #expect(SphereSettingsView.slug("  Déskree  ") == "deskree")
    }
}
