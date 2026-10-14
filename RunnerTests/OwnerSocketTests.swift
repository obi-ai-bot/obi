import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

@MainActor
struct OwnerSocketTests {
    @Test func tcpExposesOnlyAgentEndpointsAndRefusesProxyIdentity() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let desk = Desk(accounts: AccountStore(root: root), store: JobStore(url: root.appending(path: "oby.sqlite")))
        let api = API(desk: desk, devices: Devices(file: root.appending(path: "devices.json")))
        let app = Application(router: api.router(access: .agentTCP, agentsOnly: true))
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/jobs", method: .get) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/v1/jobs", method: .get, headers: [.tailscaleUserLogin: "owner@example.com"]) {
                #expect($0.status == .forbidden)
            }
            try await client.execute(uri: "/v1/status", method: .get) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/v1/agent/apple-check", method: .get,
                                     headers: [.authorization: "Bearer \(AppleCheck.token(for: "agentbox2"))"]) {
                #expect($0.status == .notFound)
            }
        }
    }

    @Test func ownerLoginWorksOnlyOverTheUnixSocket() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appending(path: "run/owner.sock")
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let desk = Desk(accounts: AccountStore(root: root), store: JobStore(url: root.appending(path: "oby.sqlite")))
        let api = API(desk: desk, devices: Devices(file: root.appending(path: "devices.json")))
        let app = Application(router: api.router(access: .tailnet(owner: "owner@example.com")),
                              configuration: .init(address: .unixDomainSocket(path: socket.path)),
                              onServerRunning: { _ in _ = chmod(socket.path, 0o600) })
        let service = Task { try await app.runService(gracefulShutdownSignals: []) }
        defer { service.cancel() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: socket.path))
        let mode = (try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode.map { $0 & 0o777 } == 0o600)

        let response = try await Shell.ok(["curl", "--silent", "--show-error", "--unix-socket", socket.path,
                                           "-H", "Tailscale-User-Login: owner@example.com", "http://localhost/v1/jobs"])
        #expect(response == "[]")
    }

    @Test func bubblewrapCanReachOnlyJobTokenRoutesAndCannotSeeTheOwnerSocket() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Workspace.root.appending(path: "run", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let socket = run.appending(path: "agent-test-\(UUID().uuidString).sock")
        try Data().write(to: socket)
        defer { try? FileManager.default.removeItem(at: socket) }
        let sandbox = Agents.sandboxed(["true"], in: nil, own: nil, reading: [socket.path])
        #expect(!sandbox.contains { $0 == socket.path })

        let desk = Desk(accounts: AccountStore(root: root), store: JobStore(url: root.appending(path: "oby.sqlite")))
        let api = API(desk: desk, devices: Devices(file: root.appending(path: "devices.json")))
        let app = Application(router: api.router(access: .agentTCP, agentsOnly: true))
        try await app.test(.live) { server in
            let port = try #require(server.port)
            let token = AppleCheck.token(for: "agentbox1")
            let socketCheck = bubblewrapRuns ? "test ! -e '\(socket.path)' && " : ""
            let probes = "\(socketCheck)curl -sS -o /dev/null -w '%{http_code}' -H 'Tailscale-User-Login: owner@example.com' 'http://localhost:\(port)/v1/jobs' && printf ' ' && curl -sS -o /dev/null -w '%{http_code}' 'http://localhost:\(port)/v1/jobs' && printf ' ' && curl -sS -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer \(token)' 'http://localhost:\(port)/v1/agent/apple-check'"
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = bubblewrapRuns
                ? Agents.sandboxed(["sh", "-c", probes], in: nil, own: nil)
                : ["sh", "-c", probes]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(String(decoding: data, as: UTF8.self) == "403 404 404")
        }
    }
}
