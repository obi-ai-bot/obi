import Foundation
import LocalAuthentication
import Observation
import OSLog

/// What signs a publish on this Mac: its Touch ID key (Shared/DeviceKey.swift), or a stand-in in tests.
nonisolated protocol PublishingKey: Sendable {
    var isAvailable: Bool { get }
    /// The public half, X9.63, to register with the runner. It doesn't ask for Touch ID.
    func publicKey() throws -> Data
    /// Asks for Touch ID with the action as the reason, then signs it; throws when the user
    /// cancels or Touch ID fails, so nothing is signed.
    func approve(job: String, action: String, device: String) async throws -> Approval
}

/// The Mac's Secure Enclave key, behind Touch ID.
nonisolated struct TouchIDKey: PublishingKey {
    var isAvailable: Bool { DeviceKey.isAvailable }

    func publicKey() throws -> Data { try DeviceKey.publicKey() }

    func approve(job: String, action: String, device: String) async throws -> Approval {
        let reason = Self.reason(action)
        // Touch ID first, so a cancel says so; the key then signs with that same answer, without asking again.
        return try await Task.detached {
            let context = LAContext()
            guard (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) == true else {
                throw RunnerError(message: "Not published: Touch ID didn't approve it.")
            }
            return try DeviceKey.approve(job: job, action: action, device: device, context: context)
        }.value
    }

    /// macOS shows "Oby is trying to <reason>.", so the sentence goes in lowercase, without its
    /// period, as for this Mac's own jobs (Publish.touchID).
    static func reason(_ action: String) -> String {
        action.prefix(1).lowercased() + action.dropFirst().dropLast(action.hasSuffix(".") ? 1 : 0)
    }
}

/// This Mac's publishing key with the runner (docs/runner-api.md, "POST /v1/devices"): a second key
/// to the same door as the iPhone's. It registers on every connection; a new key needs pairing open
/// on the runner, and until then Settings › Runner says the runner's one line, with Try again.
/// With it, a runner's job publishes from here, after Touch ID. Once paired, the gateway's X25519
/// key is pinned here and every device request through the gateway is sealed like the iPhone's.
@Observable
final class MacDevice {
    nonisolated enum State: Equatable, Sendable {
        /// Not asked yet, on this runner.
        case unregistered
        case registered
        /// The runner answered 403: its line says how to open pairing.
        case needsPairing(String)
        /// Anything else that went wrong, said as it came.
        case failed(String)
    }

    private(set) var state = State.unregistered
    @ObservationIgnored let key: any PublishingKey
    @ObservationIgnored private let given: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(key: any PublishingKey = TouchIDKey(), name: String? = nil, defaults: UserDefaults = .standard) {
        self.key = key
        given = name
        self.defaults = defaults
    }

    /// What the runner's log calls this Mac: its name in Sharing settings, asked when it registers.
    var name: String { given ?? Host.current().localizedName ?? "Mac" }

    /// Settings › Runner's word for it.
    var status: String {
        guard key.isAvailable else { return "Needs Touch ID" }
        switch state {
        case .unregistered: return "Not registered yet"
        case .registered: return "Registered, Touch ID"
        case .needsPairing, .failed: return "Not registered"
        }
    }

    /// Why it isn't registered, as the runner said it (a 403's one line), for Settings to show
    /// with Try again; nil otherwise.
    var problem: String? {
        switch state {
        case .needsPairing(let line), .failed(let line): line
        case .unregistered, .registered: nil
        }
    }

    /// The id the runner gave this Mac's key, by the runner's address, as the iPhone keeps it.
    func id(on runner: Runner) -> String? { defaults.string(forKey: Self.idKey(runner)) }

    /// The gateway's pinned X25519 public key for this runner, or nil before pairing.
    func gatewayPublicKey(on runner: Runner) -> Data? {
        defaults.data(forKey: Self.gatewayKey(runner))
    }

    /// Another runner: what the last one said doesn't hold there.
    func reset() { state = .unregistered }

    /// Sealed client for the Mac gateway, matching `Phone.runner`: nil until this Mac has paired
    /// and pinned the gateway key (and can make its X25519 identity).
    func e2eClient(for runner: Runner) -> E2E.Client? {
        guard let device = id(on: runner) ?? defaults.string(forKey: Self.idKey(runner)),
              let gateway = gatewayPublicKey(on: runner) ?? defaults.data(forKey: Self.gatewayKey(runner)),
              gateway.count == 32 else { return nil }
        let host = runner.base.host() ?? runner.base.absoluteString
        return try? DeviceKey.e2eClient(device: device, gatewayPublicKey: gateway,
                                         counterKey: "oby.e2e.counter.\(device).\(host)")
    }

    /// A runner that seals every call when this Mac has pinned the gateway key; otherwise `runner`.
    /// When the key is pinned but the client cannot be built, plaintext is refused.
    func sealed(_ runner: Runner) -> Runner {
        if let e2e = e2eClient(for: runner) {
            return Runner(base: runner.base, token: runner.token, e2e: e2e)
        }
        if gatewayPublicKey(on: runner) != nil {
            return Runner(base: runner.base, token: runner.token, e2eRequired: true)
        }
        return runner
    }

    /// Completes gateway pairing for this Mac: pins the QR/openPairing gateway key, redeems the
    /// one-time secret on the gateway (cleartext bootstrap only), and stores the device id. Touch ID
    /// signs the E2E possession proof once here, not on every later register.
    @discardableResult
    func pair(with gateway: Runner, secret: String, gatewayPublicKey: Data) async throws -> String {
        guard key.isAvailable else { throw RunnerError(message: "Publishing from this Mac needs Touch ID.") }
        guard gatewayPublicKey.count == 32 else { throw RunnerError(message: "The Mac's gateway key isn't X25519.") }
        defaults.set(gatewayPublicKey, forKey: Self.gatewayKey(gateway))
        do {
            let answer = try await gateway.pair(name: name, publicKey: try key.publicKey(), pairingSecret: secret,
                                                gatewayPublicKey: gatewayPublicKey)
            guard answer.publicKey == gatewayPublicKey else {
                throw RunnerError(message: "The Mac's gateway key changed. Open pairing again.")
            }
            defaults.set(answer.id, forKey: Self.idKey(gateway))
            // Same id for the owner API host when this Mac pairs with its own gateway.
            if gateway.base == LocalRunner.gatewayURL {
                defaults.set(answer.id, forKey: Self.idKey(Runner(base: LocalRunner.url)))
                defaults.set(gatewayPublicKey, forKey: Self.gatewayKey(Runner(base: LocalRunner.url)))
            }
            state = .registered
            return answer.id
        } catch let error as RunnerError where error.status == 403 {
            state = .needsPairing(error.message)
            throw error
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Registers the key and returns its id. On every connection it registers `again`: the runner
    /// keeps a known key's id, and a reinstalled runner learns it anew. When the gateway key is
    /// pinned, the request is sealed like the iPhone's. A 403 (pairing closed) is kept for
    /// Settings to show, and thrown too.
    @discardableResult
    func register(with runner: Runner, again: Bool = true) async throws -> String {
        if !again, let id = id(on: runner) { return id }
        guard key.isAvailable else { throw RunnerError(message: "Publishing from this Mac needs Touch ID.") }
        do {
            let connection = sealed(runner)
            let id = try await connection.register(name: name, publicKey: try key.publicKey())
            defaults.set(id, forKey: Self.idKey(runner))
            if let gateway = gatewayPublicKey(on: runner) {
                defaults.set(gateway, forKey: Self.gatewayKey(runner))
            }
            state = .registered
            return id
        } catch let error as RunnerError where error.status == 403 {
            state = .needsPairing(error.message)
            throw error
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Publishes a runner's job with exactly `action`, the runner's own sentence the user saw:
    /// Touch ID signs it, then the runner checks the signature and pushes. A cancelled Touch ID
    /// throws before anything is sent.
    func publish(_ job: String, action: String, with runner: Runner) async throws -> URL {
        let device = try await register(with: runner, again: false)
        let approval = try await key.approve(job: job, action: action, device: device)
        return try await sealed(runner).publish(job, approval: approval)
    }

    private static func idKey(_ runner: Runner) -> String { "device.\(runner.base.host() ?? runner.base.absoluteString)" }
    private static func gatewayKey(_ runner: Runner) -> String { "device.gateway.\(runner.base.host() ?? runner.base.absoluteString)" }
}
