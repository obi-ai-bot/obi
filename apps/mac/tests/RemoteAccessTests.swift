import CryptoKit
import Foundation
import Testing
@testable import Oby

/// Remote access (#285): the cloudflared bundled with Oby, and this Mac's side of turning it on.
struct RemoteAccessTests {
    /// A full build of Oby.app (OBY_FULL_BUILD=1) carries cloudflared, obi-vm and obid's web app, and
    /// the launch build none of them (docs/release.md, "Full builds"). cloudflared, when it's there, is
    /// the pinned release (apps/mac/app/Tools/bundle-cloudflared.sh), universal, signed with the app's
    /// identity and the hardened runtime.
    @Test func aFullBuildBundlesAllThreeAndTheLaunchBuildNone() throws {
        let contents = Bundle.main.bundleURL.appending(path: "Contents")
        let parts = ["MacOS/cloudflared", "Helpers/obi-vm", "Resources/obid/web/index.html"]
        let there = parts.filter { FileManager.default.fileExists(atPath: contents.appending(path: $0).path) }
        #expect(there.isEmpty || there == parts, Comment(rawValue: "only \(there) of \(parts)"))
        guard let binary = ObidTunnel.bundled else { return }
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
        let host = FakeHost()
        let sheet = Sheet("oby-signin://done?state=s1&code=c1")
        let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: exchange.transport),
                                  secrets: secrets, defaults: defaults, host: host, authenticate: sheet.run)
        defer { remote.stop() }
        #expect(!remote.on)
        #expect(remote.status == "Off")

        await remote.turnOn(with: .apple)
        #expect(remote.problem == nil)
        #expect(remote.on)
        #expect(remote.hostname == "oby-abcdefghij0123456789.tetrix.pro")
        #expect(defaults.bool(forKey: "remote.enabled"))
        let saved = try #require(try secrets.value(RemoteAccess.keyKey))
        #expect(saved.hasPrefix(SecureEnclave.isAvailable ? "se:" : "sw:"))
        // The run token goes to obid (#896), which runs cloudflared; the app keeps no copy.
        #expect(host.handed == ["eyJ-run-token"])
        #expect(try secrets.value(RemoteAccess.tokenKey) == nil)
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

        // Off stops obid's tunnel and keeps the hostname for next time.
        await remote.turnOff()
        #expect(!remote.on)
        #expect(remote.hostname == "oby-abcdefghij0123456789.tetrix.pro")
        #expect(!defaults.bool(forKey: "remote.enabled"))
        #expect(host.stops == 1)
        #expect(remote.tunnel == .off)

        // Forget: one signed call, then nothing of it stays here.
        let forgetting = Exchange([(204, "")])
        let forgets = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: forgetting.transport),
                                   secrets: secrets, defaults: defaults, host: host)
        await forgets.forget()
        #expect(host.stops == 2)
        #expect(forgets.problem == nil)
        #expect(forgetting.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == ["DELETE /v1/installations/self"])
        #expect(try Self.verifies(try #require(forgetting.requests.first), publicKey: publicKey))
        #expect(try secrets.value(RemoteAccess.keyKey) == nil)
        #expect(try secrets.value(RemoteAccess.tokenKey) == nil)
        #expect(forgets.hostname == nil)
        #expect(defaults.string(forKey: "remote.hostname") == nil)
    }



    /// Settings offers the sign-in buttons while this Mac has no hostname, Google's then Apple's,
    /// until the control plane says what it takes; Google's signs in at Google (the control plane's Google URL in the sheet) and
    /// registers with that sign-in. Set up, the switch is back.
    @Test @MainActor func turningOnOffersAppleAndGoogle() async throws {
        let google = #"{"url": "https://accounts.google.com/o/oauth2/v2/auth?client_id=1234-oby.apps.googleusercontent.com&state=s1", "state": "s1"}"#
        let exchange = Exchange([
            (410, Self.unregistered),
            (201, google),
            (201, #"{"installation": \#(Self.installation.replacingOccurrences(of: #""id": "i1","#, with: #""id": "i1", "account": {"provider": "google", "domain": "deskree.com"},"#))}"#),
            (201, #"{"endpoint": {"hostname": "oby-abcdefghij0123456789.oby-devices.test", "tunnelId": "t1", "createdAt": "2026-10-12T12:00:01.000Z"}}"#),
            (200, #"{"token": "eyJ-run-token", "hostname": "oby-abcdefghij0123456789.oby-devices.test"}"#),
        ])
        let secrets = KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)")
        defer { for name in (try? secrets.names()) ?? [] { try? secrets.remove(name) } }
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        let sheet = Sheet("oby-signin://done?state=s1&code=c1")
        let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: exchange.transport),
                                  secrets: secrets, defaults: defaults,
                                  host: FakeHost(), authenticate: sheet.run)
        defer { remote.stop() }
        #expect(remote.signsInFirst)

        await remote.turnOn(with: .google)
        #expect(remote.problem == nil)
        #expect(remote.on)
        #expect(!remote.signsInFirst)
        #expect(remote.accountName == "Google · deskree.com")
        #expect(exchange.requests.prefix(3).map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == [
            "GET /v1/installations/self", "POST /v1/auth/google/start", "POST /v1/installations",
        ])
        #expect(sheet.opened == [URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=1234-oby.apps.googleusercontent.com&state=s1")!])
        let body = try JSONDecoder().decode([String: String].self, from: try #require(exchange.requests[2].httpBody))
        #expect(body["signIn"] == "s1" && body["signInCode"] == "c1")
        // Off keeps the hostname: the switch, not the buttons.
        await remote.turnOff()
        #expect(!remote.signsInFirst)
    }

    /// Before signing in, Settings asks the control plane what it takes: a members-only one offers
    /// Google alone and says whose accounts; one that doesn't answer leaves both buttons.
    @Test @MainActor func signInOptionsComeFromTheControlPlane() async throws {
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        let members = Exchange([(200, #"{"providers": ["google"], "workspaces": ["deskree.com"]}"#)])
        let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: members.transport),
                                  secrets: KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)"), defaults: defaults,
                                  host: FakeHost(), authenticate: { $0 })
        #expect(remote.providers == [.google, .apple])
        await remote.loadSignInOptions()
        #expect(remote.providers == [.google])
        #expect(remote.workspaces == ["deskree.com"])
        #expect(members.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } == ["GET /v1/auth"])
        #expect(members.requests.first?.value(forHTTPHeaderField: "Oby-Signature") == nil)

        let down = Exchange([(503, #"{"error": "down"}"#)])
        let offline = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: down.transport),
                                   secrets: KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)"), defaults: defaults,
                                   host: FakeHost(), authenticate: { $0 })
        await offline.loadSignInOptions()
        #expect(offline.providers == [.google, .apple])
    }

    /// A Google sign-in that comes back failed names Google.
    @Test @MainActor func aGoogleSignInThatDoesntFinishSaysGoogle() async throws {
        let exchange = Exchange([(410, Self.unregistered), (201, Self.signIn)])
        let secrets = KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)")
        defer { for name in (try? secrets.names()) ?? [] { try? secrets.remove(name) } }
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: exchange.transport),
                                  secrets: secrets, defaults: defaults,
                                  host: FakeHost(),
                                  authenticate: Sheet("oby-signin://failed?state=s1").run)
        await remote.turnOn(with: .google)
        #expect(!remote.on)
        #expect(remote.problem == "Sign in with Google didn't finish. Try again.")
        #expect(exchange.requests.map { $0.url?.path ?? "" } == ["/v1/installations/self", "/v1/auth/google/start"])
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
                                      host: FakeHost(), authenticate: Sheet(back).run)
            await remote.turnOn(with: .apple)
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
                                  host: FakeHost(),
                                  authenticate: Sheet("oby-signin://done?state=s1&code=c1").run)
        defer { remote.stop() }
        await remote.turnOn(with: .apple)
        #expect(remote.on)
        #expect(remote.problem == "Your account had 5 Macs with remote access, so “Old iMac”, the one used longest ago, was removed to make room.")
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
                                  host: FakeHost(),
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
    /// says to sign in again, and Settings offers the sign-in buttons. Never a sheet out of the blue.
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
                                  host: FakeHost(),
                                  authenticate: { _ in Issue.record("no sign-in sheet at a check-in"); return URL(string: "oby-signin://failed")! })
        defer { remote.stop() }

        await remote.checkIn()
        #expect(!remote.on)
        #expect(remote.hostname == nil)
        #expect(!defaults.bool(forKey: "remote.enabled"))
        #expect(remote.signsInFirst)
        #expect(remote.problem == "This Mac was away from remote access for 30 days. Sign in again to turn it on.")
        #expect(exchange.requests.count == 1)
    }

    /// #896: an older Oby kept the run token in its own keychain and ran cloudflared itself. At
    /// launch that token goes to obid once and the app's copy is deleted; the next launch has
    /// nothing to hand over, and remote access stays on (obid has the token). The email sign-in's
    /// leftovers go.
    @Test @MainActor func aTokenLeftInTheKeychainMovesToObidOnce() async throws {
        let secrets = KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)")
        defer { for name in (try? secrets.names()) ?? [] { try? secrets.remove(name) } }
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        defaults.set(true, forKey: "remote.enabled")
        try secrets.save("eyJ-run-token", as: RemoteAccess.tokenKey)
        for name in RemoteAccess.oldSecrets { try secrets.save("old", as: name) }
        for key in RemoteAccess.oldDefaults { defaults.set("old", forKey: key) }
        let host = FakeHost()
        let plane = ControlPlane(base: URL(string: "https://oby-control.test")!) { _ in (Data(), 500) }
        let remote = RemoteAccess(plane: plane, secrets: secrets, defaults: defaults, host: host)
        defer { remote.stop() }
        #expect(remote.on)
        await remote.start()
        #expect(host.handed == ["eyJ-run-token"])
        #expect(try secrets.names().isEmpty)
        #expect(RemoteAccess.oldDefaults.allSatisfy { defaults.object(forKey: $0) == nil })

        let again = RemoteAccess(plane: plane, secrets: secrets, defaults: defaults, host: host)
        defer { again.stop() }
        await again.start()
        #expect(again.on && again.problem == nil)
        #expect(host.handed.count == 1)
    }

    /// The launch build hides Remote access (`Launch`): a Mac with a hostname and remote access off
    /// doesn't call the control plane at launch; on, or with `showEverything`, it checks in.
    @Test(arguments: [(false, false, false), (true, false, true), (false, true, true)])
    @MainActor func aMacChecksInOnlyWhileRemoteIsOn(on: Bool, everything: Bool, checksIn: Bool) async throws {
        let hostname = "oby-abcdefghij0123456789.oby-devices.test"
        let exchange = Exchange([(200, #"{"installation": {"id": "i1", "name": "MacBook", "platform": "macos", "createdAt": "2026-10-12T12:00:00.000Z", "lastSeenAt": null, "endpoint": {"hostname": "\#(hostname)", "tunnelId": "t1", "createdAt": "2026-10-12T12:00:01.000Z"}}}"#)])
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-remote-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let secrets = FileVault(folder: folder)
        try secrets.save(try MacKey.make(), as: RemoteAccess.keyKey)
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        defaults.set(hostname, forKey: "remote.hostname")
        defaults.set(on, forKey: "remote.enabled")
        defaults.set(everything, forKey: Launch.everythingKey)
        let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: exchange.transport),
                                  secrets: secrets, defaults: defaults, host: FakeHost(),
                                  authenticate: { _ in Issue.record("no sign-in sheet at a check-in"); return URL(string: "oby-signin://failed")! })
        defer { remote.stop() }
        await remote.start()
        let asked = { exchange.lock.withLock { exchange.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } } }
        for _ in 0..<20 where asked().isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(asked() == (checksIn ? ["GET /v1/installations/self"] : []))
        #expect(remote.hostname == hostname)
    }

    /// Quitting the app stops its check-ins, never obid's tunnel (#896).
    @Test @MainActor func quittingTheAppStopsNoTunnel() async throws {
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        defaults.set(true, forKey: "remote.enabled")
        let host = FakeHost()
        let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!) { _ in (Data(), 500) },
                                  secrets: KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)"),
                                  defaults: defaults, host: host)
        remote.stop()
        #expect(host.stops == 0)
    }

    /// With Settings › Runner on a remote runner there's no gateway on this Mac: turning remote
    /// access on says so, before any sign-in.
    @Test @MainActor func remoteAccessAsksForThisMacFirst() async throws {
        let exchange = Exchange([])
        let defaults = try #require(UserDefaults(suiteName: "com.deskree.oby.remote.tests-\(UUID().uuidString)"))
        let host = FakeHost()
        host.thisMac = false
        let remote = RemoteAccess(plane: ControlPlane(base: URL(string: "https://oby-control.test")!, transport: exchange.transport),
                                  secrets: KeychainVault(service: "com.deskree.oby.remote.tests-\(UUID().uuidString)"),
                                  defaults: defaults, host: host,
                                  authenticate: { _ in Issue.record("no sign-in without obid here"); return URL(string: "oby-signin://failed")! })
        await remote.turnOn()
        #expect(!remote.on)
        #expect(remote.problem == RemoteAccess.needsThisMac)
        #expect(exchange.requests.isEmpty && host.handed.isEmpty)
    }

    /// The launch build has no cloudflared: obid's tunnel isn't ready, so turning remote access on
    /// stops there, before any sign-in or control-plane call (remoteAccessAsksForThisMacFirst).
    @Test @MainActor func remoteAccessNeedsAFullBuild() {
        var said: String?
        do { try ObidTunnel().ready() } catch { said = error.localizedDescription }
        #expect((said == RemoteAccess.needsFullBuild) == (ObidTunnel.bundled == nil), Comment(rawValue: said ?? "ready"))
    }

    /// obid's `tunnel` field, as Settings shows it.
    @Test func obidsTunnelStateReads() {
        #expect(ObidTunnel.state(["state": "connected"]) == .connected)
        #expect(ObidTunnel.state(["state": "starting"]) == .starting)
        #expect(ObidTunnel.state(["state": "off"]) == .off)
        #expect(ObidTunnel.state(["state": "failed", "detail": "ERR no edge"]) == .failed("ERR no edge"))
    }

    /// obid as a test sees it: what it was handed and asked to stop.
    @MainActor final class FakeHost: TunnelHost {
        var onState: (RemoteAccess.TunnelState) -> Void = { _ in }
        var handed: [String] = []
        var stops = 0
        var thisMac = true
        func ready() throws { if !thisMac { throw Shell.Failure(message: RemoteAccess.needsThisMac) } }
        func hand(_ token: String) async throws { try ready(); handed.append(token); onState(.starting) }
        func stop() async throws { stops += 1; onState(.off) }
        func refresh() async {}
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
