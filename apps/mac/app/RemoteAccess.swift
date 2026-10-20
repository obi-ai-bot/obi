import CryptoKit
import Foundation
import Observation
import OSLog

/// Settings › Remote access (#285): reach this Mac from anywhere. Oby's control plane on
/// Cloudflare (Engine/ControlPlane.swift) gives each installation its own Cloudflare Tunnel and
/// an opaque hostname, and this Mac runs the bundled `cloudflared` outbound as a child of Oby,
/// the login item (TunnelRunner). The iPhone talks HTTPS to the hostname, and the tunnel routes
/// only to the gateway (#284) on 127.0.0.1:8810.
///
/// There's no account and no sign-in: this Mac makes a P-256 key (in the Secure Enclave when it
/// has one) and signs every call to the control plane with it. What stays on this Mac: the key
/// and the tunnel's run token, in the keychain under a service of their own (not the user's
/// vault, which Settings › Vault lists); the hostname in the defaults.
@Observable
final class RemoteAccess {
    /// How the tunnel is, as `cloudflared` says.
    nonisolated enum TunnelState: Equatable, Sendable {
        case off
        case starting
        case connected
        /// Why it isn't up; it tries again by itself.
        case failed(String)
    }

    /// The keychain service for this Mac's remote-access secrets, apart from the user's vault.
    static let service = "com.deskree.oby.remote"
    static let keyKey = "installation-key"
    static let tokenKey = "tunnel-token"
    /// How often a Mac with a hostname tells the control plane it's still here: one idle for 30
    /// days loses its installation (cloud/control-plane, `sweep`).
    static let checkInEvery = Duration.seconds(24 * 60 * 60)
    /// The email sign-in's keychain items and defaults (before 2026-10-20), removed at launch.
    static let oldSecrets = ["control-plane-session", "installation-credential"]
    static let oldDefaults = ["remote.email", "remote.installation", "remote.clientID"]

    /// Remote access is on: the tunnel runs, or tries to.
    private(set) var on: Bool
    /// This Mac's hostname, once it has one: oby-<opaque>.<the control plane's device domain>.
    private(set) var hostname: String?
    private(set) var tunnel = TunnelState.off
    private(set) var busy = false
    /// What went wrong last, for Settings to show; nil once something works.
    private(set) var problem: String?

    @ObservationIgnored private let plane: ControlPlane
    @ObservationIgnored private let secrets: any VaultStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let runner: TunnelRunner
    @ObservationIgnored private var checkIns: Task<Void, Never>?
    /// A new Mac's proof of work, in leading zero bits: at least the control plane's
    /// REGISTRATION_WORK_BITS (cloud/control-plane/wrangler.jsonc). Tests pass fewer.
    @ObservationIgnored private let workBits: Int

    init(plane: ControlPlane = ControlPlane(), secrets: any VaultStore = KeychainVault(service: RemoteAccess.service),
         defaults: UserDefaults = .standard, runner: TunnelRunner = TunnelRunner(), workBits: Int = 22) {
        self.plane = plane
        self.workBits = workBits
        self.secrets = secrets
        self.defaults = defaults
        self.runner = runner
        on = defaults.bool(forKey: "remote.enabled")
        hostname = defaults.string(forKey: "remote.hostname")
        runner.onState = { [weak self] state in self?.tunnel = state }
    }

    /// Settings' one line about the tunnel.
    var status: String {
        guard on else { return "Off" }
        switch tunnel {
        case .off: return "Starting…"
        case .starting: return "Connecting…"
        case .connected: return "Connected"
        case .failed(let why): return why
        }
    }

    // MARK: At launch and quit

    /// Remote access was on: the tunnel runs again with the keychain's token. With a hostname, on
    /// or off, this Mac checks in now and once a day, so its installation isn't removed as idle.
    func start() {
        // ponytail: once the email sign-in's leftovers are gone from every Mac, drop this.
        for name in Self.oldSecrets { try? secrets.remove(name) }
        for key in Self.oldDefaults { defaults.removeObject(forKey: key) }
        if on {
            if let token = (try? secrets.value(Self.tokenKey)) ?? nil {
                runner.start(token: token)
            } else {
                problem = "The tunnel's token isn't in the keychain any more: turn remote access on again."
                on = false
                defaults.set(false, forKey: "remote.enabled")
            }
        }
        checkInDaily()
    }

    private func checkInDaily() {
        guard hostname != nil, checkIns == nil else { return }
        checkIns = Task { [weak self] in
            while !Task.isCancelled {
                guard let remote = self else { return }
                await remote.checkIn()
                try? await Task.sleep(for: Self.checkInEvery)
            }
        }
    }

    /// Oby is quitting: the tunnel ends with it.
    func stop() {
        checkIns?.cancel()
        checkIns = nil
        runner.stop()
    }

    /// A signed call keeps the installation. When the control plane no longer knows this Mac (idle
    /// for 30 days, or forgotten), or took its tunnel back (not connected for days), the hostname
    /// here goes; on, it's set up again at once, with a new hostname.
    func checkIn() async {
        do {
            let mine = try await plane.installation(try signer())
            if mine.endpoint?.hostname != hostname { await lost() }
        } catch let failure as ControlPlane.Failure where failure.status == 410 {
            await lost()
        } catch {
            // Offline, or the control plane is down: the next check-in tries again.
            Logger.remote.error("remote access check-in: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func lost() async {
        hostname = nil
        defaults.removeObject(forKey: "remote.hostname")
        guard on else { return }
        // The old tunnel is gone at Cloudflare: its cloudflared ends, and the new one runs.
        runner.stop()
        await turnOn()
    }

    // MARK: On and off

    /// Registers this Mac by its key, gets its hostname and tunnel token, and runs the tunnel.
    /// Again later (after a reinstall, or the keychain lost the token) it's the same installation
    /// and hostname, as long as the key is the same.
    func turnOn() async {
        await attempt {
            let signer = try signer()
            do {
                try await register(signer, bits: workBits)
            } catch let failure as ControlPlane.Failure where failure.status == 403 {
                // Busy, or nearly full: the control plane asks for more work. Once, and not past
                // Self.mostWorkBits, so a Mac isn't kept hashing for minutes.
                guard let bits = failure.workBits, bits > workBits, bits <= Self.mostWorkBits else { throw failure }
                try await register(signer, bits: bits)
            }
            let endpoint = try await plane.createEndpoint(signer)
            let token = try await plane.tunnelToken(signer)
            try secrets.save(token.token, as: Self.tokenKey)
            hostname = endpoint.hostname
            defaults.set(endpoint.hostname, forKey: "remote.hostname")
            defaults.set(true, forKey: "remote.enabled")
            on = true
            runner.start(token: token.token)
            Logger.remote.notice("remote access on: \(endpoint.hostname, privacy: .public)")
        }
        checkInDaily()
    }

    /// The tunnel stops; the hostname and the installation stay for next time.
    func turnOff() {
        runner.stop()
        defaults.set(false, forKey: "remote.enabled")
        on = false
        Logger.remote.notice("remote access off")
    }

    /// Removes this Mac from the control plane (its tunnel and hostname go), signed by its key,
    /// and forgets everything here, the key too. A hostname it had never answers again.
    func forget() async {
        runner.stop()
        await attempt {
            if let saved = try secrets.value(Self.keyKey) {
                do {
                    try await plane.forget(try MacKey.signer(saved))
                } catch let failure as ControlPlane.Failure where failure.status == 410 {
                    // Removed already (idle, or forgotten before): nothing to remove.
                }
            }
            for key in [Self.keyKey, Self.tokenKey] { try secrets.remove(key) }
            for key in ["remote.hostname", "remote.enabled"] { defaults.removeObject(forKey: key) }
            checkIns?.cancel()
            checkIns = nil
            hostname = nil
            on = false
        }
    }

    /// The most work a Mac does when asked for more: the control plane's MAX_WORK_BITS
    /// (cloud/control-plane/src/app.ts), its base and every extra together. 30 bits is a few
    /// minutes, asked for only while the control plane is nearly full and busy.
    static let mostWorkBits = 30

    /// Registers this Mac, with a proof of work worked out off the main thread (a second or two at
    /// 22 bits).
    private func register(_ signer: ControlPlane.Signer, bits: Int) async throws {
        let at = Int(plane.now().timeIntervalSince1970)
        let key = ControlPlane.base64url(signer.publicKey)
        let proof = await Task.detached(priority: .userInitiated) { MacKey.work(key: key, at: at, bits: bits) }.value
        _ = try await plane.register(signer, name: Host.current().localizedName ?? "Mac", proofAt: at, proof: proof)
    }

    /// This Mac's key, made the first time it's needed.
    private func signer() throws -> ControlPlane.Signer {
        if let saved = try secrets.value(Self.keyKey) { return try MacKey.signer(saved) }
        let saved = try MacKey.make()
        try secrets.save(saved, as: Self.keyKey)
        return try MacKey.signer(saved)
    }

    /// Runs `action` with `busy` on, and keeps what went wrong for Settings.
    private func attempt(_ action: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await action()
            problem = nil
        } catch {
            problem = error.localizedDescription
            Logger.remote.error("remote access: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// This Mac's P-256 key for the control plane, as the keychain keeps it: "se:" and the Secure
/// Enclave's wrapped key (only this Mac's Secure Enclave can use it, and the private key never
/// leaves it), or "sw:" and a software key's raw bytes on a Mac with no Secure Enclave.
nonisolated enum MacKey {
    /// A new key: the Secure Enclave's on a Mac that has one, and if it can't make one, that's an
    /// error to show, never a quiet step down to a software key.
    static func make() throws -> String {
        if SecureEnclave.isAvailable {
            return "se:" + (try SecureEnclave.P256.Signing.PrivateKey()).dataRepresentation.base64EncodedString()
        }
        return "sw:" + P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()
    }

    /// A new Mac's proof of work (cloud/control-plane/src/app.ts, `checkWork`): the first decimal
    /// answer such that SHA-256 of "oby-register-v1", the key, `at` and the answer, a line each,
    /// starts with `bits` zero bits.
    static func work(key: String, at: Int, bits: Int) -> String {
        var start = SHA256()
        start.update(data: Data("oby-register-v1\n\(key)\n\(at)\n".utf8))
        var answer = 0
        while true {
            var hash = start
            hash.update(data: Data(String(answer).utf8))
            if zeroBits(Array(hash.finalize())) >= bits { return String(answer) }
            answer += 1
        }
    }

    static func zeroBits(_ bytes: [UInt8]) -> Int {
        var bits = 0
        for byte in bytes {
            if byte != 0 { return bits + byte.leadingZeroBitCount }
            bits += 8
        }
        return bits
    }

    static func signer(_ saved: String) throws -> ControlPlane.Signer {
        guard let data = Data(base64Encoded: String(saved.dropFirst(3))) else { throw Shell.Failure(message: "This Mac's remote-access key couldn't be read.") }
        if saved.hasPrefix("se:") {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
            return ControlPlane.Signer(publicKey: key.publicKey.x963Representation) { message in
                try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data).signature(for: message).rawRepresentation
            }
        }
        let key = try P256.Signing.PrivateKey(rawRepresentation: data)
        return ControlPlane.Signer(publicKey: key.publicKey.x963Representation) { message in
            try P256.Signing.PrivateKey(rawRepresentation: data).signature(for: message).rawRepresentation
        }
    }
}

/// `cloudflared tunnel run`, bundled with Oby (apps/mac/app/Tools/bundle-cloudflared.sh), as a child of
/// the app: it starts when remote access is on and again after it exits, waiting a little longer
/// each time. The token goes in its environment (`TUNNEL_TOKEN`), never in its arguments, so the
/// process list doesn't show it.
final class TunnelRunner {
    /// Where the bundled binary is: Contents/MacOS/cloudflared, signed with the app.
    nonisolated static var bundled: URL? { Bundle.main.url(forAuxiliaryExecutable: "cloudflared") }

    var onState: (RemoteAccess.TunnelState) -> Void = { _ in }
    private let binary: URL?
    /// Starts the process: `Process.run`, or a test's stand-in that only looks at it.
    private let launch: (Process) throws -> Void
    private var process: Process?
    private var token: String?
    private var stopped = true
    private var failures = 0

    init(binary: URL? = TunnelRunner.bundled, launch: @escaping (Process) throws -> Void = { try $0.run() }) {
        self.binary = binary
        self.launch = launch
    }

    var isRunning: Bool { process != nil }

    func start(token: String) {
        self.token = token
        stopped = false
        failures = 0
        if process == nil { run() } else { onState(.starting) }
    }

    func stop() {
        stopped = true
        token = nil
        if let process, process.isRunning {
            // Its exit clears `process` and says off.
            process.terminate()
        } else {
            process = nil
            onState(.off)
        }
    }

    private func run() {
        guard let token else { return }
        guard let binary else {
            onState(.failed("cloudflared isn't bundled with this build of Oby."))
            return
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["tunnel", "--no-autoupdate", "run"]
        var environment = ProcessInfo.processInfo.environment
        environment["TUNNEL_TOKEN"] = token
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let log = Pipe()
        process.standardError = log
        log.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.heard(text) }
        }
        process.terminationHandler = { [weak self] process in
            log.fileHandleForReading.readabilityHandler = nil
            let status = process.terminationStatus
            Task { @MainActor in self?.exited(status) }
        }
        do {
            try launch(process)
            self.process = process
            onState(.starting)
        } catch {
            onState(.failed("cloudflared couldn't start: \(error.localizedDescription)"))
        }
    }

    /// cloudflared's log: one line per edge connection it registers.
    private func heard(_ text: String) {
        if text.contains("Registered tunnel connection") {
            failures = 0
            onState(.connected)
        }
        for line in text.split(separator: "\n") where line.contains("ERR") {
            Logger.remote.error("cloudflared: \(String(line), privacy: .public)")
        }
    }

    private func exited(_ status: Int32) {
        process = nil
        guard !stopped, token != nil else {
            onState(.off)
            return
        }
        failures += 1
        let wait = min(60, 2 << min(failures, 5))
        onState(.failed("The tunnel dropped (cloudflared exited with \(status)); trying again in \(wait) s."))
        Task {
            try? await Task.sleep(for: .seconds(wait))
            guard !stopped, process == nil else { return }
            run()
        }
    }
}

extension Logger {
    nonisolated static let remote = Logger(subsystem: "com.deskree.oby", category: "remote")
}
