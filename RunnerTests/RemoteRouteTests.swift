import Foundation
import Testing
@testable import ObyShared

/// How the iPhone picks its way to the Mac (#285): home over Bonjour, away through the tunnel.
struct RemoteRouteTests {
    @Test func knowsTheControlPlanesHostnames() {
        #expect(MacLink.isHostname("oby-abcdefghij0123456789.tetrix.pro"))
        #expect(MacLink.isHostname("oby-abcdefghijklmnop.tetrix.pro"))
        // The Mac's Tailscale name, with or without the port `tailscale serve` gives the gateway (#621).
        #expect(MacLink.isHostname("tetrix-lab.tail8de49b.ts.net"))
        #expect(MacLink.isHostname("tetrix-lab.tail8de49b.ts.net:8443"))
        // Too short an opaque part, capitals, a deeper name (no certificate for it), the Worker, or nothing like it.
        #expect(!MacLink.isHostname("oby-abc.tetrix.pro"))
        #expect(!MacLink.isHostname("oby-ABCDEFGHIJ0123456789.tetrix.pro"))
        #expect(!MacLink.isHostname("abcdefghij0123456789.oby.tetrix.pro"))
        #expect(!MacLink.isHostname("oby-control.tetrix.pro"))
        #expect(!MacLink.isHostname("a.b.tail8de49b.ts.net"))
        #expect(!MacLink.isHostname("tail8de49b.ts.net"))
        #expect(!MacLink.isHostname("tetrix-lab.tail8de49b.ts.net.evil.example.com"))
        #expect(!MacLink.isHostname("evil.example.com:8443"))
        #expect(!MacLink.isHostname(""))
    }

    @Test func takesAHostnameAsTypedOrScanned() {
        #expect(MacLink.hostname(from: "  OBY-abcdefghij0123456789.Tetrix.pro\n") == "oby-abcdefghij0123456789.tetrix.pro")
        #expect(MacLink.hostname(from: "https://oby-abcdefghij0123456789.tetrix.pro/v1/status") == "oby-abcdefghij0123456789.tetrix.pro")
        #expect(MacLink.hostname(from: "https://tetrix-lab.tail8de49b.ts.net:8443") == "tetrix-lab.tail8de49b.ts.net:8443")
        #expect(MacLink.hostname(from: "https://evil.example.com:8443") == nil)
        #expect(MacLink.hostname(from: "") == nil)
    }

    @Test func readsWhatPairingHandsOver() throws {
        let link = try MacLink.paired(Data(#"{"name": "Wellington's MacBook Pro", "hostname": "oby-abcdefghij0123456789.tetrix.pro"}"#.utf8))
        #expect(link.name == "Wellington's MacBook Pro")
        #expect(link.tunnelURL == URL(string: "https://oby-abcdefghij0123456789.tetrix.pro"))
        #expect(try MacLink.paired(link.encoded()) == link)
        #expect(throws: (any Error).self) { try MacLink.paired(Data(#"{"name": "Mac", "hostname": "evil.example.com"}"#.utf8)) }
        #expect(throws: (any Error).self) { try MacLink.paired(Data("nope".utf8)) }
    }

    @Test func homeWinsOverTheTunnel() throws {
        let link = MacLink(name: "MacBook", hostname: "oby-abcdefghij0123456789.tetrix.pro")
        let lan = URL(string: "http://192.168.1.20:8810")!
        #expect(RemoteRoute.choose(lan: lan, link: link, paired: true) == .home(lan))
        #expect(RemoteRoute.choose(lan: nil, link: link, paired: true) == .away(link.tunnelURL))
        #expect(RemoteRoute.choose(lan: nil, link: nil, paired: true) == nil)
        // Something on the network, but no Mac linked: the iPhone keeps its runner.
        #expect(RemoteRoute.choose(lan: lan, link: nil, paired: true) == nil)
        #expect(RemoteRoute.choose(lan: lan, link: link, paired: false) == nil)
        #expect(RemoteRoute.home(lan).url == lan)
        #expect(RemoteRoute.away(link.tunnelURL).label == "Away, through the tunnel")
        #expect(RemoteRoute.home(lan).label == "At home, over the local network")
    }

    @Test func namesTheGatewayOnTheLocalNetwork() {
        #expect(RemoteRoute.lanURL(host: "192.168.1.20", port: 8810) == URL(string: "http://192.168.1.20:8810"))
        #expect(RemoteRoute.lanURL(host: "fe80::1c2f", port: 8810) == URL(string: "http://[fe80::1c2f]:8810"))
        #expect(RemoteRoute.lanURL(host: "Wellingtons-MacBook-Pro.local", port: 8810) == URL(string: "http://Wellingtons-MacBook-Pro.local:8810"))
    }
}
