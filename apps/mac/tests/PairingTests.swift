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

    @Test func theTailnetRouteIsTheServeURLThatProxiesToTheGateway() {
        #expect(PairingRoute.tailnetHost(serveStatus: Data(Self.serve.utf8), port: 8810) == "mac.tail0000.ts.net:8443")
    }

    @Test func aFunnelURLIsNeverTheRoute() {
        let json = #"{"Web": {"mac.tail0000.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8810"}}}}, "AllowFunnel": {"mac.tail0000.ts.net:443": true}}"#
        #expect(PairingRoute.tailnetHost(serveStatus: Data(json.utf8), port: 8810) == nil)
    }

    @Test func aServeURLForAnotherPortOrPathIsNotTheRoute() {
        #expect(PairingRoute.tailnetHost(serveStatus: Data(Self.serve.utf8), port: 9999) == nil)
        let path = #"{"Web": {"mac.tail0000.ts.net:8443": {"Handlers": {"/oby": {"Proxy": "http://127.0.0.1:8810"}}}}}"#
        #expect(PairingRoute.tailnetHost(serveStatus: Data(path.utf8), port: 8810) == nil)
    }

    @Test func aTCPForwardThatEndsTLSIsARoute() {
        let json = #"{"TCP": {"8443": {"TCPForward": "127.0.0.1:8810", "TerminateTLS": "mac.tail0000.ts.net"}}}"#
        #expect(PairingRoute.tailnetHost(serveStatus: Data(json.utf8), port: 8810) == "mac.tail0000.ts.net:8443")
        let plain = #"{"TCP": {"8443": {"TCPForward": "127.0.0.1:8810"}}}"#
        #expect(PairingRoute.tailnetHost(serveStatus: Data(plain.utf8), port: 8810) == nil)
    }

    @Test func noTailscaleMeansNoTailnetRoute() async {
        #expect(await PairingRoute.tailnetHost(port: 8810, clis: ["/nonexistent/tailscale"]) == nil)
        #expect(PairingRoute.tailnetHost(serveStatus: Data("{}".utf8), port: 8810) == nil)
        #expect(PairingRoute.tailnetHost(serveStatus: Data("not json".utf8), port: 8810) == nil)
    }

    @Test func remoteAccessComesFirstThenTheTailnet() {
        #expect(PairingRoute.routes(remote: "oby-abcdefghijklmnop.tetrix.pro", tailscale: "mac.tail0000.ts.net:8443")
            == [.remote("oby-abcdefghijklmnop.tetrix.pro"), .tailscale("mac.tail0000.ts.net:8443")])
        #expect(PairingRoute.routes(remote: nil, tailscale: "mac.tail0000.ts.net:8443") == [.tailscale("mac.tail0000.ts.net:8443")])
        #expect(PairingRoute.routes(remote: nil, tailscale: nil).isEmpty)
        #expect(PairingRoute.tailscale("mac.tail0000.ts.net:8443").label == "Over Tailscale: mac.tail0000.ts.net:8443")
    }

    @Test func theGatewayPortIsObidsOrTheDefault() {
        #expect(PairingRoute.gatewayPort(config: Data(#"{"gateway": "127.0.0.1:9910"}"#.utf8)) == 9910)
        #expect(PairingRoute.gatewayPort(config: Data("{}".utf8)) == 8810)
        #expect(PairingRoute.gatewayPort(config: nil) == 8810)
    }
}
