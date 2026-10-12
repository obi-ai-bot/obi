import Foundation

/// The runner on the user's own Mac (#283): where it keeps its files, and the token that lets the
/// Oby app on the same Mac into its loopback API. Nothing on a Mac vouches for who's asking the
/// way `tailscale serve` does on tetrix-lab, so the runner makes a token of its own when it first
/// starts and keeps it in a file only the user may read, inside its `OBY_HOME`; the app reads it
/// there and sends it as `Authorization: Bearer`. The runner answers only on `127.0.0.1`, and only
/// requests whose `Host` is a loopback name: a web page the user opens can't have their browser
/// reach it through a name that resolves to 127.0.0.1 (DNS rebinding).
nonisolated enum LocalRunner {
    static let port = 7777
    /// Where the Mac app follows the runner on this Mac.
    static let url = URL(string: "http://127.0.0.1:\(port)")!
    /// The token file, in the runner's `OBY_HOME`.
    static let tokenFile = "token"

    /// What the runner's `OBY_HOME` defaults to on a Mac: `~/Library/Application Support/Oby/Runner`,
    /// inside the app's own folder (`Workspace.root` without `OBY_HOME`) but never the same: each
    /// has its own `oby.sqlite`, clones and worktrees.
    static var home: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Oby/Runner", directoryHint: .isDirectory)
    }

    /// The token as the file in `home` has it, or nil when there's none yet (the runner hasn't
    /// started) or it isn't one.
    static func token(in home: URL = home) -> String? {
        guard let data = try? Data(contentsOf: home.appending(path: tokenFile)) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return isToken(token) ? token : nil
    }

    /// The runner's token: the file's, or a new one written there (64 hex characters from 32
    /// random bytes), readable by the user alone (0600). A file that isn't a token is replaced.
    static func makeToken(in home: URL = home) throws -> String {
        if let token = token(in: home) { return token }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        let file = home.appending(path: tokenFile)
        guard FileManager.default.createFile(atPath: file.path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw Shell.Failure(message: "Couldn't write the runner's token at \(file.path).")
        }
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
