import Foundation
import Testing
@testable import Oby

struct PairingTests {
    @Test func localRunnerPairingUsesTheOwnerSocket() {
        let socket = LocalRunner.socket.path
        let runner = Runner(base: LocalRunner.url, token: "token", unixSocket: socket)
        #expect(runner.unixSocket == socket)
        #expect(Runner(base: LocalRunner.url, token: "token", unixSocket: nil).unixSocket == nil)
    }

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
}
