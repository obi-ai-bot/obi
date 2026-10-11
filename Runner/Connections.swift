import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ObyEngine

/// An app or API the user connected (F17, #60): its name, the remote MCP server (Streamable HTTP)
/// or API it reaches, and which vault secret goes in which header. The secret is named, never
/// held: the user sets it with `oby-runner vault add`, and only the broker reads it (Runner/Broker.swift).
struct Connection: Codable, Equatable {
    var name: String
    /// The remote MCP server's URL, or nil for an API.
    var mcp: String?
    /// The API's base URL, or nil for an MCP server.
    var api: String?
    /// The vault secret's name.
    var secret: String
    /// The header the secret goes in: nil (or `Authorization`) for `Authorization: Bearer <secret>`,
    /// else that header with the secret as it is.
    var header: String?
    var created = Date.now

    /// Where it reaches: the MCP server, or the API's base.
    var url: URL { URL(string: mcp ?? api ?? "")! }
    var host: String { url.host ?? "" }

    /// A name that can't run into a tool's: lower-case letters, digits and dashes, so
    /// `<name>_<tool>` splits at its first underscore.
    static func problem(name: String) -> String? {
        name.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,31}/) == nil ? "A connection's name is up to 32 lower-case letters, digits or dashes." : nil
    }

    /// Why `text` can't be a connection's URL, or nil: HTTPS, with no login or fragment in it, or
    /// HTTP only on this machine. The secret never travels in the clear.
    static func problem(url text: String) -> String? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else {
            return "\(text) isn't a URL a connection can use: https://host/path, with no login, query or fragment in it."
        }
        guard scheme == "https" || scheme == "http" && loopback(host) else {
            return "A connection's URL is HTTPS (HTTP only on 127.0.0.1): the secret never travels in the clear."
        }
        return nil
    }

    static func loopback(_ host: String) -> Bool { ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased()) }

    /// Why `header` can't carry the secret, or nil.
    static func problem(header: String) -> String? {
        let reserved: Set<String> = ["host", "content-length", "content-type", "transfer-encoding", "connection", "accept",
                                     "cookie", "mcp-session-id", "mcp-protocol-version"]
        return header.wholeMatch(of: /[A-Za-z0-9-]{1,64}/) == nil || reserved.contains(header.lowercased())
            ? "\(header) can't carry the secret: name a header like Authorization or X-Api-Key." : nil
    }

    /// Everything wrong with it, or nil.
    var problem: String? {
        if let problem = Self.problem(name: name) { return problem }
        guard (mcp == nil) != (api == nil), let text = mcp ?? api else { return "A connection has either mcp (a remote MCP server's URL) or api (an API's base URL)." }
        if let problem = Self.problem(url: text) ?? Vault.problem(name: secret) { return problem }
        return header.flatMap(Self.problem(header:))
    }

    /// What the user approves on their phone to add it: the runner's own sentence, signed exactly.
    var action: String {
        let header = header.flatMap { $0.lowercased() == "authorization" ? nil : $0 }
        return "Connect \(name): agents' read-only calls to \(mcp.map { "the MCP server \($0)" } ?? "the API \(api ?? "")") carry the vault secret \(secret)"
            + (header.map { " in the header \($0)." } ?? " as Authorization: Bearer.")
    }

    /// What the user approves on their phone to remove the connection named `name`.
    static func removal(_ name: String) -> String { "Disconnect \(name)." }

    /// Puts the secret in its header. A value that spans lines can't be a header.
    func authorize(_ request: inout URLRequest, with value: String) throws {
        guard !value.contains(where: \.isNewline) else {
            throw Shell.Failure(message: "The vault secret \(secret) spans lines, so it can't go in a header.")
        }
        if let header, header.lowercased() != "authorization" {
            request.setValue(value, forHTTPHeaderField: header)
        } else {
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        }
    }
}

/// The connections, in `connections.json` in `OBY_HOME` (which every agent's sandbox hides). Names
/// and URLs only: no secret is ever in it. Without a file (the tests), in memory only.
@MainActor
final class ConnectionStore {
    let file: URL?
    private(set) var all: [Connection] = []

    init(file: URL?) {
        self.file = file
        guard let file, let data = try? Data(contentsOf: file) else { return }
        do {
            all = try JSONDecoder.iso.decode([Connection].self, from: data)
        } catch {
            Logger.runner.error("can't read \(file.path, privacy: .public): no app is connected until it's fixed")
        }
    }

    /// Adds `connection`, or replaces the one with its name.
    func save(_ connection: Connection) throws {
        if let problem = connection.problem { throw Shell.Failure(message: problem) }
        var all = all.filter { $0.name != connection.name }
        all.append(connection)
        try write(all.sorted { $0.name < $1.name })
    }

    /// Removes the connection named `name`, and says whether there was one. The secret stays in the vault.
    func remove(_ name: String) throws -> Bool {
        guard all.contains(where: { $0.name == name }) else { return false }
        try write(all.filter { $0.name != name })
        return true
    }

    func named(_ name: String) -> Connection? { all.first { $0.name == name } }

    private func write(_ list: [Connection]) throws {
        if let file {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(list).write(to: file, options: .atomic)
        }
        all = list
    }
}

/// The vault's use log: one JSON line per call an agent made through a connection, in
/// `uses.jsonl` beside the vault's secrets, readable only by the runner's user. Names only (the
/// job, the connection, the tool, the secret, the host, read or write, allowed or refused), never a value.
// ponytail: it only grows; trim it, and show it in Settings, when the Mac app's side comes.
@MainActor
final class UseLog {
    let file: URL?
    /// When each connection was last used, from the log and since.
    private(set) var lastUsed: [String: Date] = [:]
    /// Every use this run, oldest first.
    private(set) var recent: [ConnectionUse] = []

    init(file: URL?) {
        self.file = file
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let use = try? JSONDecoder.iso.decode(ConnectionUse.self, from: Data(line.utf8)) else { continue }
            lastUsed[use.connection] = max(lastUsed[use.connection] ?? use.date, use.date)
        }
    }

    func append(_ use: ConnectionUse) {
        recent.append(use)
        lastUsed[use.connection] = use.date
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(use) else { return }
        line.append(0x0A)
        // The vault's folder, 0700, as the vault makes it; the log 0600, appended to, never a link.
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = mkdir(folder.path, 0o700)
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return Logger.runner.error("can't write the vault's use log at \(file.path, privacy: .public) (errno \(errno, privacy: .public))") }
        defer { close(fd) }
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

extension JSONDecoder {
    /// ISO 8601 dates, as the runner writes them.
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
