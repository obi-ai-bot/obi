import Foundation
import Testing
@testable import Oby

struct PairingTests {
    @Test func invitationDecodesTheRunnerDateFormat() throws {
        let json = #"{"code":"123456","expiresAt":"2026-10-13T12:02:00Z","hostname":"oby.example","link":"{\"hostname\":\"oby.example\",\"name\":\"My Mac\"}","name":"My Mac","secret":"one-time","url":"https://oby.example"}"#

        let invitation = try PairingPayloadDecoder.decodeInvitation(Data(json.utf8))

        #expect(invitation.code == "123456")
        #expect(invitation.expiresAt == ISO8601DateFormatter().date(from: "2026-10-13T12:02:00Z"))
    }

    @Test func devicesDecodeTheRunnerDateFormat() throws {
        let json = #"[{"id":"device-1","name":"Alice's iPhone","created":"2026-10-13T10:00:00Z","expiresAt":"2026-11-12T10:00:00Z"}]"#

        let devices = try PairingPayloadDecoder.decodeDevices(Data(json.utf8))

        let device = try #require(devices.first)
        #expect(device.name == "Alice's iPhone")
        #expect(device.created == ISO8601DateFormatter().date(from: "2026-10-13T10:00:00Z"))
        #expect(device.expiresAt == ISO8601DateFormatter().date(from: "2026-11-12T10:00:00Z"))
    }

    /// What `tailscale serve status --json` printed on the owner's Mac (2026-10-20), its names changed.
    static let serve = #"""
    {"TCP": {"443": {"HTTPS": true}, "8443": {"HTTPS": true}},
     "Web": {"mac.tail0000.ts.net:443": {"Handlers": {"/oberon": {"Proxy": "http://127.0.0.1:7448"}}},
             "mac.tail0000.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8810"}}}},
     "AllowFunnel": {"mac.tail0000.ts.net:443": true}}
    """#

    static func tailnet(_ json: String, port: Int = 8810) -> PairingRoute.Tailnet {
        PairingRoute.tailnet(serveStatus: Data(json.utf8), port: port)
    }

    /// Funnel on :443 goes to another server there, not the gateway: the tailnet route stands.
    @Test func theTailnetRouteIsTheServeURLThatProxiesToTheGateway() {
        #expect(Self.tailnet(Self.serve) == .route("mac.tail0000.ts.net:8443"))
    }

    @Test func aFunnelURLIsNeverTheRoute() {
        let json = #"{"Web": {"mac.tail0000.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8810"}}}}, "AllowFunnel": {"mac.tail0000.ts.net:443": true}}"#
        #expect(Self.tailnet(json) == .funnel)
    }

    @Test func aFunnelToTheGatewayOnAnyPathRulesOutTheTailnetRoute() {
        let json = #"""
        {"Web": {"mac.tail0000.ts.net:443": {"Handlers": {"/oby": {"Proxy": "http://127.0.0.1:8810"}}},
                 "mac.tail0000.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8810"}}}},
         "AllowFunnel": {"mac.tail0000.ts.net:443": true}}
        """#
        #expect(Self.tailnet(json) == .funnel)
    }

    @Test func aForegroundFunnelToTheGatewayRulesOutTheTailnetRoute() {
        let json = #"""
        {"Web": {"mac.tail0000.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8810"}}}},
         "Foreground": {"session-1": {"TCP": {"443": {"HTTPS": true}},
                                      "Web": {"mac.tail0000.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8810"}}}},
                                      "AllowFunnel": {"mac.tail0000.ts.net:443": true}}}}
        """#
        #expect(Self.tailnet(json) == .funnel)
    }

    @Test func aTCPFunnelToTheGatewayRulesOutTheTailnetRoute() {
        let json = #"""
        {"TCP": {"10000": {"TCPForward": "127.0.0.1:8810"}},
         "Web": {"mac.tail0000.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8810"}}}},
         "AllowFunnel": {"mac.tail0000.ts.net:10000": true}}
        """#
        #expect(Self.tailnet(json) == .funnel)
    }

    @Test func aServeURLForAnotherPortOrPathIsNotTheRoute() {
        #expect(Self.tailnet(Self.serve, port: 9999) == .nothing)
        #expect(Self.tailnet(#"{"Web": {"mac.tail0000.ts.net:8443": {"Handlers": {"/oby": {"Proxy": "http://127.0.0.1:8810"}}}}}"#) == .nothing)
    }

    @Test func aTCPForwardThatEndsTLSIsARoute() {
        #expect(Self.tailnet(#"{"TCP": {"8443": {"TCPForward": "127.0.0.1:8810", "TerminateTLS": "mac.tail0000.ts.net"}}}"#)
            == .route("mac.tail0000.ts.net:8443"))
        #expect(Self.tailnet(#"{"TCP": {"8443": {"TCPForward": "127.0.0.1:8810"}}}"#) == .nothing)
    }

    @Test func noTailscaleMeansNoTailnetRoute() async {
        #expect(await PairingRoute.tailnet(port: 8810, clis: ["/nonexistent/tailscale"]) == .nothing)
        #expect(Self.tailnet("{}") == .nothing)
        #expect(Self.tailnet("not json") == .nothing)
    }

    @Test func remoteAccessComesFirstThenTheTailnet() {
        #expect(PairingRoute.routes(remote: "oby-abcdefghijklmnop.tetrix.pro", tailscale: "mac.tail0000.ts.net:8443")
            == [.remote("oby-abcdefghijklmnop.tetrix.pro"), .tailscale("mac.tail0000.ts.net:8443")])
        #expect(PairingRoute.routes(remote: nil, tailscale: "mac.tail0000.ts.net:8443") == [.tailscale("mac.tail0000.ts.net:8443")])
        #expect(PairingRoute.routes(remote: nil, tailscale: nil).isEmpty)
        #expect(PairingRoute.tailscale("mac.tail0000.ts.net:8443").label == "Over Tailscale: mac.tail0000.ts.net:8443")
    }

    @Test func theGatewayPortIsObidsOrNoneWhenItHasNoGateway() {
        #expect(PairingRoute.gatewayPort(config: Data(#"{"gateway": "127.0.0.1:9910"}"#.utf8)) == 9910)
        #expect(PairingRoute.gatewayPort(config: nil) == 8810)
        #expect(PairingRoute.gatewayPort(config: Data("{}".utf8)) == nil)
        #expect(PairingRoute.gatewayPort(config: Data(#"{"gateway": "127.0.0.1:70000"}"#.utf8)) == nil)
        #expect(PairingRoute.gatewayPort(config: Data(#"{"gateway": "127.0.0.1:0"}"#.utf8)) == nil)
    }
}
