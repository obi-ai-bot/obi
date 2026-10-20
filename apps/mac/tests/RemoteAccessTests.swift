import CryptoKit
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

    static let installation = #"{"id": "i1", "name": "MacBook", "platform": "macos", "createdAt": "2026-10-12T12:00:00.000Z", "lastSeenAt": null, "endpoint": null}"#

    static let signIn = #"{"url": "https://appleid.apple.com/auth/authorize?client_id=com.deskree.oby.signin&state=s1", "state": "s1"}"#
    static let unregistered = #"{"error": "This Mac isn't registered. Turn remote access on again."}"#

    /// Records what Apple's sheet was opened at, and ends it where `back` says.
    final class Sheet {
        var opened: [URL] = []
        let back: URL?
        init(_ back: String?) { self.back = back.map { URL(string: $0)! } }
        func run(_ url: URL) async throws -> URL {
            opened.append(url)
            guard let back else { throw Shell.Failure(message: "Sign in with Apple was cancelled.") }
            return back
        }
    }

    /// Turning on makes this Mac's key, signs in with Apple (the sheet at the control plane's
    /// authorization URL, coming back to oby-signin://done with the same state), registers with
    /// that sign-in, keeps the key and the tunnel's token in the keychain and the hostname in the
    /// defaults, and runs cloudflared with the token in its environment, never in its arguments.
    /// Every call is signed by the key. Off keeps the hostname; Forget removes the installation,
    /// signed, and the key with it.
    @Test @MainActor func turningOnSignsInWithAppleAndRunsTheTunnel() async throws {
        let exchange = Exchange([
            (410, Self.unregistered),
            (201, Self.signIn),
            (201, #"{"installation": \#(Self.installation)}"#),
            (201, #"{"endpoint": {"hostname": "oby-abcdefghij0123456789.tetrix.pro", "tunnelId": "t1", "createdAt": "2026-10-12T12:00:01.000Z"}}"#),
            (200, #"{"token": "eyJ-run-token", "hostname": "oby-abcdefghij0123456789.tetrix.pro"}"#),
        ])
        let secrets = KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)")
        defer { for name in (try? secrets.names()) ?? [] { try? secrets.remove(name) } }
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        let launched = Launched()
        let runner = TunnelRunner(binary: URL(filePath: "/usr/bin/true"), launch: { launched.processes.append($0) })
        let sheet = Sheet("oby-signin://done?state=s1&code=c1")
        let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: exchange.transport),
                                  secrets: secrets, defaults: defaults, runner: runner, authenticate: sheet.run)
        defer { remote.stop() }
        #expect(!remote.on)
        #expect(remote.status == "Off")

        await remote.turnOn()
        #expect(remote.problem == nil)
        #expect(remote.on)
        #expect(remote.hostname == "oby-abcdefghij0123456789.tetrix.pro")
        #expect(defaults.bool(forKey: "remote.enabled"))
        let saved = try #require(try secrets.value(RemoteAccess.keyKey))
        #expect(saved.hasPrefix(SecureEnclave.isAvailable ? "se:" : "sw:"))
        #expect(try secrets.value(RemoteAccess.tokenKey) == "eyJ-run-token")
        let process = try #require(launched.processes.first)
        #expect(process.executableURL?.path == "/usr/bin/true")
        #expect(process.arguments == ["tunnel", "--no-autoupdate", "run"])
        #expect(process.environment?["TUNNEL_TOKEN"] == "eyJ-run-token")
        #expect(remote.tunnel == .starting)

        let requests = Array(exchange.requests.prefix(5))
        #expect(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "GET /v1/installations/self", "POST /v1/auth/apple/start", "POST /v1/installations",
            "POST /v1/installations/self/endpoint", "GET /v1/installations/self/endpoint/token",
        ])
        #expect(sheet.opened == [URL(string: "https://appleid.apple.com/auth/authorize?client_id=com.deskree.oby.signin&state=s1")!])
        let body = try JSONDecoder().decode([String: String].self, from: try #require(requests[2].httpBody))
        #expect(body == ["name": Host.current().localizedName ?? "Mac", "platform": "macos", "signIn": "s1", "signInCode": "c1"])
        // Each call's signature checks out against the key's public half, as the Worker checks it.
        let publicKey = try MacKey.signer(saved).publicKey
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Oby-Key") == ControlPlane.base64url(publicKey))
            #expect(try Self.verifies(request, publicKey: publicKey))
        }

        // Off keeps the hostname for next time; nothing ran, so there's nothing to end.
        remote.turnOff()
        #expect(!remote.on)
        #expect(remote.hostname == "oby-abcdefghij0123456789.tetrix.pro")
        #expect(!defaults.bool(forKey: "remote.enabled"))
        #expect(remote.tunnel == .off)

        // Forget: one signed call, then nothing of it stays here.
        let forgetting = Exchange([(204, "")])
        let forgets = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: forgetting.transport),
                                   secrets: secrets, defaults: defaults, runner: runner)
        await forgets.forget()
        #expect(forgets.problem == nil)
        #expect(forgetting.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == ["DELETE /v1/installations/self"])
        #expect(try Self.verifies(try #require(forgetting.requests.first), publicKey: publicKey))
        #expect(try secrets.value(RemoteAccess.keyKey) == nil)
        #expect(try secrets.value(RemoteAccess.tokenKey) == nil)
        #expect(forgets.hostname == nil)
        #expect(defaults.string(forKey: "remote.hostname") == nil)
    }



    /// Cancelled at Apple, or sent back with another state: no registration, and Settings says why.
    @Test @MainActor func aSignInThatDoesntFinishRegistersNothing() async throws {
        for (back, said) in [(nil, "Sign in with Apple was cancelled."), ("oby-signin://done?state=someone-elses&code=c1", "Sign in with Apple didn't finish. Try again."),
                             ("oby-signin://failed?state=s1", "Sign in with Apple didn't finish. Try again."),
                             ("oby-signin://done?state=s1", "Sign in with Apple didn't finish. Try again.")] {
            let exchange = Exchange([(410, Self.unregistered), (201, Self.signIn)])
            let secrets = KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)")
            defer { for name in (try? secrets.names()) ?? [] { try? secrets.remove(name) } }
            let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
            let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: exchange.transport),
                                      secrets: secrets, defaults: defaults,
                                      runner: TunnelRunner(binary: URL(filePath: "/usr/bin/true"), launch: { _ in }), authenticate: Sheet(back).run)
            await remote.turnOn()
            #expect(!remote.on)
            #expect(remote.problem == said)
            #expect(exchange.requests.count == 2)
        }
    }

    /// The account had 5 Macs: the control plane removed the one used longest ago, and Settings
    /// says which.
    @Test @MainActor func turningOnSaysWhichMacMadeRoom() async throws {
        let exchange = Exchange([
            (410, Self.unregistered),
            (201, Self.signIn),
            (201, #"{"installation": \#(Self.installation), "evicted": {"name": "Old iMac"}}"#),
            (201, #"{"endpoint": {"hostname": "oby-abcdefghij0123456789.oby-devices.test", "tunnelId": "t1", "createdAt": "2026-10-12T12:00:01.000Z"}}"#),
            (200, #"{"token": "eyJ-run-token", "hostname": "oby-abcdefghij0123456789.oby-devices.test"}"#),
        ])
        let secrets = KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)")
        defer { for name in (try? secrets.names()) ?? [] { try? secrets.remove(name) } }
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: exchange.transport),
                                  secrets: secrets, defaults: defaults,
                                  runner: TunnelRunner(binary: URL(filePath: "/usr/bin/true"), launch: { _ in }),
                                  authenticate: Sheet("oby-signin://done?state=s1&code=c1").run)
        defer { remote.stop() }
        await remote.turnOn()
        #expect(remote.on)
        #expect(remote.problem == "Your Apple Account had 5 Macs with remote access, so “Old iMac”, the one used longest ago, was removed to make room.")
    }

    /// The control plane took the tunnel back (not connected for days): the check-in sees no
    /// endpoint and, on, sets one up again with its new hostname.
    @Test @MainActor func aReclaimedTunnelIsSetUpAgainAtTheCheckIn() async throws {
        let exchange = Exchange([
            (200, #"{"installation": \#(Self.installation)}"#),
            // Still registered: no sign-in, straight to a new endpoint.
            (200, #"{"installation": \#(Self.installation)}"#),
            (201, #"{"endpoint": {"hostname": "oby-newnewnewnew01234567.oby-devices.test", "tunnelId": "t2", "createdAt": "2026-11-12T12:00:01.000Z"}}"#),
            (200, #"{"token": "eyJ-new-token", "hostname": "oby-newnewnewnew01234567.oby-devices.test"}"#),
        ])
        let secrets = KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)")
        defer { for name in (try? secrets.names()) ?? [] { try? secrets.remove(name) } }
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        defaults.set("oby-abcdefghij0123456789.oby-devices.test", forKey: "remote.hostname")
        defaults.set(true, forKey: "remote.enabled")
        try secrets.save(try MacKey.make(), as: RemoteAccess.keyKey)
        let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: exchange.transport),
                                  secrets: secrets, defaults: defaults,
                                  runner: TunnelRunner(binary: URL(filePath: "/usr/bin/true"), launch: { _ in }),
                                  authenticate: { _ in Issue.record("no sign-in sheet at a check-in"); return URL(string: "oby-signin://failed")! })
        defer { remote.stop() }
        await remote.checkIn()
        #expect(remote.problem == nil)
        #expect(remote.hostname == "oby-newnewnewnew01234567.oby-devices.test")
        #expect(exchange.requests.prefix(4).map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "GET /v1/installations/self", "GET /v1/installations/self", "POST /v1/installations/self/endpoint", "GET /v1/installations/self/endpoint/token",
        ])
    }

    /// The control plane removed this Mac (away 30 days): the check-in turns remote access off and
    /// says to turn it on again, which signs in with Apple. Never a sheet out of the blue.
    @Test @MainActor func aForgottenMacIsOffAfterItsCheckIn() async throws {
        let exchange = Exchange([(410, Self.unregistered)])
        let secrets = KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)")
        defer { for name in (try? secrets.names()) ?? [] { try? secrets.remove(name) } }
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        defaults.set("oby-abcdefghij0123456789.tetrix.pro", forKey: "remote.hostname")
        defaults.set(true, forKey: "remote.enabled")
        try secrets.save(try MacKey.make(), as: RemoteAccess.keyKey)
        try secrets.save("eyJ-run-token", as: RemoteAccess.tokenKey)
        let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: exchange.transport),
                                  secrets: secrets, defaults: defaults,
                                  runner: TunnelRunner(binary: URL(filePath: "/usr/bin/true"), launch: { _ in }),
                                  authenticate: { _ in Issue.record("no sign-in sheet at a check-in"); return URL(string: "oby-signin://failed")! })
        defer { remote.stop() }

        await remote.checkIn()
        #expect(!remote.on)
        #expect(remote.hostname == nil)
        #expect(!defaults.bool(forKey: "remote.enabled"))
        #expect(remote.problem == "This Mac was away from remote access for 30 days. Turn it on again to sign in with Apple.")
        #expect(exchange.requests.count == 1)
    }

    /// At launch with remote access on, the tunnel runs again from the keychain's token; with
    /// the token gone, it says so and stays off. The email sign-in's leftovers go.
    @Test @MainActor func startsAgainFromTheKeychain() throws {
        let secrets = KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)")
        defer { for name in (try? secrets.names()) ?? [] { try? secrets.remove(name) } }
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        defaults.set(true, forKey: "remote.enabled")
        try secrets.save("eyJ-run-token", as: RemoteAccess.tokenKey)
        for name in RemoteAccess.oldSecrets { try secrets.save("old", as: name) }
        for key in RemoteAccess.oldDefaults { defaults.set("old", forKey: key) }
        let launched = Launched()
        let plane = ControlPlane(base: URL(string: "https://oby-control.test")!) { _ in (Data(), 500) }
        let remote = RemoteAccess(plane: plane, secrets: secrets, defaults: defaults,
                                  runner: TunnelRunner(binary: URL(filePath: "/usr/bin/true"), launch: { launched.processes.append($0) }))
        #expect(remote.on)
        remote.start()
        #expect(try secrets.names().sorted() == [RemoteAccess.tokenKey])
        #expect(RemoteAccess.oldDefaults.allSatisfy { defaults.object(forKey: $0) == nil })
        #expect(launched.processes.first?.environment?["TUNNEL_TOKEN"] == "eyJ-run-token")
        #expect(remote.tunnel == .starting)

        try secrets.remove(RemoteAccess.tokenKey)
        let again = RemoteAccess(plane: plane, secrets: secrets, defaults: defaults,
                                 runner: TunnelRunner(binary: URL(filePath: "/usr/bin/true"), launch: { launched.processes.append($0) }))
        again.start()
        #expect(!again.on)
        #expect(again.problem?.contains("keychain") == true)
        #expect(launched.processes.count == 1)
    }


    /// The Worker's check (cloud/control-plane/src/app.ts, `signed`), in CryptoKit.
    static func verifies(_ request: URLRequest, publicKey: Data) throws -> Bool {
        let header = { (name: String) in request.value(forHTTPHeaderField: name) ?? "" }
        let head = ["oby-control-v1", request.httpMethod ?? "", request.url?.path ?? "", header("Oby-Timestamp"), header("Oby-Nonce"), ""].joined(separator: "\n")
        let signature = try #require(Data(base64Encoded: base64(header("Oby-Signature"))))
        return try P256.Signing.PublicKey(x963Representation: publicKey)
            .isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: signature), for: Data(head.utf8) + (request.httpBody ?? Data()))
    }

    private static func base64(_ url: String) -> String {
        let plain = url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return plain + String(repeating: "=", count: (4 - plain.count % 4) % 4)
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
