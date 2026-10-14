import Foundation
import Observation
import Security
import WatchConnectivity

/// Pairs this phone's Apple Watch with the runner, so the watch reaches it through the Cloudflare
/// Tunnel when this phone is out of reach (docs/runner-api.md, `POST /v1/watches`). The watch
/// makes its key in its Secure Enclave and hands over the public half; Face ID here approves it;
/// the runner keeps the key and the Access service token (in its vault); and the watch gets its
/// id, the Watch API's address and the token. The phone keeps the token too, in its keychain,
/// to pair the next watch.
@Observable
final class WatchPairing {
    /// The Cloudflare Access service token, as the Zero Trust dashboard shows it.
    var clientID = ""
    var clientSecret = ""
    private(set) var watches: [PairedWatch] = []
    private(set) var busy = false

    init() {
        if let saved = Self.read() {
            clientID = saved.clientID
            clientSecret = saved.clientSecret
        }
    }

    var canPair: Bool { !busy && !clientID.isEmpty && !clientSecret.isEmpty }

    func load(_ phone: Phone) async throws {
        watches = try await phone.runner.watches()
    }

    func pair(_ phone: Phone) async throws {
        busy = true
        defer { busy = false }
        guard DeviceKey.isAvailable else { throw RunnerError(message: "Pairing needs Face ID on your iPhone.") }
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = try await ask([WatchWire.kind: WatchWire.Kind.pairKey.rawValue])
        guard let publicKey = key[WatchWire.publicKey] as? Data else { throw RunnerError(message: "Your watch sent no key.") }
        let e2ePublicKey = key[WatchWire.e2ePublicKey] as? Data
        let name = key[WatchWire.name] as? String ?? "Apple Watch"
        let device = try await phone.registerDevice()
        let approval = try await Task.detached { try DeviceKey.approvePairing(publicKey: publicKey.base64EncodedString(), device: device) }.value
        let paired = try await phone.runner.pairWatch(name: name, publicKey: publicKey, clientID: clientID, clientSecret: clientSecret,
                                                      approval: approval, e2ePublicKey: e2ePublicKey)
        Self.save(clientID: clientID, clientSecret: clientSecret)
        var message: [String: Any] = [WatchWire.kind: WatchWire.Kind.paired.rawValue, WatchWire.watch: paired.id,
                                      WatchWire.url: paired.url.absoluteString, WatchWire.clientID: clientID,
                                      WatchWire.clientSecret: clientSecret]
        // Pin the same gateway key the iPhone already trusts; without it the watch stays on cleartext.
        if let gateway = phone.link?.publicKey, gateway.count == 32 {
            message[WatchWire.gatewayPublicKey] = gateway
        }
        _ = try await ask(message)
        watches = try await phone.runner.watches()
    }

    /// The runner forgets the watch; a watch in reach forgets its pairing too.
    func remove(_ id: String, _ phone: Phone) async throws {
        try await phone.runner.removeWatch(id)
        watches.removeAll { $0.id == id }
        _ = try? await ask([WatchWire.kind: WatchWire.Kind.unpaired.rawValue, WatchWire.watch: id])
    }

    /// One message to the watch app, answered in the reply. Pairing is done with the watch at hand.
    private func ask(_ message: [String: Any]) async throws -> [String: Any] {
        guard WCSession.isSupported() else { throw RunnerError(message: "This iPhone has no Apple Watch.") }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            throw RunnerError(message: "Install Oby on your Apple Watch first.")
        }
        guard session.isReachable else { throw RunnerError(message: "Open Oby on your watch, then try again.") }
        let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(message) { continuation.resume(returning: $0) } errorHandler: { continuation.resume(throwing: $0) }
        }
        if let error = reply[WatchWire.error] as? String { throw RunnerError(message: error) }
        return reply
    }

    // MARK: The token on this phone

    private static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "com.deskree.oby",
                                              kSecAttrAccount as String: "watch-access"]

    private static func read() -> (clientID: String, clientSecret: String)? {
        var query = item
        query[kSecReturnData as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
              let saved = try? JSONDecoder().decode([String: String].self, from: data),
              let id = saved["clientId"], let secret = saved["clientSecret"] else { return nil }
        return (id, secret)
    }

    private static func save(clientID: String, clientSecret: String) {
        guard let data = try? JSONEncoder().encode(["clientId": clientID, "clientSecret": clientSecret]) else { return }
        SecItemDelete(item as CFDictionary)
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
