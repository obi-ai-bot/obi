import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(Security)
import Security
#endif

/// The runner on the user's own Mac (#283): where it keeps its files, and the token that lets the
/// Oby app on the same Mac into its loopback API. Nothing on a Mac vouches for who's asking the
/// way `tailscale serve` does on tetrix-lab, so the runner makes a token of its own when it first
/// starts and keeps it in the keychain (`keychainService`), never in a file: agents on a Mac run as
/// the user, outside bubblewrap, and could read any file of theirs, while another program reading
/// the keychain item is one the user is asked about. The app reads it there and sends it as
/// `Authorization: Bearer`. The runner answers only on `127.0.0.1`, and only requests whose `Host`
/// is a loopback name: a web page the user opens can't have their browser reach it through a name
/// that resolves to 127.0.0.1 (DNS rebinding). obid instead keeps api-token in its sandbox-hidden
/// home; the app can read that owner-only file when obid uses the same This Mac home.
nonisolated enum LocalRunner {
    static let port = 7777
    /// Where the Mac app follows the runner on this Mac.
    static let url = URL(string: "http://127.0.0.1:\(port)")!
    /// The keychain service the token lives under, and the item's name. Oby.app and `oby-runner`
    /// are different programs: the first time one reads what the other made, macOS may ask the user.
    static let keychainService = "com.deskree.oby.runner"
    static let tokenName = "token"

    /// The app's own folder: `~/Library/Application Support/Oby` (`Workspace.root` without `OBY_HOME`).
    /// A Mac runner shares its `accounts.json` and account homes (Settings › Accounts adds and
    /// signs them in: `accounts(local:)`) and the app's attachments with the app, and nothing else.
    static var appRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Oby", directoryHint: .isDirectory)
    }

    /// What the runner's `OBY_HOME` defaults to on a Mac: `~/Library/Application Support/Oby/Runner`,
    /// inside the app's own folder but never the same: each has its own `oby.sqlite`, clones and worktrees.
    static var home: URL { appRoot.appending(path: "Runner", directoryHint: .isDirectory) }

    /// Where the app keeps what the user attached to a request (the tray's screenshots and clipboard):
    /// the only files a dispatch may attach to a job (`Attachments.validated`).
    static var attachments: URL { appRoot.appending(path: "attachments", directoryHint: .isDirectory) }

    /// The accounts the runner spreads jobs across. A runner for this Mac's app (`local`) reads the
    /// app's own `accounts.json` and account homes, so what Settings set up (Codex, named Claude
    /// accounts) is what it runs jobs on; any other runner has accounts of its own, in its `OBY_HOME`.
    static func accounts(local: Bool, appRoot: URL = appRoot, workspace: URL = Workspace.root) -> AccountStore {
        AccountStore(root: local ? appRoot : workspace)
    }

    /// Where the token is kept: the keychain on a Mac. Linux runners have an owner instead.
    static var keychain: any LocalTokenStore {
        #if canImport(Security)
        KeychainVault(service: keychainService, label: "Oby runner")
        #else
        NoTokenStore()
        #endif
    }

    /// The credential for This Mac. obid uses the same home as the Swift runner and keeps its
    /// token in api-token; the Swift runner continues to use its keychain item. After a 401,
    /// excluding that credential lets a stale file fall back to the running Swift runner.
    static func token(home: URL = home, fallback: any LocalTokenStore = keychain, excluding refused: String? = nil) -> String? {
        if let token = obidToken(in: home), token != refused { return token }
        guard let token = token(from: fallback), token != refused else { return nil }
        return token
    }

    /// A bounded read of a regular, owner-only file. O_NOFOLLOW and fstat check the file we
    /// actually opened; O_NONBLOCK keeps a FIFO at that name from hanging the app.
    static func obidToken(in home: URL) -> String? {
        let path = home.appending(path: "api-token").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              let data = try? file.read(upToCount: 4097), data.count <= 4096 else { return nil }
        var bytes = Array(data)
        while bytes.last == 10 || bytes.last == 13 { bytes.removeLast() }
        guard bytes.count >= 32, bytes.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The token as `store` has it, or nil when there's none yet (the runner hasn't started) or
    /// what's there isn't one.
    static func token(from store: any LocalTokenStore) -> String? {
        guard let kept = try? store.read() else { return nil }
        let token = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        return isToken(token) ? token : nil
    }

    /// The runner's token: the store's, or a new one kept there (64 hex characters from 32 random
    /// bytes). What's there that isn't a token is replaced.
    static func makeToken(in store: any LocalTokenStore = keychain) throws -> String {
        if let token = token(from: store) { return token }
        var generator = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        try store.write(token)
        return token
    }

    static func isToken(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }

    /// Whether `header`, a request's `Host`, names this machine's loopback: `127.0.0.1`,
    /// `localhost` or `[::1]`, with or without a port. Anything else (`evil.example`, a tailnet
    /// name, no `Host` at all) isn't let in on a Mac runner.
    static func isLoopback(host header: String?) -> Bool {
        guard var host = header?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") {
            // An IPv6 literal: `[::1]` or `[::1]:7777`.
            guard let close = host.firstIndex(of: "]") else { return false }
            let rest = host[host.index(after: close)...]
            guard rest.isEmpty || (rest.hasPrefix(":") && Int(rest.dropFirst()) != nil) else { return false }
            host = String(host[host.index(after: host.startIndex)..<close])
            return host == "::1"
        }
        if let colon = host.lastIndex(of: ":") {
            guard Int(host[host.index(after: colon)...]) != nil else { return false }
            host = String(host[..<colon])
        }
        return ["127.0.0.1", "localhost"].contains(host)
    }

    /// Whether both tokens are the same, in time that doesn't depend on where they differ.
    static func same(_ given: String, as token: String) -> Bool {
        let a = Array(given.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

/// Where a Mac runner's token is kept: one item, read and written whole.
nonisolated protocol LocalTokenStore: Sendable {
    func read() throws -> String?
    func write(_ token: String) throws
}

#if canImport(Security)
/// The keychain item `LocalRunner.tokenName` under the vault's service (Engine/Vault.swift).
extension KeychainVault: LocalTokenStore {
    func read() throws -> String? { try value(LocalRunner.tokenName) }
    func write(_ token: String) throws { try save(token, as: LocalRunner.tokenName) }
}
#else
/// Linux has no keychain, and its runner has an owner: a Mac runner never runs there.
nonisolated struct NoTokenStore: LocalTokenStore {
    func read() throws -> String? { throw Shell.Failure(message: "A runner without OBY_OWNER keeps its token in the keychain, which this machine has none of.") }
    func write(_ token: String) throws { _ = try read() }
}
#endif

/// A token kept in memory: the tests'.
nonisolated final class MemoryTokens: LocalTokenStore {
    private let kept = Mutex<String?>(nil)

    init(_ token: String? = nil) { kept.withLock { $0 = token } }

    func read() throws -> String? { kept.withLock { $0 } }
    func write(_ token: String) throws { kept.withLock { $0 = token } }
}
