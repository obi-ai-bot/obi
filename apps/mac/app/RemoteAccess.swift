import Foundation
import Observation
import OSLog

/// Settings › Remote access (#285): reach this Mac from anywhere. Oby's control plane on
/// Cloudflare (Engine/ControlPlane.swift) gives each installation its own Cloudflare Tunnel and
/// an opaque hostname, and this Mac runs the bundled `cloudflared` outbound as a child of Oby,
/// the login item (TunnelRunner). The iPhone talks HTTPS to the hostname, and the tunnel routes
/// only to the gateway (#284) on 127.0.0.1:8810.
///
/// What stays on this Mac: the session token, the installation's credential and the tunnel's
/// run token, in the keychain under a service of their own (not the user's vault, which
/// Settings › Vault lists); the email, hostname and installation id in the defaults.
@Observable
final class RemoteAccess {
    nonisolated enum Step: Equatable, Sendable {
        /// Not signed in to the control plane.
        case signedOut
        /// A code went to this email; waiting for it.
        case codeSent(String)
        /// Signed in, and remote access is off.
        case signedIn
        /// Remote access is on: the tunnel runs, or tries to.
        case on
    }

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
    static let sessionKey = "control-plane-session"
    static let credentialKey = "installation-credential"
    static let tokenKey = "tunnel-token"

    private(set) var step = Step.signedOut
    /// Who's signed in, once someone is.
    private(set) var email: String?
    /// This Mac's hostname, once it has one: oby-<opaque>.tetrix.pro.
    private(set) var hostname: String?
    private(set) var tunnel = TunnelState.off
    private(set) var busy = false
    /// What went wrong last, for Settings to show; nil once something works.
    private(set) var problem: String?

    @ObservationIgnored private let plane: ControlPlane
    @ObservationIgnored private let secrets: any VaultStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let runner: TunnelRunner

    init(plane: ControlPlane = ControlPlane(), secrets: any VaultStore = KeychainVault(service: RemoteAccess.service),
         defaults: UserDefaults = .standard, runner: TunnelRunner = TunnelRunner()) {
        self.plane = plane
        self.secrets = secrets
        self.defaults = defaults
        self.runner = runner
        email = defaults.string(forKey: "remote.email")
        hostname = defaults.string(forKey: "remote.hostname")
        if email != nil { step = defaults.bool(forKey: "remote.enabled") ? .on : .signedIn }
        runner.onState = { [weak self] state in self?.tunnel = state }
    }

    /// What this installation calls itself to the control plane, made once and kept.
    var clientID: String {
        if let id = defaults.string(forKey: "remote.clientID") { return id }
        let id = "mac-" + UUID().uuidString.lowercased()
        defaults.set(id, forKey: "remote.clientID")
        return id
    }

    /// Settings' one line about the tunnel.
    var status: String {
        switch step {
        case .signedOut, .codeSent: return "Off"
        case .signedIn: return "Off"
        case .on:
            switch tunnel {
            case .off: return "Starting…"
            case .starting: return "Connecting…"
            case .connected: return "Connected"
            case .failed(let why): return why
            }
        }
    }

    // MARK: At launch and quit

    /// Remote access was on: the tunnel runs again with the keychain's token.
    func start() {
        guard defaults.bool(forKey: "remote.enabled") else { return }
        guard let token = (try? secrets.value(Self.tokenKey)) ?? nil else {
            problem = "The tunnel's token isn't in the keychain any more: turn remote access on again."
            defaults.set(false, forKey: "remote.enabled")
            step = email == nil ? .signedOut : .signedIn
            return
        }
        step = .on
        runner.start(token: token)
    }

    /// Oby is quitting: the tunnel ends with it.
    func stop() {
        runner.stop()
    }

    // MARK: Sign-in

    func requestCode(_ email: String) async {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        await attempt {
            try await plane.requestCode(email: email)
            step = .codeSent(email)
        }
    }

    /// Back to the email field.
    func useAnotherEmail() {
        if case .codeSent = step { step = .signedOut }
    }

    func verify(_ code: String) async {
        guard case .codeSent(let email) = step else { return }
        await attempt {
            let session = try await plane.verify(email: email, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            try secrets.save(session.token, as: Self.sessionKey)
            self.email = session.user.email
            defaults.set(session.user.email, forKey: "remote.email")
            step = .signedIn
        }
    }

    // MARK: On and off

    /// Registers this Mac, gets its hostname and tunnel token, and runs the tunnel. Again later
    /// (after a reinstall, or the keychain lost the token) it's the same installation and
    /// hostname, with a fresh credential.
    func turnOn() async {
        await attempt {
            guard let session = try secrets.value(Self.sessionKey) else {
                step = .signedOut
                throw Shell.Failure(message: "Sign in first.")
            }
            let registration: ControlPlane.Registration
            do {
                registration = try await plane.register(session: session, clientID: clientID, name: Host.current().localizedName ?? "Mac")
            } catch let failure as ControlPlane.Failure where failure.status == 401 {
                // The session ended (90 days, or the installation was removed from another device).
                try? secrets.remove(Self.sessionKey)
                step = .signedOut
                throw failure
            }
            try secrets.save(registration.credential, as: Self.credentialKey)
            defaults.set(registration.installation.id, forKey: "remote.installation")
            let endpoint = try await plane.createEndpoint(credential: registration.credential)
            let token = try await plane.tunnelToken(credential: registration.credential)
            try secrets.save(token.token, as: Self.tokenKey)
            hostname = endpoint.hostname
            defaults.set(endpoint.hostname, forKey: "remote.hostname")
            defaults.set(true, forKey: "remote.enabled")
            step = .on
            runner.start(token: token.token)
            Logger.remote.notice("remote access on: \(endpoint.hostname, privacy: .public)")
        }
    }

    /// The tunnel stops; the hostname and the installation stay for next time.
    func turnOff() {
        runner.stop()
        defaults.set(false, forKey: "remote.enabled")
        if case .on = step { step = .signedIn }
        Logger.remote.notice("remote access off")
    }

    /// Removes this Mac from the control plane (its tunnel and hostname go), signs out, and
    /// forgets everything here. A hostname it had never answers again.
    func forget() async {
        runner.stop()
        await attempt {
            let session = try secrets.value(Self.sessionKey)
            if let session, let installation = defaults.string(forKey: "remote.installation") {
                do {
                    try await plane.remove(installation, session: session)
                } catch let failure as ControlPlane.Failure where failure.status == 401 || failure.status == 404 {
                    // Removed from another device already, or the session is over: nothing to remove.
                }
            } else if let credential = try secrets.value(Self.credentialKey) {
                try? await plane.removeEndpoint(credential: credential)
            }
            for key in [Self.sessionKey, Self.credentialKey, Self.tokenKey] { try secrets.remove(key) }
            for key in ["remote.email", "remote.hostname", "remote.installation", "remote.enabled"] { defaults.removeObject(forKey: key) }
            email = nil
            hostname = nil
            step = .signedOut
        }
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
