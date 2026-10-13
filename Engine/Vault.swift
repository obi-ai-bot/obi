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
    /// What the scanner looks for, read from the store on first use and again whenever its
    /// `stamp` changes (a change here, or by another process, or to the file's permissions).
    private let learned = Mutex(Learned())

    private struct Learned {
        /// The store's stamp when `leaks` was read from it; nil until then, and after a change here.
        var stamp: String?
        /// The latest values known, kept when the store can't be read, so log lines stay redacted.
        var values: [String: String] = [:]
        var leaks = Leaks.empty
    }

    init(store: any VaultStore) {
        self.store = store
    }

    /// The keychain on the Mac, the runner's file on Linux. A runner on a Mac (#283, a bare
    /// executable with no bundle id) keeps its own keychain items, under its own service name: an
    /// item the app made would prompt the user when another program reads it.
    static let shared: Vault = {
        #if canImport(Security)
        Vault(store: KeychainVault(service: Bundle.main.bundleIdentifier == nil ? KeychainVault.runnerService : KeychainVault.appService))
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
            learned.values[name] = value
            learned.leaks = Leaks(learned.values)
            learned.stamp = nil
        }
    }

    func remove(_ name: String) throws {
        try learned.withLock { learned in
            try store.remove(name)
            learned.values[name] = nil
            learned.leaks = Leaks(learned.values)
            learned.stamp = nil
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

    /// Every value and its encoded copies, for the secret scan. The store is checked each time
    /// (on the runner, the file's permissions too) and read again when it changed. Throws when the
    /// vault can't be read: then the scan can't run, and nothing goes out.
    func leaks() throws -> Leaks {
        try learned.withLock { learned in
            let stamp = try store.stamp()
            if learned.stamp == stamp { return learned.leaks }
            var values: [String: String] = [:]
            for name in try store.names() {
                if let value = try store.value(name) { values[name] = value }
            }
            learned = Learned(stamp: stamp, values: values, leaks: Leaks(values))
            return learned.leaks
        }
    }

    /// What text and environments on their way to an agent (the brain, the Lead, a job's agent) are
    /// checked against. Throws, saying why, when the vault can't be read: then no prompt, message,
    /// file, review or environment goes to an agent, and the job says why.
    func forAgents() throws -> Leaks {
        do {
            return try leaks()
        } catch {
            throw Shell.Failure(message: "The vault can't be read (\(error.localizedDescription)): nothing goes to an agent until it's fixed.")
        }
    }

    /// `text` as an agent may get it: the vault's secrets, plain or encoded, taken out. Throws when
    /// the vault can't be read.
    func forAgent(_ text: String) throws -> String {
        try forAgents().redact(text)
    }

    /// What to redact log lines with: the vault as it is now, or the latest values known when it
    /// can't be read.
    func redacting() -> Leaks {
        (try? leaks()) ?? learned.withLock { $0.leaks }
    }

    /// JSON as it may leave Oby (a push through Apple, the runner's API): every string in it with
    /// the vault's secrets, plain or encoded, taken out (a job's request, title, step or summary
    /// could hold one). Unchanged when none does. Throws when the vault can't be read: then it doesn't go.
    func scrubbed(_ json: Data) throws -> Data {
        let leaks = try leaks()
        guard !leaks.isEmpty, let object = try? JSONSerialization.jsonObject(with: json, options: .fragmentsAllowed) else { return json }
        var changed = false
        func scrub(_ value: Any) -> Any {
            switch value {
            case let text as String:
                let clean = leaks.redact(text)
                if clean != text { changed = true }
                return clean
            case let list as [Any]: return list.map(scrub)
            case let fields as [String: Any]: return fields.mapValues(scrub)
            default: return value
            }
        }
        let clean = scrub(object)
        guard changed else { return json }
        return try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

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
    /// Changes whenever the secrets may have changed, here or elsewhere. Cheap: no value is read.
    /// Throws when the store can't be read as it is now.
    func stamp() throws -> String
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

    /// The file's inode, size and time, after the same checks as reading it: `oby-runner vault add`
    /// changes the file while the service runs (each save is a new file), and a chmod that lets
    /// others read it makes the scan fail even with the values learned.
    func stamp() throws -> String {
        guard try Self.private(folder, directory: true) != nil, let info = try Self.private(file, directory: false) else { return "none" }
        #if os(Linux)
        let time = info.st_mtim
        #else
        let time = info.st_mtimespec
        #endif
        return "\(info.st_ino) \(info.st_size) \(time.tv_sec).\(time.tv_nsec)"
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
        guard try Self.private(folder, directory: true) != nil, try Self.private(file, directory: false) != nil else { return [:] }
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
        try Self.private(folder, directory: true)
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

    /// What `lstat` says of `url` when it's there and only the runner's user may read it; nil when
    /// it isn't there. Throws when it's the wrong kind of thing (a link), someone else owns it, or
    /// anyone else may read it.
    @discardableResult
    static func `private`(_ url: URL, directory: Bool) throws -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
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
        return info
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
    static let appService = "com.deskree.oby.vault"
    /// The runner's on a Mac (`oby-runner vault …` from the app's Contents/Helpers adds to it).
    static let runnerService = "com.deskree.oby.runner.vault"

    var service = appService
    /// What Keychain Access shows an item as, before its name.
    var label = "Oby vault"

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    func names() throws -> [String] {
        try items().compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Each item's name and when it last changed: Keychain Access or `security` can change one
    /// outside Oby.
    func stamp() throws -> String {
        try items().map { item in
            let date = (item[kSecAttrModificationDate as String] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(item[kSecAttrAccount as String] as? String ?? "?") \(date)"
        }.sorted().joined(separator: "\n")
    }

    /// Every item's attributes, never its data.
    private func items() throws -> [[String: Any]] {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status, "list the vault")
        return result as? [[String: Any]] ?? []
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
            query[kSecAttrLabel as String] = "\(label): \(name)"
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
        // The same value with Windows line ends, as a file in the diff may have it.
        if value.utf8.contains(10), !value.contains("\r\n") {
            needles.append(Needle(name: name, how: "", text: value.replacing("\n", with: "\r\n"), anyCase: false))
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
        // As a form sends it: spaces as +.
        if value.contains(" "), let form = value.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: " "))) {
            needles.append(Needle(name: name, how: "URL-encoded", text: form.replacing(" ", with: "+"), anyCase: true))
        }
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
        hits(in: text).map { "vault secret \($0.name)" + ($0.how.isEmpty ? "" : ", \($0.how)") }
    }

    /// Each secret `text` holds, once, and how: "" for the value itself, "base64", "hex in base64"…
    func hits(in text: String) -> [(name: String, how: String)] {
        guard !isEmpty else { return [] }
        var places = [(how: "", text: text)]
        if text.contains("%") {
            let plain = text.replacing(/(?:%[0-9A-Fa-f]{2})+/) { Publish.percent($0.output) }
            if plain != text { places.append(("URL-encoded", plain)) }
        }
        if text.contains("+") {
            let form = text.replacing("+", with: " ").replacing(/(?:%[0-9A-Fa-f]{2})+/) { Publish.percent($0.output) }
            places.append(("URL-encoded", form))
        }
        // Any decoded run as long as the shortest value: the built-in rules' 15 readable characters would miss a short one.
        places += Publish.decoded(text, keep: { $0.utf8.count >= Vault.shortest })
        var seen = Set<String>()
        var hits: [(name: String, how: String)] = []
        for place in places {
            for needle in needles where !seen.contains(needle.name) && contains(place.text, needle) {
                seen.insert(needle.name)
                hits.append((needle.name, [needle.how, place.how].filter { !$0.isEmpty }.joined(separator: " in ")))
            }
        }
        return hits
    }

    /// The secrets whose value spans lines, found in `lines` joined as they were: each once, with
    /// the index of the line it starts on. A line on its own never holds the whole value.
    func spanning(_ lines: [String]) -> [(name: String, line: Int)] {
        let joined = lines.joined(separator: "\n")
        var seen = Set<String>()
        return needles.compactMap { needle in
            guard needle.how.isEmpty, needle.text.utf8.contains(10), !seen.contains(needle.name),
                  let range = joined.range(of: needle.text) else { return nil }
            seen.insert(needle.name)
            // By byte: "\r\n" is one Character.
            return (needle.name, joined[..<range.lowerBound].utf8.count { $0 == 10 })
        }
    }

    /// Whether any value spans lines, so `spanning` has something to find.
    var spans: Bool { needles.contains { $0.how.isEmpty && $0.text.utf8.contains(10) } }

    /// `text` with every vault value the scan would find in it replaced by `[vault: name]`: each
    /// copy, plain or encoded, then any encoded run that decodes to one (a partly URL-encoded value,
    /// hex inside base64), then, if something is still found, the lines that hold it, and last the whole text.
    func redact(_ text: String) -> String {
        guard !isEmpty else { return text }
        var text = text
        for needle in needles where contains(text, needle) {
            text = needle.anyCase ? text.replacingOccurrences(of: needle.text, with: marker([needle.name]), options: .caseInsensitive)
                : text.replacing(needle.text, with: marker([needle.name]))
        }
        if text.contains("\n") { text = unwrapped(text) }
        guard !hits(in: text).isEmpty else { return text }
        let runs = [/[^\s"'<>]*%[0-9A-Fa-f]{2}[^\s"'<>]*/, /[A-Za-z0-9+\/_-]{16,}={0,2}/, /[0-9A-Fa-f]{16,}/,
                    /(?:\\x[0-9A-Fa-f]{2}){8,}|(?:0x[0-9A-Fa-f]{2}[\s,]*){8,}/]
        for run in runs {
            text = text.replacing(run) { match in
                let names = hits(in: String(match.output)).map(\.name)
                return names.isEmpty ? String(match.output) : marker(names)
            }
        }
        guard !hits(in: text).isEmpty else { return text }
        text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let names = hits(in: String(line)).map(\.name)
            return names.isEmpty ? String(line) : marker(names)
        }.joined(separator: "\n")
        let names = hits(in: text).map(\.name)
        return names.isEmpty ? text : marker(names)
    }

    /// `text` with base64 or hex wrapped over lines taken out, joined as the scan joins them
    /// (`Publish.wrapped`): runs of lines that hold nothing else, with the end of the line before.
    private func unwrapped(_ text: String) -> String {
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"',\\"))
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let encoded = lines.map { line in
            let text = line.trimmingCharacters(in: trim)
            return !text.isEmpty && text.wholeMatch(of: /[A-Za-z0-9+\/=_-]+/) != nil
        }
        var start = 0
        while start < lines.count {
            guard encoded[start] else { start += 1; continue }
            var end = start
            while end + 1 < lines.count, encoded[end + 1] { end += 1 }
            let lead = start == 0 ? "" : lines[start - 1].trimmingCharacters(in: trim).firstMatch(of: /[A-Za-z0-9+\/_-]{8,}$/).map { String($0.output) } ?? ""
            let joined = lead + lines[start...end].map { $0.trimmingCharacters(in: trim) }.joined()
            let names = hits(in: joined).map(\.name)
            if !names.isEmpty {
                for index in (lead.isEmpty ? start : start - 1)...end { lines[index] = marker(names) }
            }
            start = end + 1
        }
        return lines.joined(separator: "\n")
    }

    private func marker(_ names: [String]) -> String { "[vault: \(names.joined(separator: ", "))]" }

    private func contains(_ text: String, _ needle: Needle) -> Bool {
        needle.anyCase ? text.range(of: needle.text, options: .caseInsensitive) != nil : text.contains(needle.text)
    }
}
