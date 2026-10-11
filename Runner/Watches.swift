import Crypto
import Foundation
import HTTPTypes
@testable import ObyEngine

/// The Apple Watches that may use the Watch API (Runner/WatchAPI.swift), each by its Secure
/// Enclave key, kept in `watches.json`. A Watch is paired by the iPhone, which the runner trusts
/// over the tailnet and which signs the pairing with its Face ID key; the iPhone also hands over
/// the Cloudflare Access service token it gives the Watch, and the runner keeps that in its vault,
/// where no agent sees it and the secret scan learns it.
@MainActor
final class Watches {
    struct Watch: Codable, Equatable {
        var id: String
        var name: String
        /// P-256, X9.63 (65 bytes, uncompressed), base64.
        var publicKey: String
        var registered: Date
    }

    /// What a request's signature is checked against (docs/runner-api.md, "The Watch API").
    struct Signed: Sendable {
        var watch: String
        var method: String
        /// The path and query, as sent.
        var target: String
        var time: String
        var nonce: String
        var signature: String
        var body: Data
    }

    /// The vault's entries for the Access service token's two halves.
    enum VaultEntry {
        static let idEntry = "watch-access-client-id"
        static let tokenEntry = "watch-access-client-token"
    }

    /// How old a request may be.
    static let window: TimeInterval = 120
    /// How far ahead of the runner's clock a request's time may be: a little, for clocks that differ.
    static let ahead: TimeInterval = 5

    private let file: URL
    private let vault: Vault
    private(set) var watches: [Watch] = []
    /// Each nonce used while its request's time is still within the window, by watch, with that
    /// time. Kept in `watch-nonces.json` beside `watches.json` (0600), so a restart doesn't let a
    /// request through again.
    private var nonces: [String: Date] = [:]
    let noncesFile: URL

    init(file: URL, vault: Vault = .shared) {
        self.file = file
        self.vault = vault
        noncesFile = file.deletingLastPathComponent().appending(path: "watch-nonces.json")
        if let data = try? Data(contentsOf: noncesFile) {
            do {
                nonces = try Self.decoder.decode([String: Date].self, from: data)
            } catch {
                // Unreadable, it can't say which were used: every Watch request is refused until it's fixed.
                Logger.runner.error("can't read \(self.noncesFile.path, privacy: .public): no Watch request gets in until it's removed")
                nonces = [Self.unreadable: .distantFuture]
            }
        }
        if let data = try? Data(contentsOf: file) {
            do {
                watches = try Self.decoder.decode([Watch].self, from: data)
            } catch {
                Logger.runner.error("can't read \(file.path, privacy: .public): no Watch can reach the runner until one is paired again")
            }
        }
        for watch in watches { Logger.runner.notice("watch \(watch.id, privacy: .public): \(watch.name, privacy: .public)") }
    }

    /// Pairs a Watch and returns its id; a key it knows keeps its id. The service token replaces
    /// the one in the vault, so the token the iPhone holds now is the one the runner keeps.
    func pair(name: String, publicKey: String, clientID: String, clientSecret: String, now: Date = .now) throws -> String {
        guard Self.key(publicKey) != nil else {
            throw APIError(.unprocessableContent, "publicKey isn't a P-256 public key (X9.63, base64).")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(name.count) else { throw APIError(.unprocessableContent, "name is the Watch's name, up to 100 characters.") }
        for value in [clientID, clientSecret] where value.wholeMatch(of: /[A-Za-z0-9._-]{8,256}/) == nil {
            throw APIError(.unprocessableContent, "accessClientId and accessClientSecret are the Access service token's.")
        }
        do {
            try vault.add(clientID, as: VaultEntry.idEntry)
            try vault.add(clientSecret, as: VaultEntry.tokenEntry)
        } catch {
            throw APIError(.serviceUnavailable, "The runner couldn't keep the service token in its vault: \(error.localizedDescription)")
        }
        if let known = watches.firstIndex(where: { $0.publicKey == publicKey }) {
            watches[known].name = name
            try save()
            return watches[known].id
        }
        let watch = Watch(id: UUID().uuidString.lowercased(), name: name, publicKey: publicKey, registered: now)
        watches.append(watch)
        try save()
        Logger.runner.notice("paired watch \(watch.id, privacy: .public): \(watch.name, privacy: .public)")
        return watch.id
    }

    /// Forgets a Watch: its requests fail from now on. With the last one gone, the service
    /// token leaves the vault too.
    func remove(_ id: String) throws {
        guard let index = watches.firstIndex(where: { $0.id == id }) else { throw APIError(.notFound, "There's no paired Watch \(id).") }
        watches.remove(at: index)
        try save()
        nonces = nonces.filter { !$0.key.hasPrefix("\(id) ") }
        if watches.isEmpty {
            try? vault.remove(VaultEntry.idEntry)
            try? vault.remove(VaultEntry.tokenEntry)
        }
        Logger.runner.notice("removed watch \(id, privacy: .public)")
    }

    /// Lets a request through once: from a paired Watch, signed by its key over exactly this
    /// method, path, body, time and nonce, at most two minutes old and a few seconds ahead, with a
    /// nonce not used before (before a restart too). Returns the Watch's id.
    func check(_ request: Signed, now: Date = .now) throws -> String {
        guard let watch = watches.first(where: { $0.id == request.watch }), let key = Self.key(watch.publicKey) else {
            throw APIError(.unauthorized, "That Watch isn't paired with this runner.")
        }
        guard request.nonce.wholeMatch(of: /[A-Za-z0-9_-]{16,64}/) != nil else {
            throw APIError(.unauthorized, "Oby-Nonce is 16 to 64 letters, digits, - or _.")
        }
        let message = Self.message(method: request.method, target: request.target, time: request.time, nonce: request.nonce, body: request.body)
        guard let der = Data(base64Encoded: request.signature), let signature = try? P256.Signing.ECDSASignature(derRepresentation: der),
              key.isValidSignature(signature, for: message) else {
            throw APIError(.unauthorized, "The signature doesn't match the Watch's key.")
        }
        guard let seconds = TimeInterval(request.time), request.time.wholeMatch(of: /[0-9]{1,12}/) != nil else {
            throw APIError(.unauthorized, "Oby-Time is the request's time, in seconds since 1970.")
        }
        let time = Date(timeIntervalSince1970: seconds)
        guard now.timeIntervalSince(time) <= Self.window, time.timeIntervalSince(now) <= Self.ahead else {
            throw APIError(.unauthorized, "The request's time is too far from the runner's. Check the Watch's clock.")
        }
        guard nonces[Self.unreadable] == nil else {
            throw APIError(.serviceUnavailable, "The runner can't read which Watch requests were used: \(noncesFile.path).")
        }
        // A nonce goes once its request is too old to get in anyway.
        var kept = nonces.filter { now.timeIntervalSince($0.value) <= Self.window }
        let used = "\(watch.id) \(request.nonce)"
        guard kept[used] == nil else { throw APIError(.unauthorized, "That request was already used.") }
        kept[used] = time
        // Saved before it's let through: a nonce the runner couldn't keep could work again after a restart.
        try saveNonces(kept)
        nonces = kept
        return watch.id
    }

    /// Stands in for every nonce while `watch-nonces.json` can't be read.
    private static let unreadable = "unreadable"

    /// `watch-nonces.json`, created 0600 before a byte is written, then renamed over the old one.
    private func saveNonces(_ nonces: [String: Date]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(nonces)
        let temporary = noncesFile.deletingLastPathComponent().appending(path: ".watch-nonces-\(UUID().uuidString).json")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw APIError(.serviceUnavailable, "The runner couldn't record the Watch's request (errno \(errno)).") }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard fchmod(fd, 0o600) == 0 else { throw APIError(.serviceUnavailable, "The runner couldn't record the Watch's request privately.") }
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temporary.path, noncesFile.path) == 0 else {
                throw APIError(.serviceUnavailable, "The runner couldn't record the Watch's request (errno \(errno)).")
            }
        } catch {
            unlink(temporary.path)
            throw error as? APIError ?? APIError(.serviceUnavailable, "The runner couldn't record the Watch's request: \(error.localizedDescription)")
        }
    }

    /// What the Watch signs: `"oby-watch\n<method>\n<path?query>\n<time>\n<nonce>\n<hex SHA-256 of the body>"`.
    nonisolated static func message(method: String, target: String, time: String, nonce: String, body: Data) -> Data {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Data("oby-watch\n\(method)\n\(target)\n\(time)\n\(nonce)\n\(hash)".utf8)
    }

    private static func key(_ base64: String) -> P256.Signing.PublicKey? {
        Data(base64Encoded: base64).flatMap { try? P256.Signing.PublicKey(x963Representation: $0) }
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(watches).write(to: file, options: .atomic)
        } catch {
            throw APIError(.internalServerError, "The runner couldn't save its paired Watches: \(error.localizedDescription)")
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
