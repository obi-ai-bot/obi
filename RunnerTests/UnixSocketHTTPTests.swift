import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import ObyEngine
@testable import oby_runner

/// The local Mac client's Unix-socket transport (#397 review fixes).
@MainActor
struct UnixSocketHTTPTests {
    @Test func resumeOnceResumesOnlyOnce() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(done)
            #expect(once.resume(returning: ()))
            #expect(!once.resume(returning: ()))
            #expect(!once.resume(throwing: LocalSocketError.timedOut))
            #expect(!once.isPending)
        }
    }

    @Test func resumeOnceFailedPathAlsoResumesOnlyOnce() async {
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                let once = ResumeOnce(done)
                #expect(once.resume(throwing: LocalSocketError.closedEarly))
                #expect(!once.resume(returning: ()))
                #expect(!once.resume(throwing: LocalSocketError.timedOut))
            }
            Issue.record("expected throw")
        } catch {
            #expect((error as? LocalSocketError) == .closedEarly)
        }
    }

    @Test func socketDeadlineTimesOutAStalledOperation() async {
        let started = ContinuousClock.now
        do {
            _ = try await SocketDeadline.withTimeout(.milliseconds(80)) {
                try await Task.sleep(for: .seconds(60))
                return "done"
            }
            Issue.record("expected timeout")
        } catch {
            #expect((error as? LocalSocketError) == .timedOut)
        }
        // Under a busy suite the cooperative pool can delay the sleep; it must still beat the
        // 60s hang, not wait it out.
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    @Test func socketDeadlineHonoursTaskCancellation() async throws {
        let task = Task {
            try await SocketDeadline.withTimeout(.seconds(30)) {
                try await Task.sleep(for: .seconds(30))
                return "done"
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch let error as LocalSocketError where error == .timedOut {
            Issue.record("deadline raced cancellation")
        }
    }

    @Test func streamRetainsItsPumpUntilTermination() async throws {
        final class Probe: @unchecked Sendable {
            let box: Box
            init(box: Box) { self.box = box; box.alive = true }
            deinit { box.alive = false }
        }
        final class Box: @unchecked Sendable {
            var alive = false
        }
        let box = Box()
        var held: AsyncThrowingStream<UInt8, Error>.Continuation?
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            held = continuation
            let probe = Probe(box: box)
            // Same retain pattern as UnixSocketHTTP.stream: onTermination keeps the pump alive
            // for the stream's lifetime (fix for the weak-self drop after the builder returns).
            continuation.onTermination = { _ in _ = probe }
        }
        // After the stream builder returns, a weak pump would already be gone.
        #expect(box.alive)
        _ = stream
        held?.finish()
    }

    @Test func pairingInviteListAndRevokeWorkOverTheOwnerSocket() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let socketRoot = URL(fileURLWithPath: "/tmp/oby-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: socketRoot) }
        let socket = socketRoot.appending(path: "run/owner.sock")
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let token = String(repeating: "ab", count: 32)
        let desk = Desk(accounts: AccountStore(root: root), store: JobStore(url: root.appending(path: "oby.sqlite")))
        let devices = Devices(file: root.appending(path: "devices.json"))
        let api = API(desk: desk, devices: devices)
        let app = Application(router: api.router(access: .local(token: token)),
                              configuration: .init(address: .unixDomainSocket(path: socket.path)),
                              onServerRunning: { _ in _ = chmod(socket.path, 0o600) })
        let service = Task { try await app.runService(gracefulShutdownSignals: []) }
        defer { service.cancel() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: socket.path))

        // Wait until the owner socket answers (suite load can delay the listener).
        var ready = false
        for _ in 0..<50 {
            var probe = URLRequest(url: URL(string: "http://localhost/v1/pairing/devices")!)
            probe.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            probe.timeoutInterval = 2
            if let (_, response) = try? await UnixSocketHTTP.data(for: probe, path: socket.path),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(ready)

        var request = URLRequest(url: URL(string: "http://localhost/v1/pairing/invite")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"url":"https://oby-test.tetrix.pro","name":"Test Mac","hostname":"oby-test.tetrix.pro"}"#.utf8)
        let (inviteData, inviteResponse) = try await UnixSocketHTTP.data(for: request, path: socket.path)
        let inviteHTTP = try #require(inviteResponse as? HTTPURLResponse)
        #expect(inviteHTTP.statusCode == 200)
        struct Invitation: Decodable { var code: String; var secret: String }
        let invitation = try JSONDecoder().decode(Invitation.self, from: inviteData)
        #expect(invitation.code.count == 6 && invitation.secret.count >= 32)

        var list = URLRequest(url: URL(string: "http://localhost/v1/pairing/devices")!)
        list.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        list.timeoutInterval = 30
        let (listData, listResponse) = try await UnixSocketHTTP.data(for: list, path: socket.path)
        #expect((listResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: listData, as: UTF8.self) == "[]")

        let redeemed = try Gateway(devices: devices, pairing: api.pairing).redeem(invitation.code, name: "Phone")
        let (listed, _) = try await UnixSocketHTTP.data(for: list, path: socket.path)
        struct Device: Decodable { var id: String; var name: String }
        let devicesJSON = try JSONDecoder().decode([Device].self, from: listed)
        #expect(devicesJSON.count == 1 && devicesJSON.first?.name == "Phone")
        let id = try #require(devicesJSON.first?.id)

        var revoke = URLRequest(url: URL(string: "http://localhost/v1/pairing/devices/\(id)")!)
        revoke.httpMethod = "DELETE"
        revoke.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        revoke.timeoutInterval = 30
        let (_, revokeResponse) = try await UnixSocketHTTP.data(for: revoke, path: socket.path)
        #expect((revokeResponse as? HTTPURLResponse)?.statusCode == 204)
        #expect(!devices.acceptsGatewayToken(redeemed.token))
    }

    @Test func pairingRoutesAreAbsentOnAgentTCP() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let desk = Desk(accounts: AccountStore(root: root), store: JobStore(url: root.appending(path: "oby.sqlite")))
        let api = API(desk: desk, devices: Devices(file: root.appending(path: "devices.json")))
        let app = Application(router: api.router(access: .agentTCP, agentsOnly: true))
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/pairing/invite", method: .post) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/v1/pairing/devices", method: .get) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/v1/pairing/devices/abc", method: .delete) { #expect($0.status == .notFound) }
        }
    }

    @Test func unixSocketRequestTimesOutWhenThePeerNeverAnswers() async throws {
        let socketRoot = URL(fileURLWithPath: "/tmp/oby-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: socketRoot) }
        try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: true)
        let path = socketRoot.appending(path: "hang.sock").path
        let listenFD = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #expect(listenFD >= 0)
        defer { close(listenFD) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in utf8.enumerated() { buffer[index] = byte }
        }
        #expect(withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0)
        #expect(Glibc.listen(listenFD, 1) == 0)
        // Accept in the background so connect succeeds, then never reply.
        let acceptor = Task.detached {
            var remote = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &length) }
            }
            if client >= 0 {
                try? await Task.sleep(for: .seconds(30))
                close(client)
            }
        }
        defer { acceptor.cancel() }

        var request = URLRequest(url: URL(string: "http://localhost/v1/status")!)
        request.timeoutInterval = 0.08
        let started = ContinuousClock.now
        do {
            _ = try await UnixSocketHTTP.data(for: request, path: path)
            Issue.record("expected timeout")
        } catch {
            #expect((error as? LocalSocketError) == .timedOut)
        }
        #expect(ContinuousClock.now - started < .seconds(20))
    }
}
