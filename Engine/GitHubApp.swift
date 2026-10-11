import Foundation
import Synchronization

/// Who a GitHub call acts as. The owner's own gh login pushes branches, opens and edits pull
/// requests and reads who they are; what the runner does on its own (reading pull requests,
/// issues and the board, posting reviews and check results, merging into dev, failure records)
/// acts as the Oby by Deskree app, with a budget of its own. `Shell` applies it.
nonisolated enum GitHubActor: String, Sendable {
    case app, owner
}

/// The Oby by Deskree GitHub App: installation tokens minted with the app's key, cached until five
/// minutes before they expire, and minted again when GitHub refuses one. The key stays in this
/// process: only `sign` holds it, and nothing here logs or hands it out. Without an app (the Mac,
/// tests), or without an installation for the account a call names, calls go as the owner.
actor GitHubApp {
    /// The runner's settings: the App ID (or Client ID) and where its private key is.
    nonisolated static let idVariable = "OBY_GITHUB_APP_ID"
    nonisolated static let keyVariable = "OBY_GITHUB_APP_KEY"
    /// Never in an agent's environment, nor anything Oby runs.
    nonisolated static let variables = [idVariable, keyVariable]
    nonisolated static var defaultKey: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/oby/github-app.pem")
    }

    /// One answer from GitHub's API.
    struct Answer: Sendable {
        var status: Int
        var body: Data
    }
    struct Token: Sendable {
        var value: String
        var expires: Date
    }

    /// The app Oby uses, set once by the runner at start.
    nonisolated static var shared: GitHubApp? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
    private nonisolated static let current = Mutex<GitHubApp?>(nil)

    /// Whether GitHub calls go as the app (`/v1/status`'s `github`): the app is set up and its
    /// last request for a token worked.
    nonisolated static var inUse: Bool { shared?.works == true }
    nonisolated var works: Bool { worked.withLock { $0 } }

    /// Whether Oby's review and Mac check can go on pull requests as check runs (`/v1/status`'s
    /// `checks`): "ok", "missing permission" until the owner grants the app Checks: Read and write,
    /// or "no app" when calls go as the owner, who can't write check runs.
    nonisolated static var checks: String { checks(shared) }
    nonisolated static func checks(_ app: GitHubApp?) -> String {
        guard let app, app.works else { return "no app" }
        return app.writesChecks ? "ok" : "missing permission"
    }
    /// The installations GitHub listed have Checks: write, or the last check run Oby wrote went through.
    nonisolated var writesChecks: Bool { checksWritable.withLock { $0 } }
    /// A check run went through (true) or GitHub refused it for the permission (false).
    nonisolated func wroteChecks(_ allowed: Bool) { checksWritable.withLock { $0 = allowed } }

    nonisolated let id: String
    /// RS256 over the JWT's signing input, with the app's key.
    private let sign: @Sendable (Data) throws -> Data
    /// One request to api.github.com: method, path, bearer token.
    private let send: @Sendable (_ method: String, _ path: String, _ bearer: String) async throws -> Answer
    private let now: @Sendable () -> Date
    private nonisolated let worked = Mutex(false)
    private nonisolated let checksWritable = Mutex(false)
    /// The installations by account, lowercased, and when they were read.
    private var installations: [String: Int]?
    private var installationsRead = Date.distantPast
    private var tokens: [Int: Token] = [:]
    private var minting: [Int: Task<Token?, Never>] = [:]
    private var failed: [Int: Date] = [:]

    init(id: String, sign: @escaping @Sendable (Data) throws -> Data,
         send: @escaping @Sendable (_ method: String, _ path: String, _ bearer: String) async throws -> Answer = GitHubApp.curl,
         now: @escaping @Sendable () -> Date = { .now }) {
        self.id = id
        self.sign = sign
        self.send = send
        self.now = now
    }

    // MARK: The JWT

    /// `{"alg": "RS256", "typ": "JWT"}.{"iat", "exp", "iss"}`, base64url, signed: issued a minute
    /// ago for clock drift, and expiring in nine minutes (GitHub takes ten at most).
    func jwt() throws -> String {
        let time = Int(now().timeIntervalSince1970)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"], options: .sortedKeys)
        let claims = try JSONSerialization.data(withJSONObject: ["iat": time - 60, "exp": time + 540, "iss": id] as [String: Any], options: .sortedKeys)
        let input = Self.base64URL(header) + "." + Self.base64URL(claims)
        return input + "." + Self.base64URL(try sign(Data(input.utf8)))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }

    // MARK: Tokens

    /// The installation token for `account` (a user or organization login), or nil: then the call
    /// goes as the owner. With no account named, the app's only installation, if it has just one.
    func token(for account: String?) async -> String? {
        guard let installation = await installation(for: account) else { return nil }
        if let token = tokens[installation], token.expires.timeIntervalSince(now()) > 300 { return token.value }
        if let running = minting[installation] { return await running.value?.value }
        // A token GitHub wouldn't give is asked for again after a minute, not on every call.
        if let failed = failed[installation], now().timeIntervalSince(failed) < 60 { return nil }
        let task = Task { await mint(installation) }
        minting[installation] = task
        let token = await task.value
        minting[installation] = nil
        tokens[installation] = token
        failed[installation] = token == nil ? now() : nil
        return token?.value
    }

    /// GitHub refused `token` (401): the next call mints another.
    func refused(_ token: String) {
        tokens = tokens.filter { $0.value.value != token }
    }

    /// Reads the installations and mints a token for one, so the runner's journal and `/v1/status`
    /// say at start whether the app works. Returns the accounts it's installed for.
    func check() async -> [String] {
        await read()
        let accounts = (installations ?? [:]).keys.sorted()
        if let account = accounts.first { _ = await token(for: account) }
        return accounts
    }

    private func installation(for account: String?) async -> Int? {
        // A list that couldn't be read is tried again after a minute; an account missing from one
        // read more than ten minutes ago may have installed the app since.
        let age = now().timeIntervalSince(installationsRead)
        if installations == nil ? age > 60 : account.map({ installations?[$0.lowercased()] == nil }) == true && age > 600 {
            await read()
        }
        guard let installations else { return nil }
        guard let account else { return installations.count == 1 ? installations.first?.value : nil }
        return installations[account.lowercased()]
    }

    private func read() async {
        installationsRead = now()
        do {
            let answer = try await send("GET", "/app/installations?per_page=100", try jwt())
            guard answer.status == 200, let rows = try JSONSerialization.jsonObject(with: answer.body) as? [[String: Any]] else {
                throw Shell.Failure(message: "GitHub answered \(answer.status)")
            }
            var found: [String: Int] = [:]
            var checks = !rows.isEmpty
            for row in rows {
                if let id = row["id"] as? Int, let account = row["account"] as? [String: Any], let login = account["login"] as? String {
                    found[login.lowercased()] = id
                }
                if (row["permissions"] as? [String: Any])?["checks"] as? String != "write" { checks = false }
            }
            installations = found
            wroteChecks(checks)
            if found.isEmpty { worked.withLock { $0 = false } }
        } catch {
            worked.withLock { $0 = false }
            Logger.github.error("GitHub app \(self.id, privacy: .public): couldn't read its installations (\(error.localizedDescription, privacy: .public)). GitHub calls go as the owner.")
        }
    }

    private func mint(_ installation: Int) async -> Token? {
        do {
            let answer = try await send("POST", "/app/installations/\(installation)/access_tokens", try jwt())
            guard answer.status == 201, let row = try JSONSerialization.jsonObject(with: answer.body) as? [String: Any],
                  let value = row["token"] as? String, let at = row["expires_at"] as? String,
                  let expires = try? Date(at, strategy: .iso8601) else {
                if answer.status == 404 { installations = nil }
                throw Shell.Failure(message: "GitHub answered \(answer.status)")
            }
            worked.withLock { $0 = true }
            return Token(value: value, expires: expires)
        } catch {
            worked.withLock { $0 = false }
            Logger.github.error("GitHub app \(self.id, privacy: .public): no token for installation \(installation, privacy: .public) (\(error.localizedDescription, privacy: .public)). GitHub calls go as the owner.")
            return nil
        }
    }

    /// A request with curl, its settings on stdin so the bearer token isn't in any process's arguments.
    nonisolated static func curl(_ method: String, _ path: String, _ bearer: String) async throws -> Answer {
        let quoted = { (value: String) in "\"" + value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\"" }
        let config = [
            "url = \(quoted("https://api.github.com\(path)"))",
            "request = \(quoted(method))",
            "header = \(quoted("authorization: Bearer \(bearer)"))",
            "header = \"accept: application/vnd.github+json\"",
            "header = \"x-github-api-version: 2022-11-28\"",
            "user-agent = \"oby-runner\"",
            "silent", "max-time = 20", "write-out = \"\\n%{http_code}\"",
        ].joined(separator: "\n") + "\n"
        let result = try await Shell.run(["curl", "-K", "-"], input: Data(config.utf8), timeout: 30)
        guard result.status == 0, let cut = result.out.lastIndex(of: UInt8(ascii: "\n")),
              let status = Int(String(decoding: result.out[(cut + 1)...], as: UTF8.self)) else {
            throw Shell.Failure(message: "curl exit \(result.status)")
        }
        return Answer(status: status, body: Data(result.out[..<cut]))
    }

    // MARK: Who a gh call is for

    /// The account a gh call names, whose installation acts for it: `-R`/`--repo owner/name`,
    /// `--owner`, a github.com URL, or an API path under `repos/` or `orgs/`.
    nonisolated static func account(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            if ["-R", "--repo", "--owner"].contains(argument), let next, let owner = next.split(separator: "/").first { return String(owner) }
            for prefix in ["--repo=", "--owner=", "-R="] where argument.hasPrefix(prefix) {
                if let owner = argument.dropFirst(prefix.count).split(separator: "/").first { return String(owner) }
            }
            if argument.hasPrefix("https://github.com/"), let owner = argument.dropFirst("https://github.com/".count).split(separator: "/").first {
                return String(owner)
            }
            let path = argument.hasPrefix("/") ? argument.dropFirst() : Substring(argument)
            for prefix in ["repos/", "orgs/"] where path.hasPrefix(prefix) {
                if let owner = path.dropFirst(prefix.count).split(separator: "/").first { return String(owner) }
            }
        }
        return nil
    }

    /// Calls about the owner: `gh api user…`, and any that names `@me`, mean the owner's login.
    nonisolated static func ownersOwn(_ arguments: [String]) -> Bool {
        if arguments.contains("@me") { return true }
        guard let api = arguments.firstIndex(of: "api"), let path = arguments.dropFirst(api + 1).first(where: { !$0.hasPrefix("-") }) else { return false }
        let trimmed = path.hasPrefix("/") ? path.dropFirst() : Substring(path)
        return trimmed == "user" || trimmed.hasPrefix("user/") || trimmed.hasPrefix("user?")
    }

    /// Whether gh's answer is GitHub refusing the token.
    nonisolated static func refused(_ output: Shell.Output) -> Bool {
        output.status != 0 && (output.err.contains("HTTP 401") || output.err.contains("Bad credentials"))
    }
}

extension Logger {
    nonisolated static let github = Logger(subsystem: "com.deskree.oby", category: "github")
}
