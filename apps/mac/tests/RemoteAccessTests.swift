import Foundation
import Testing
@testable import Oby

/// Remote access (#285): the cloudflared bundled with Oby, and this Mac's side of turning it on.
struct RemoteAccessTests {
    /// cloudflared ships inside Oby.app (apps/mac/app/Tools/bundle-cloudflared.sh): the pinned release,
    /// universal, signed with the app's identity and the hardened runtime.
    @Test func cloudflaredIsBundledAndSigned() throws {
        let binary = try #require(TunnelRunner.bundled)
        #expect(binary.path.hasSuffix("/Contents/MacOS/cloudflared"))
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))
        let verified = try run("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", binary.path])
        #expect(verified.status == 0, Comment(rawValue: "codesign --verify: \(verified.err)"))
        let details = try run("/usr/bin/codesign", ["-d", "-vv", binary.path])
        let directory = details.err.split(separator: "\n").first { $0.hasPrefix("CodeDirectory") } ?? ""
        #expect(directory.contains("runtime"), Comment(rawValue: "no hardened runtime: \(details.err)"))
        let slices = try run("/usr/bin/lipo", ["-archs", binary.path])
        #expect(slices.out.contains("arm64") && slices.out.contains("x86_64"), Comment(rawValue: slices.out))
        let version = try run(binary.path, ["--version"])
        #expect(version.out.contains("cloudflared version 2026.10.0"), Comment(rawValue: version.out))
    }

    /// Turning on registers this Mac, keeps the credential and the tunnel's token in the keychain
    /// and the hostname in the defaults, and runs cloudflared with the token in its environment,
    /// never in its arguments. Off keeps the hostname; an ended session signs out.
    @Test @MainActor func turningOnKeepsTheTokenInTheKeychainAndRunsTheTunnel() async throws {
        let installation = #"{"id": "i1", "clientId": "c", "name": "MacBook", "platform": "macos", "createdAt": "2026-10-12T12:00:00.000Z", "lastSeenAt": null, "endpoint": null}"#
        let exchange = Exchange([
            (202, #"{"sent": true}"#),
            (201, #"{"token": "oby_session_abc", "user": {"id": "u1", "email": "well@example.com"}, "expiresAt": "2027-01-10T12:00:00.000Z"}"#),
            (201, #"{"installation": \#(installation), "credential": "oby_install_xyz"}"#),
            (201, #"{"endpoint": {"hostname": "oby-abcdefghij0123456789.tetrix.pro", "tunnelId": "t1", "createdAt": "2026-10-12T12:00:01.000Z"}}"#),
            (200, #"{"token": "eyJ-run-token", "hostname": "oby-abcdefghij0123456789.tetrix.pro"}"#),
            (401, #"{"error": "Sign in again."}"#),
        ])
        let secrets = KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)")
        defer { for name in (try? secrets.names()) ?? [] { try? secrets.remove(name) } }
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        let launched = Launched()
        let runner = TunnelRunner(binary: URL(filePath: "/usr/bin/true"), launch: { launched.processes.append($0) })
        let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: exchange.transport),
                                  secrets: secrets, defaults: defaults, runner: runner)
        #expect(remote.step == .signedOut)

        await remote.requestCode(" Well@example.com ")
        #expect(remote.step == .codeSent("Well@example.com"))
        await remote.verify("123456")
        #expect(remote.step == .signedIn)
        #expect(remote.email == "well@example.com")
        #expect(try secrets.value(RemoteAccess.sessionKey) == "oby_session_abc")

        await remote.turnOn()
        #expect(remote.problem == nil)
        #expect(remote.step == .on)
        #expect(remote.hostname == "oby-abcdefghij0123456789.tetrix.pro")
        #expect(defaults.bool(forKey: "remote.enabled"))
        #expect(defaults.string(forKey: "remote.installation") == "i1")
        #expect(try secrets.value(RemoteAccess.credentialKey) == "oby_install_xyz")
        #expect(try secrets.value(RemoteAccess.tokenKey) == "eyJ-run-token")
        let process = try #require(launched.processes.first)
        #expect(process.executableURL?.path == "/usr/bin/true")
        #expect(process.arguments == ["tunnel", "--no-autoupdate", "run"])
        #expect(process.environment?["TUNNEL_TOKEN"] == "eyJ-run-token")
        #expect(remote.tunnel == .starting)

        let paths = exchange.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(paths == ["POST /v1/auth/otp/request", "POST /v1/auth/otp/verify", "POST /v1/installations",
                          "POST /v1/installations/self/endpoint", "GET /v1/installations/self/endpoint/token"])
        let body = try JSONDecoder().decode([String: String].self, from: try #require(exchange.requests[2].httpBody))
        #expect(body["clientId"] == remote.clientID)
        #expect(body["platform"] == "macos")
        #expect(exchange.requests[4].value(forHTTPHeaderField: "Authorization") == "Bearer oby_install_xyz")

        // Off keeps the hostname for next time; nothing ran, so there's nothing to end.
        remote.turnOff()
        #expect(remote.step == .signedIn)
        #expect(remote.hostname == "oby-abcdefghij0123456789.tetrix.pro")
        #expect(!defaults.bool(forKey: "remote.enabled"))
        #expect(remote.tunnel == .off)

        // On again with a session that ended: signed out, with the control plane's line.
        await remote.turnOn()
        #expect(remote.step == .signedOut)
        #expect(remote.problem == "Sign in again.")
        #expect(try secrets.value(RemoteAccess.sessionKey) == nil)
        #expect(launched.processes.count == 1)
    }

    /// At launch with remote access on, the tunnel runs again from the keychain's token; with
    /// the token gone, it says so and stays off.
    @Test @MainActor func startsAgainFromTheKeychain() throws {
        let secrets = KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)")
        defer { for name in (try? secrets.names()) ?? [] { try? secrets.remove(name) } }
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        defaults.set("well@example.com", forKey: "remote.email")
        defaults.set("oby-abcdefghij0123456789.tetrix.pro", forKey: "remote.hostname")
        defaults.set(true, forKey: "remote.enabled")
        try secrets.save("eyJ-run-token", as: RemoteAccess.tokenKey)
        let launched = Launched()
        let plane = ControlPlane(base: URL(string: "https://oby-control.test")!) { _ in (Data(), 500) }
        let remote = RemoteAccess(plane: plane, secrets: secrets, defaults: defaults,
                                  runner: TunnelRunner(binary: URL(filePath: "/usr/bin/true"), launch: { launched.processes.append($0) }))
        #expect(remote.step == .on)
        remote.start()
        #expect(launched.processes.first?.environment?["TUNNEL_TOKEN"] == "eyJ-run-token")
        #expect(remote.tunnel == .starting)

        try secrets.remove(RemoteAccess.tokenKey)
        let again = RemoteAccess(plane: plane, secrets: secrets, defaults: defaults,
                                 runner: TunnelRunner(binary: URL(filePath: "/usr/bin/true"), launch: { launched.processes.append($0) }))
        again.start()
        #expect(again.step == .signedIn)
        #expect(again.problem?.contains("keychain") == true)
        #expect(launched.processes.count == 1)
    }

    /// Records every request and answers from a script, in order.
    final class Exchange: @unchecked Sendable {
        var requests: [URLRequest] = []
        var answers: [(Int, String)]
        let lock = NSLock()
        init(_ answers: [(Int, String)]) { self.answers = answers }

        func transport(_ request: URLRequest) async throws -> (Data, Int) {
            lock.withLock {
                requests.append(request)
                guard !answers.isEmpty else { return (Data(), 500) }
                let (status, body) = answers.removeFirst()
                return (Data(body.utf8), status)
            }
        }
    }

    final class Launched {
        var processes: [Process] = []
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output, error)
    }
}
