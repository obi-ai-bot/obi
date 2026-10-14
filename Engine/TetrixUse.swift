import Foundation

/// What Oby sees of a job's agent and Tetrix (#130): whether its tool had Tetrix's MCP server
/// connected, the Tetrix tools it called, and whether its commits carry the session it saved.
/// Claude Code says which MCP servers it connected in its stream-json `init`, Codex's app-server
/// in `mcpServerStatus/list`; both report each tool call.
nonisolated struct TetrixUse: Codable, Equatable, Sendable {
    /// What an agent's tool said: whether Tetrix was connected as its session started, or a call to
    /// one of Tetrix's tools, by name (`search_entities`).
    enum Seen: Equatable, Sendable {
        case connected(Bool)
        case call(String)
    }

    /// The job's own commits as its last round left them: how many carry a `Tetrix-Session:`
    /// trailer, and the sessions they name.
    struct Stamps: Codable, Equatable, Sendable {
        var commits: Int
        var stamped: Int
        var sessions: [String]
    }

    /// Whether the agent had Tetrix connected, or nil before its tool said.
    var connected: Bool?
    /// Its Tetrix calls by tool, over every round.
    var calls: [String: Int] = [:]
    /// Tetrix calls in each round that ended, oldest first.
    var rounds: [Int]?
    /// A round had Tetrix connected and didn't use it, and the next round's message said so: once a job.
    var reminded: Bool?
    var stamps: Stamps?
    /// On Oby's review jobs: what Oby saw of the author's agent and Tetrix (`report`), for the reviewer.
    var author: String?

    /// The trailer agents stamp their commits with.
    static let trailer = "Tetrix-Session"
    /// The tool that saves an agent's session in Tetrix.
    static let save = "save_session"

    var total: Int { calls.values.reduce(0, +) }
    var used: Bool { total > 0 }
    var saved: Bool { (calls[Self.save] ?? 0) > 0 }

    /// `seen` noted: a call means Tetrix was connected, whatever the start said.
    func noting(_ seen: Seen) -> TetrixUse {
        var use = self
        switch seen {
        case .connected(let on): use.connected = on || use.used
        case .call(let tool):
            use.calls[tool, default: 0] += 1
            use.connected = true
        }
        return use
    }

    /// A round ended: what it called is kept, for the next round's reminder.
    mutating func endRound() {
        rounds = (rounds ?? []) + [total - (rounds ?? []).reduce(0, +)]
    }

    // MARK: What the tools say

    /// Tetrix's tool in an MCP tool name, `mcp__<server>__<tool>`, where the server's name holds
    /// "tetrix" (`tetrix`, `tetrix-main`, `claude_ai_Tetrix`), or nil for any other tool.
    static func tool(_ name: String) -> String? {
        let parts = name.components(separatedBy: "__")
        guard parts.count == 3, parts[0] == "mcp" else { return nil }
        return tool(server: parts[1], tool: parts[2])
    }

    /// A tool of an MCP server whose name holds "tetrix", as Codex names them apart, or nil.
    static func tool(server: String, tool: String) -> String? {
        guard server.lowercased().contains("tetrix"), tool.wholeMatch(of: /[A-Za-z0-9_\-]{1,64}/) != nil else { return nil }
        return tool
    }

    /// Claude Code's `init`: its `mcp_servers`, each `{"name": "tetrix", "status": "connected"}`
    /// (or `failed`, `needs-auth`, `pending`). Nothing when it lists none at all.
    static func claudeInit(_ message: [String: Any]) -> [Seen] {
        guard let servers = message["mcp_servers"] as? [[String: Any]] else { return [] }
        return [.connected(servers.contains { ($0["name"] as? String)?.lowercased().contains("tetrix") == true && $0["status"] as? String == "connected" })]
    }

    /// Codex's `mcpServerStatus/list`: `{"data": [{"name": "tetrix", "tools": {…}, "authStatus": "oAuth"}, …]}`.
    /// Connected when a server named for Tetrix offers tools and isn't signed out; nil when the
    /// answer has no list (an older Codex).
    static func codexStatus(_ result: [String: Any]) -> Bool? {
        guard let servers = result["data"] as? [[String: Any]] else { return nil }
        return servers.contains { server in
            guard (server["name"] as? String)?.lowercased().contains("tetrix") == true,
                  server["authStatus"] as? String != "notLoggedIn" else { return false }
            return !((server["tools"] as? [String: Any]) ?? [:]).isEmpty
        }
    }

    /// `claude mcp list`: one line per server, like `tetrix: https://… (HTTP) - ✓ Connected`
    /// (else `✗ Failed to connect`, `⚠ Needs authentication`).
    static func claudeList(_ output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased().contains("tetrix") else { return false }
            return line.contains("✓") || line.lowercased().hasSuffix(" connected")
        }
    }

    /// `cursor-agent mcp list`: a line for the tetrix server that says it's ready or connected.
    // ponytail: Cursor's list format isn't recorded yet (docs/cursor.md); this reads a line that names
    // tetrix and says it's ready, connected or ✓, and not one that says it needs a login.
    static func cursorList(_ output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let lower = line.lowercased()
            guard lower.contains("tetrix"), !lower.contains("not "), !lower.contains("needs"), !lower.contains("error"),
                  !lower.contains("failed"), !lower.contains("disabled") else { return false }
            return line.contains("✓") || lower.contains("ready") || lower.contains("connected") || lower.contains("enabled")
        }
    }

    // MARK: Commits

    /// The job's commits since `since` and their `Tetrix-Session:` trailers, or nil when git can't say.
    static func stamps(worktree: URL, since: String) async -> Stamps? {
        guard FileManager.default.fileExists(atPath: worktree.path),
              let log = try? await Shell.ok(["git", "-C", worktree.path, "log", "--format=%x1e%(trailers:key=\(trailer),valueonly,separator=%x1f)", "\(since)..HEAD"])
        else { return nil }
        return stamps(log)
    }

    /// What `stamps` reads: each commit starts with U+001E, its sessions apart by U+001F.
    static func stamps(_ log: String) -> Stamps {
        let commits = log.split(separator: "\u{1e}", omittingEmptySubsequences: false).dropFirst()
        var sessions: [String] = []
        var stamped = 0
        for commit in commits {
            let named = commit.split(whereSeparator: { $0 == "\u{1f}" || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.wholeMatch(of: /[A-Za-z0-9._:\-]{1,80}/) != nil }
            if !named.isEmpty { stamped += 1 }
            for session in named where !sessions.contains(session) { sessions.append(session) }
        }
        return Stamps(commits: commits.count, stamped: stamped, sessions: sessions)
    }

    // MARK: What agents are told

    /// What the job is about, as the agent asks Tetrix: "issue #130 in deskree-inc/oby".
    static func subject(_ job: Job) -> String {
        if let pr = job.pr { return "pull request #\(pr) in \(job.repo)" }
        if let issue = job.issue { return "issue #\(issue) in \(job.repo)" }
        return "this work in \(job.repo)"
    }

    /// Tetrix first, then its session saved and the commits stamped.
    static func agentLines(_ job: Job) -> [String] {
        let commits = Job.committing.contains(job.kind)
        return [
            "Tetrix first: if the tetrix MCP server is connected, start by asking it about \(subject(job)) and the area it touches, before you read many files: search_entities to find it and what's related (pull requests, commits, owners, past sessions and decisions), get_entity for the details, and code_impact on the files you expect to change where the repository's code is indexed. Ask it again for questions about code structure, ownership and impact: it saves tokens.",
            sessionsLine(job),
            commits
                ? "When it's connected, end by calling Tetrix's save_session with what you did, decided and left open, and stamp your commits with the session it returns: a trailer `\(trailer): <id>` in the commit message (git commit --trailer \"\(trailer): <id>\"), so save it before your last commit, or amend that commit. Oby checks both and notes them in the job's report."
                : "When it's connected, end by calling Tetrix's save_session with what you found and decided. Oby checks it and notes it in the job's report.",
        ]
    }

    /// Earlier sessions' digests (#214): what agents before this one decided, learned and left open
    /// on the same work, read before starting so it isn't investigated or got wrong again.
    static func sessionsLine(_ job: Job) -> String {
        "Before you start, also read in Tetrix what earlier sessions on \(subject(job)) left: repo_sessions on it (and on the files you expect to change) lists the sessions that worked on it, session_context shows what one touched, and session_digest reads its decisions, lessons and open items. Build on them instead of redoing their investigation, and say in your summary where you depart from one."
    }

    /// Oby's review: the reviewer asks Tetrix too, hears what Oby saw of the author's use of it,
    /// and flags a change that ignores what Tetrix knew.
    static func reviewLines(_ job: Job) -> [String] {
        var lines = ["Tetrix first: if the tetrix MCP server is connected, start by asking it about \(subject(job)) and the area it touches, before you read many files: search_entities, get_entity, and code_impact where the repository's code is indexed, and repo_sessions and session_digest for what earlier sessions on it decided. A change that ignores what Tetrix knew (an owner, a past decision, a related pull request, a known impact) is a finding: say so. End by calling save_session with what you found."]
        if let author = job.tetrix?.author { lines.append("What Oby saw of the author's agent and Tetrix: \(author)") }
        return lines
    }

    /// The next round's message, with one reminder when the round that just ended had Tetrix
    /// connected and didn't use it. Once a job: `job` notes it.
    static func remind(_ job: inout Job, _ message: String) -> String {
        guard let use = job.tetrix, use.connected == true, use.reminded != true, use.rounds?.last == 0 else { return message }
        job.tetrix?.reminded = true
        return message + "\n\nTetrix is connected and your last round didn't use it. Ask it about \(subject(job)) and the area you're changing (search_entities, get_entity, code_impact) before you read more files, and end with save_session"
            + (Job.committing.contains(job.kind) ? " and the `\(trailer):` trailer on your commits." : ".")
    }

    // MARK: What Oby reports

    /// The job report's line, like "Tetrix: 6 calls (search_entities 3, get_entity 2, save_session 1).
    /// Session saved. 2 of 2 commits stamped Tetrix-Session (s-1)." Nil when the tool never said.
    static func report(_ job: Job) -> String? { facts(job).map { "Tetrix: " + $0 } }

    /// The report's line without its label, as the reviewer hears it.
    static func facts(_ job: Job) -> String? {
        guard let use = job.tetrix, use.connected != nil || use.used else { return nil }
        guard use.used else {
            return use.connected == true ? "connected, but the agent didn't use it."
                : "not connected for this account's agent, so it wasn't asked. Settings shows how to sign it in."
        }
        let tools = use.calls.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { "\($0.key) \($0.value)" }
        var parts = ["\(use.total) call\(use.total == 1 ? "" : "s") (\(tools.joined(separator: ", ")))."]
        parts.append(use.saved ? "Session saved." : "No session saved.")
        if let stamps = use.stamps, stamps.commits > 0 {
            let sessions = stamps.sessions.isEmpty ? "" : " (\(stamps.sessions.prefix(3).joined(separator: ", ")))"
            parts.append("\(stamps.stamped) of \(stamps.commits) commit\(stamps.commits == 1 ? "" : "s") stamped \(trailer)\(sessions).")
        }
        return parts.joined(separator: " ")
    }

    /// Of an account's recent jobs that ended and whose tool said what it had: how many there are,
    /// and how many used Tetrix.
    static func share(_ jobs: [Job], account: String) -> (jobs: Int, used: Int) {
        let known = jobs.filter { !$0.isActive && $0.account == account && $0.tetrix.map { $0.connected != nil || $0.used } == true }
        return (known.count, known.filter { $0.tetrix?.used == true }.count)
    }

    /// What Terminal runs to sign an account's agents in to Tetrix: the tool's own login for its
    /// `tetrix` MCP server, never Oby holding the token.
    static func signInScript(for account: Account) -> String {
        let quote = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        let (variable, steps) = switch account.agent {
        case "codex":
            ("CODEX_HOME", """
                echo 'If Codex has no tetrix server yet, add it first: codex mcp add tetrix --url <Tetrix MCP URL>'
                codex mcp login tetrix --scopes graph:read,hitl:write,sessions:write,offline_access
                """)
        case "cursor":
            ("CURSOR_CONFIG_DIR", """
                echo 'If Cursor has no tetrix server yet, add it first in <this account>/mcp.json, then sign in:'
                cursor-agent mcp login tetrix
                """)
        default:
            ("CLAUDE_CONFIG_DIR", """
                echo 'In Claude Code, type /mcp, choose tetrix and Authenticate, then /exit.'
                echo 'If tetrix is not listed, add it first: claude mcp add --scope user --transport http tetrix <Tetrix MCP URL>'
                claude
                """)
        }
        // Cursor's login is a file under XDG_CONFIG_HOME: the account's own takes its HOME too.
        let own = account.agent == "cursor" ? account.home.map { "\nexport XDG_CONFIG_HOME=\(quote($0 + "/.config"))\nexport HOME=\(quote($0))" } ?? "" : ""
        return """
        #!/bin/sh
        \(account.home.map { "export \(variable)=\(quote($0))" } ?? "unset \(variable)")\(own)
        echo \(quote("Oby: sign \(account.name)'s agents in to Tetrix."))
        \(steps)
        echo
        echo 'Done? Go back to Oby. You can close this window.'

        """
    }
}

extension Desk {
    /// The job's commits since it started, and the Tetrix sessions they're stamped with, for its
    /// report: read once its last round ended, when its agent had Tetrix.
    func noteTetrixStamps(_ id: String) async {
        guard let job = job(id), let use = job.tetrix, use.connected == true || use.used, let since = job.startCommit else { return }
        let stamps = await readStamps(id, since)
        guard let stamps, var latest = self.job(id), latest.isActive else { return }
        latest.tetrix?.stamps = stamps
        replace(latest, save: false)
    }
}
