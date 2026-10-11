import Foundation
import Synchronization
#if canImport(Security)
import Security
#endif

/// Secrets the user adds for connections they make (an API token for a service): Oby uses them in
/// its own calls and never shows them. On the Mac they're in the keychain; on the runner, in a file
/// only the runner's user may read, inside `OBY_HOME`, which every agent's bubblewrap hides.
/// No agent sees a value: not in a prompt, an environment variable, a file, an argument or a log.
/// The secret scan learns every value, plain and encoded, so nothing outgoing carries one.
// ponytail: slice one of F17 (#60). The Secure Enclave key with biometryCurrentSet on the Mac (needs
// Developer ID, F4), the phone-held key on the runner, the broker and connections come later.
nonisolated final class Vault: Sendable {
    let store: any VaultStore
    /// What the scanner looks for, read from the store on first use and again after each change
    /// (here, or to the store's file by another process: `stamp`).
    private let learned = Mutex<(stamp: String?, leaks: Leaks)?>(nil)

    init(store: any VaultStore) {
        self.store = store
    }

    /// The keychain on the Mac, the runner's file on Linux.
    static let shared: Vault = {
        #if canImport(Security)
        Vault(store: KeychainVault())
        #else
        Vault(store: FileVault(folder: folder))
        #endif
    }()

    /// Where the runner keeps its vault: in `OBY_HOME`, which agents see empty.
    static var folder: URL { Workspace.root.appending(path: "vault") }

    /// The shortest value the vault takes: a shorter one would match ordinary text everywhere.
    static let shortest = 8
    static let longest = 64 * 1024

    /// The secrets' names, sorted. Never their values.
    func names() throws -> [String] {
        try store.names().sorted()
    }

    /// Adds `value` as `name`, or replaces it. Newlines around it (a paste) are dropped. Errors name
    /// the secret, never the value.
    func add(_ value: String, as name: String) throws {
        let value = value.trimmingCharacters(in: .newlines)
        if let problem = Self.problem(name: name) ?? Self.problem(value: value) { throw Shell.Failure(message: problem) }
        try learned.withLock { learned in
            try store.save(value, as: name)
            learned = nil
        }
    }

    func remove(_ name: String) throws {
        try learned.withLock { learned in
            try store.remove(name)
            learned = nil
        }
    }

    /// Why `name` can't name a secret, or nil: letters, digits, `.`, `_` and `-`, so a name is safe
    /// in a log line or a finding.
    static func problem(name: String) -> String? {
        name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) == nil
            ? "A secret's name is up to 64 letters, digits, dots, dashes or underscores." : nil
    }

    /// Why the vault won't keep `value`, or nil.
    static func problem(value: String) -> String? {
        let size = value.utf8.count
        if size < shortest || value.trimmingCharacters(in: .whitespaces).isEmpty { return "A secret is at least \(shortest) characters." }
        if size > longest { return "A secret is at most 64 KB." }
        return nil
    }

    /// Every value and its encoded copies, for the secret scan. Throws when the vault can't be read:
    /// then the scan can't run, and nothing goes out.
    func leaks() throws -> Leaks {
        try learned.withLock { learned in
            let stamp = store.stamp()
            if let learned, learned.stamp == stamp { return learned.leaks }
            var values: [String: String] = [:]
            for name in try store.names() {
                if let value = try store.value(name) { values[name] = value }
            }
            let leaks = Leaks(values)
            learned = (stamp, leaks)
            return leaks
        }
    }

    /// What the scan has learned so far, without reading the vault: for redacting log lines.
    var known: Leaks? { learned.withLock { $0?.leaks } }

    /// Hands the value to `body`, for Oby's own call on a connection the user made. Nothing else reads it.
    func use<T>(_ name: String, _ body: (String) throws -> T) throws -> T {
        guard let value = try store.value(name) else { throw Shell.Failure(message: "The vault has no secret named \(name).") }
        return try body(value)
    }
}

/// Where a vault keeps its secrets. Errors name the secret or the place, never a value.
nonisolated protocol VaultStore: Sendable {
    func names() throws -> [String]
    func value(_ name: String) throws -> String?
    func save(_ value: String, as name: String) throws
    func remove(_ name: String) throws
    /// Changes when the secrets change outside this process; nil when nothing else changes them.
    func stamp() -> String?
}

extension VaultStore {
    func stamp() -> String? { nil }
}

// MARK: The runner's file

/// The runner's vault: `secrets.json` in a folder only the runner's user may open (0700), itself
/// readable only by that user (0600). A file or folder anyone else can read, or that someone else
/// owns, isn't read: the scan can't run until it's fixed, so nothing goes out.
// ponytail: plaintext at rest, guarded by the Unix user. Wrapped to the phone's Secure Enclave key,
// with plaintext only in a separate user's memory (and systemd-creds on a TPM), is the upgrade.
nonisolated final class FileVault: VaultStore {
    let folder: URL
    var file: URL { folder.appending(path: "secrets.json") }
    private let lock = Mutex(())

    private struct Saved: Codable {
        var secrets: [String: String]
    }

    init(folder: URL) {
        self.folder = folder
    }

    func names() throws -> [String] { try lock.withLock { _ in try Array(read().keys) } }

    /// `oby-runner vault add` changes the file while the service runs: a new file has a new date.
    func stamp() -> String? {
        let info = try? FileManager.default.attributesOfItem(atPath: file.path)
        return "\((info?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) \(info?[.size] ?? 0)"
    }
    func value(_ name: String) throws -> String? { try lock.withLock { _ in try read()[name] } }

    func save(_ value: String, as name: String) throws {
        try lock.withLock { _ in
            var secrets = try read()
            secrets[name] = value
            try write(secrets)
        }
    }

    func remove(_ name: String) throws {
        try lock.withLock { _ in
            var secrets = try read()
            guard secrets.removeValue(forKey: name) != nil else { return }
            try write(secrets)
        }
    }

    /// Every secret, or none when there's no file yet.
    private func read() throws -> [String: String] {
        guard try Self.private(folder, directory: true), try Self.private(file, directory: false) else { return [:] }
        do {
            return try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file)).secrets
        } catch {
            throw Shell.Failure(message: "Can't read the vault at \(file.path).")
        }
    }

    /// The file in place of the old one, created 0600 before a byte is written, then renamed over it.
    private func write(_ secrets: [String: String]) throws {
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(folder.path, 0o700) != 0, errno != EEXIST {
            throw Shell.Failure(message: "Can't make the vault's folder \(folder.path) (errno \(errno)).")
        }
        _ = try Self.private(folder, directory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Saved(secrets: secrets))
        let temporary = folder.appending(path: ".secrets-\(UUID().uuidString).json")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Shell.Failure(message: "Can't write the vault in \(folder.path) (errno \(errno)).") }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard fchmod(fd, 0o600) == 0 else { throw Shell.Failure(message: "Can't make the vault private (errno \(errno)).") }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, file.path) == 0 else { throw Shell.Failure(message: "Can't save the vault at \(file.path) (errno \(errno)).") }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    /// True when `url` is there and only the runner's user may read it; false when it isn't there.
    /// Throws when it's the wrong kind of thing (a link), someone else owns it, or anyone else may read it.
    static func `private`(_ url: URL, directory: Bool) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw Shell.Failure(message: "Can't read the vault at \(url.path) (errno \(errno)).")
        }
        // S_IFMT, S_IFDIR and S_IFREG, which Glibc's module doesn't spell the same way.
        let kind = info.st_mode & 0o170000, mode = info.st_mode & 0o777
        guard kind == (directory ? 0o040000 : 0o100000) else {
            throw Shell.Failure(message: "The vault's \(url.path) isn't a \(directory ? "folder" : "file").")
        }
        guard info.st_uid == geteuid() else {
            throw Shell.Failure(message: "The vault's \(url.path) belongs to another user: only the runner's user may own it.")
        }
        guard mode & 0o077 == 0 else {
            throw Shell.Failure(message: "Others may read the vault's \(url.path) (mode \(String(mode, radix: 8))): run chmod \(directory ? "700" : "600") on it.")
        }
        return true
    }
}

// MARK: The Mac's keychain

#if canImport(Security)
/// The Mac's vault: generic passwords in the login keychain, one per secret, readable only on
/// this Mac while it's unlocked. Other apps that ask for one get macOS's own prompt. Listing reads
/// the names alone, never the values.
// ponytail: the data-protection keychain with a Secure Enclave key and biometryCurrentSet needs
// Developer ID signing and a provisioning profile (F4).
nonisolated struct KeychainVault: VaultStore {
    var service = "com.deskree.oby.vault"

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    func names() throws -> [String] {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status, "list the vault")
        return (result as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func value(_ name: String) throws -> String? {
        var query = base
        query[kSecAttrAccount as String] = name
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, "read \(name)")
        return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    func save(_ value: String, as name: String) throws {
        var query = base
        query[kSecAttrAccount as String] = name
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = Data(value.utf8)
            query[kSecAttrLabel as String] = "Oby vault: \(name)"
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        try check(status, "save \(name)")
    }

    func remove(_ name: String) throws {
        var query = base
        query[kSecAttrAccount as String] = name
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status, "remove \(name)")
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status != errSecSuccess else { return }
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        throw Shell.Failure(message: "Couldn't \(what) in the keychain: \(reason).")
    }
}
#endif

// MARK: What the scan looks for

/// Every vault value in each form it could leave in: plain, base64 (standard or URL-safe, at any
/// offset in a longer run), hex, and URL-encoded. The secret scan blocks text that holds one; `redact`
/// takes them out of text Oby keeps or logs. The values themselves stay inside.
nonisolated struct Leaks: Sendable {
    struct Needle: Sendable {
        var name: String
        /// "base64", "hex" or "URL-encoded"; empty for the value itself.
        var how: String
        var text: String
        /// Hex and URL-encoding read the same in either case.
        var anyCase: Bool
    }

    /// Longest first, so a value goes before the parts that would match inside it.
    let needles: [Needle]

    static let empty = Leaks([:])

    init(_ values: [String: String]) {
        needles = values.sorted { $0.key < $1.key }.flatMap { Self.needles(for: $0.value, named: $0.key) }
            .sorted { $0.text.utf8.count > $1.text.utf8.count }
    }

    var isEmpty: Bool { needles.isEmpty }

    static func needles(for value: String, named name: String) -> [Needle] {
        let bytes = Array(value.utf8)
        var needles = [Needle(name: name, how: "", text: value, anyCase: false)]
        // A key or certificate split over lines: each long line on its own too.
        for line in value.split(whereSeparator: \.isNewline) where line.utf8.count >= Vault.shortest && line != Substring(value) {
            needles.append(Needle(name: name, how: "", text: String(line), anyCase: false))
        }
        for run in base64(bytes) {
            needles.append(Needle(name: name, how: "base64", text: run, anyCase: false))
            let safe = run.replacing("+", with: "-").replacing("/", with: "_")
            if safe != run { needles.append(Needle(name: name, how: "base64", text: safe, anyCase: false)) }
        }
        needles.append(Needle(name: name, how: "hex", text: bytes.map { String(format: "%02x", $0) }.joined(), anyCase: true))
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved), encoded != value {
            needles.append(Needle(name: name, how: "URL-encoded", text: encoded, anyCase: true))
        }
        needles.append(Needle(name: name, how: "URL-encoded", text: bytes.map { String(format: "%%%02X", $0) }.joined(), anyCase: true))
        return needles
    }

    /// The base64 characters that only the value decides, whatever comes before it in the encoded
    /// run: one per offset (0, 1 or 2 bytes in), so a value in the middle of a longer string is found too.
    static func base64(_ bytes: [UInt8]) -> [String] {
        (0..<3).compactMap { offset in
            let encoded = Array((Data(repeating: 0, count: offset) + Data(bytes)).base64EncodedString())
            // Character i holds bits 6i to 6i+6; the value's are 8·offset to 8·(offset+count).
            let first = (8 * offset + 5) / 6, end = (8 * (offset + bytes.count)) / 6
            guard end - first >= 4 else { return nil }
            return String(encoded[first..<end])
        }
    }

    /// The vault's secrets `text` holds, as the scan's rule names: "vault secret staging-key" or
    /// "vault secret staging-key, base64". Also looks in what the text's encoded runs decode to.
    func found(in text: String) -> [String] {
        guard !isEmpty else { return [] }
        var places = [(how: "", text: text)]
        if text.contains("%") {
            let plain = text.replacing(/(?:%[0-9A-Fa-f]{2})+/) { Publish.percent($0.output) }
            if plain != text { places.append(("URL-encoded", plain)) }
        }
        places += Publish.decoded(text)
        var seen = Set<String>()
        var rules: [String] = []
        for place in places {
            for needle in needles where !seen.contains(needle.name) && contains(place.text, needle) {
                seen.insert(needle.name)
                let how = [needle.how, place.how].filter { !$0.isEmpty }.joined(separator: " in ")
                rules.append("vault secret \(needle.name)" + (how.isEmpty ? "" : ", \(how)"))
            }
        }
        return rules
    }

    /// `text` with every vault value, plain or encoded, replaced by `[vault: name]`.
    func redact(_ text: String) -> String {
        var text = text
        for needle in needles where contains(text, needle) {
            text = needle.anyCase ? text.replacingOccurrences(of: needle.text, with: "[vault: \(needle.name)]", options: .caseInsensitive)
                : text.replacing(needle.text, with: "[vault: \(needle.name)]")
        }
        return text
    }

    private func contains(_ text: String, _ needle: Needle) -> Bool {
        needle.anyCase ? text.range(of: needle.text, options: .caseInsensitive) != nil : text.contains(needle.text)
    }
}
