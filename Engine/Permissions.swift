import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// How much a job asks the user (#134), like Claude Code's modes. Whatever the mode, Policy's fixed
/// denials come first (no publishing, the worktree only, no background work, only Tetrix's reads
/// among MCP tools), then the user's saved rules (deny beats allow), then the mode allows or asks.
/// Reads and Oby's bookkeeping never ask. Oby never launches Claude Code with its own bypass flag:
/// it answers every prompt itself, so the fixed rules hold in Bypass too.
nonisolated enum PermissionMode: String, Codable, CaseIterable, Sendable {
    /// Every command and file edit waits for the user.
    case ask
    /// Edits inside the worktree go through; commands ask.
    case acceptEdits
    /// The agent only reads, then its plan waits for approval.
    case plan
    /// Oby answers everything by its rules, as before modes: the default.
    case bypass

    /// "Accept edits", as cards and replies say it.
    var title: String {
        switch self {
        case .ask: "Ask"
        case .acceptEdits: "Accept edits"
        case .plan: "Plan"
        case .bypass: "Bypass"
        }
    }

    /// The mode a card or a person names: "acceptEdits", "Accept edits", "bypass".
    init?(named name: String) {
        let plain = name.lowercased().filter(\.isLetter)
        guard let mode = Self.allCases.first(where: { $0.rawValue.lowercased() == plain || $0.title.lowercased().filter(\.isLetter) == plain }) else { return nil }
        self = mode
    }
}

/// How the user answers a waiting permission: once, always (a rule for the repository), or no.
nonisolated enum PermissionDecision: String, Codable, CaseIterable, Sendable { case allow, always, deny }

/// A tool call an agent asks about, as Oby reads it: Claude Code's `can_use_tool`, or Codex's approval.
nonisolated struct ToolCall: Equatable, Sendable {
    /// The agent's own id for the prompt: what its answer goes back with.
    var request: String
    /// Claude Code's tool name; Codex's commands are "Bash" and its file changes "Edit".
    var tool: String
    var command: String?
    /// The files it writes, as the agent named them.
    var paths: [String] = []
    /// What ExitPlanMode brings: the agent's plan.
    var plan: String?
    var url: String?

    /// Claude Code's input, read.
    static func claude(_ request: String, tool: String, input: [String: Any]) -> ToolCall {
        ToolCall(request: request, tool: tool, command: input["command"] as? String,
                 paths: [input["file_path"] ?? input["notebook_path"]].compactMap { $0 as? String },
                 plan: tool == "ExitPlanMode" ? input["plan"] as? String ?? "" : nil, url: input["url"] as? String)
    }
}

/// What Oby answers an agent's prompt with.
nonisolated enum ToolAnswer: Equatable, Sendable {
    case allow
    /// Allowed, and not asked again in this session (Claude Code's `updatedPermissions`, Codex's `acceptForSession`).
    case always
    /// No, with the words for the agent.
    case deny(String)
}

/// A permission prompt waiting for the user (`Job.permission`): what the agent wants to do, the rule
/// "always" would save, and how the card says it.
nonisolated struct Permission: Codable, Equatable, Sendable {
    var id: String
    var tool: String
    /// "Run swift test".
    var title: String
    /// The whole command, the files, or the address.
    var detail: String
    /// The rule "always" saves, like "Bash(swift test:*)", or nil when Oby can't make a safe one
    /// (a command chained with `&&`, a pipe): then it can only be allowed once.
    var rule: String?
    /// "Yes, and don't ask again for swift test in deskree-inc/oby", or nil without a rule.
    var always: String?
}

/// A rule the user saved for a repository ("always", or #67's learned rules), in `oby.sqlite`.
nonisolated struct PermissionRule: Codable, Equatable, Identifiable, Sendable {
    enum Decision: String, Codable, Sendable { case allow, deny }

    var id: String
    /// Claude Code's syntax: `Bash(swift test:*)` (a command and what follows it), `Bash(make lint)`
    /// (exactly that), `Edit` (every file edit), `WebFetch` (every use of the tool).
    var rule: String
    var repo: String
    var decision: Decision
    var created: Date
}

nonisolated enum Permissions {
    enum Verdict: Equatable { case allow, deny(String), ask }

    /// What never asks: reads, and Oby's own bookkeeping (a to-do list, a helper whose own actions ask).
    static let quiet: Set<String> = ["Read", "Grep", "Glob", "LS", "NotebookRead", "TodoWrite", "Task", "Agent"]
    /// File edits: the worktree's only (Policy), allowed in Accept edits, refused in Plan.
    static let edits: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    /// What an agent in Plan hears when it tries to change something.
    static let planOnly = "Plan mode: read only, change nothing yet. Finish with your plan; the user approves it before you go on."
    /// Tools whose second word names what they do (`swift test`, `git status`): their rules keep it.
    static let subcommands: Set<String> = ["git", "swift", "npm", "pnpm", "yarn", "bun", "npx", "cargo", "go", "make", "docker",
                                           "uv", "poetry", "bundle", "rake", "mix", "dotnet", "gradle", "./gradlew", "xcrun", "brew", "deno"]

    /// The mode's answer to a call Policy let through, after the user's saved rules for the repository.
    static func decide(_ call: ToolCall, mode: PermissionMode, rules: [PermissionRule], worktree: URL) -> Verdict {
        // Policy's fixed denials, again: the agents ask Policy first, but no mode or rule gets past them.
        let inputs: [[String: Any]] = call.paths.isEmpty ? [call.command.map { ["command": $0] } ?? [:]] : call.paths.map { ["file_path": $0] }
        if let fixed = inputs.lazy.compactMap({ Policy.deny(tool: call.tool, input: $0, worktree: worktree) }).first { return .deny(fixed) }
        // Plan's own end: the plan waits for the user in Plan, and in any other mode there's nothing to approve.
        if call.tool == "ExitPlanMode" { return mode == .plan ? .ask : .allow }
        if quiet.contains(call.tool) || call.tool.hasPrefix("mcp__") { return .allow }
        if let deny = rules.first(where: { $0.decision == .deny && matches($0.rule, call, worktree: worktree, allowing: false) }) {
            return .deny("The user's rule \(deny.rule) refuses this in \(deny.repo). Do it another way, or say in your summary what you'd have done.")
        }
        if mode == .plan, edits.contains(call.tool) { return .deny(planOnly) }
        if rules.contains(where: { $0.decision == .allow && matches($0.rule, call, worktree: worktree, allowing: true) }) { return .allow }
        switch mode {
        case .bypass: return .allow
        case .acceptEdits: return edits.contains(call.tool) ? .allow : .ask
        case .ask, .plan: return .ask
        }
    }

    // MARK: Rules

    /// Shell syntax that runs more than one command, or sends output somewhere: such a command
    /// never matches an allow rule, and gets none suggested.
    static let chained = /&&|\|\||[;|&`<>\n]|\$\(/

    /// Whether `rule` covers the call. An allow rule covers only a plain command (`allowing`); a
    /// deny rule covers a chained one when any of its commands matches.
    static func matches(_ rule: String, _ call: ToolCall, worktree: URL, allowing: Bool) -> Bool {
        let (name, content) = parse(rule)
        guard family(name) == family(call.tool) else { return false }
        guard let content else { return true }
        let (pattern, prefix) = content.hasSuffix(":*") ? (String(content.dropLast(2)), true)
            : content.hasSuffix("*") ? (String(content.dropLast()), true) : (content, false)
        let fits = { (text: String) in
            let text = text.trimmingCharacters(in: .whitespaces)
            guard prefix else { return text == pattern }
            return text == pattern || text.hasPrefix(pattern.hasSuffix("/") ? pattern : pattern + " ") || (pattern.hasSuffix("/") && text.hasPrefix(pattern))
        }
        if family(call.tool) == "Bash" {
            guard let command = call.command?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            if command.contains(chained) {
                return !allowing && command.split(separator: chained).contains { fits(String($0)) }
            }
            return fits(command)
        }
        if family(call.tool) == "Edit" {
            let files = call.paths.map { relative($0, to: worktree) }
            return !files.isEmpty && (allowing ? files.allSatisfy(fits) : files.contains(where: fits))
        }
        return fits(call.url ?? call.command ?? "")
    }

    /// "Bash(swift test:*)" is ("Bash", "swift test:*"); "Edit" is ("Edit", nil).
    static func parse(_ rule: String) -> (name: String, content: String?) {
        guard let open = rule.firstIndex(of: "("), rule.hasSuffix(")") else { return (rule, nil) }
        let content = String(rule[rule.index(after: open)..<rule.index(before: rule.endIndex)])
        return (String(rule[..<open]), content.isEmpty ? nil : content)
    }

    /// Every file-editing tool is "Edit", as Claude Code's rules read them.
    static func family(_ tool: String) -> String { edits.contains(tool) ? "Edit" : tool }

    /// A path as the worktree sees it: "Engine/Jobs.swift".
    static func relative(_ path: String, to worktree: URL) -> String {
        let root = worktree.standardizedFileURL.path + "/"
        let file = URL(filePath: path, relativeTo: worktree).standardizedFileURL.path
        return file.hasPrefix(root) ? String(file.dropFirst(root.count)) : file
    }

    /// The words a command's rule keeps: "swift test" for `swift test --filter X`, "ls" for
    /// `ls -la`; nil for a chained command or one that starts by setting a variable.
    static func prefix(of command: String) -> String? {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !command.contains(chained) else { return nil }
        let words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first, !first.contains("="), !first.contains("\""), !first.contains("'") else { return nil }
        if subcommands.contains(first), words.count > 1, words[1].wholeMatch(of: /[a-z][a-z0-9:_-]*/) != nil {
            return "\(first) \(words[1])"
        }
        return first
    }

    /// The card for a call that waits for the user, with the id it's answered by.
    static func permission(for call: ToolCall, id: String, repo: String, worktree: URL) -> Permission {
        let line = { (text: String, cap: Int) in
            let first = text.split(separator: "\n").first.map(String.init) ?? text
            return first.count > cap ? String(first.prefix(cap - 1)) + "…" : first
        }
        var title: String
        var detail = ""
        var rule: String?
        var what: String?
        switch family(call.tool) {
        case "Bash":
            let command = call.command ?? ""
            detail = String(command.prefix(2000))
            if let prefix = prefix(of: command) {
                rule = "Bash(\(prefix):*)"
                what = prefix
                title = "Run \(line(prefix, 60))"
            } else {
                title = "Run \(line(command, 60))"
            }
        case "Edit":
            let files = call.paths.map { relative($0, to: worktree) }
            detail = files.joined(separator: ", ")
            let names = files.map { URL(filePath: $0).lastPathComponent }
            title = "\(call.tool == "Write" ? "Write" : "Edit") \(names.count == 1 ? names[0] : "\(names.count) files")"
            rule = "Edit"
            what = "file edits"
        default:
            detail = call.url ?? call.command ?? ""
            title = switch call.tool {
            case "WebFetch": "Fetch \(URL(string: detail)?.host() ?? "a web page")"
            case "WebSearch": "Search the web"
            default: "Use \(call.tool)"
            }
            rule = call.tool
            what = call.tool
        }
        return Permission(id: id, tool: call.tool, title: title, detail: detail, rule: rule,
                          always: what.map { "Yes, and don't ask again for \($0) in \(repo)" })
    }

    /// A new permission's id: "p" and six letters or digits.
    static func newID() -> String { "p" + String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(6)) }

    /// What the agent hears when the user says no without words.
    static let saidNo = "The user said no. Don't do that; do the rest of the work another way, or say in your summary what you needed."

    // MARK: Plans

    /// What a plan's card offers, the recommended one first.
    static let planOptions = ["Approve: Accept edits", "Approve: Bypass", "Change it"]
    static let changeIt = "Change it"

    static func planQuestion(_ plan: String) -> Plan.Question {
        Plan.Question(text: "Approve the plan?", options: planOptions, recommended: 0, plan: String(plan.prefix(20_000)))
    }

    /// The mode a plan's answer approves it in, or nil when the answer asks for changes:
    /// "Approve: Bypass", "approve", "yes".
    static func approval(_ answer: String) -> PermissionMode? {
        let plain = answer.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if ["yes", "ok", "okay", "go", "go ahead", "approve", "approved", "approve it", "looks good"].contains(plain) { return .acceptEdits }
        guard plain.hasPrefix("approve") else { return nil }
        let named = plain.dropFirst("approve".count).trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
        return PermissionMode(named: named).flatMap { $0 == .plan ? nil : $0 } ?? .acceptEdits
    }

    /// What the agent hears when its plan, presented as its summary, is approved.
    static func approved(_ mode: PermissionMode) -> String {
        "The user approved your plan (mode: \(mode.title)). Carry it out now, then finish with a short summary as asked."
    }

    /// What the agent hears for Change it without words.
    static let changePlan = "The user wants changes to this plan. If you can't tell what to change, ask with a QUESTION line; otherwise revise it and present it again."

    /// What an agent hears about a permission it asked for before the runner restarted.
    static func later(_ permission: Permission, _ answer: ToolAnswer) -> String {
        let asked = "Before Oby restarted, you asked to \(permission.title.prefix(1).lowercased() + permission.title.dropFirst())"
            + (permission.detail.isEmpty ? "" : " (\(permission.detail))") + "."
        switch answer {
        case .allow, .always: return asked + " The user allowed it: go ahead, then finish with a short summary as asked."
        case .deny(let words): return asked + " The user said no: \(words)"
        }
    }
}

/// Settings › Permissions and the saved rules, in `oby.sqlite` next to the jobs: each machine's own,
/// and none of the tests'.
extension JobStore {
    func createPermissionTables() {
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS rules (id TEXT PRIMARY KEY, created REAL NOT NULL, body TEXT NOT NULL)", nil, nil, nil)
    }

    func setting(_ key: String) -> String? {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT value FROM settings WHERE key = ?", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    func save(setting key: String, _ value: String) {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        sqlite3_bind_text(statement, 2, value, -1, transient)
        if sqlite3_step(statement) != SQLITE_DONE { Logger.jobs.error("saving the setting \(key, privacy: .public) failed") }
    }

    func save(_ rule: PermissionRule) {
        guard let body = try? JSONEncoder().encode(rule) else { return }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO rules (id, created, body) VALUES (?, ?, ?)", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, rule.id, -1, transient)
        sqlite3_bind_double(statement, 2, rule.created.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, String(decoding: body, as: UTF8.self), -1, transient)
        if sqlite3_step(statement) != SQLITE_DONE { Logger.jobs.error("saving rule \(rule.id, privacy: .public) failed") }
    }

    /// Every saved rule, oldest first.
    func rules() -> [PermissionRule] {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT body FROM rules ORDER BY created, rowid", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var rules: [PermissionRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0),
               let rule = try? JSONDecoder().decode(PermissionRule.self, from: Data(String(cString: text).utf8)) {
                rules.append(rule)
            }
        }
        return rules
    }

    /// Removes a rule; false when there was none with that id.
    func delete(rule id: String) -> Bool {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM rules WHERE id = ?", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(statement)
        return sqlite3_changes(db) > 0
    }
}

// MARK: The desk

/// Waiting permissions work like waiting questions: the job stays running, its agent idle, its
/// clocks paused; the inbox has it and alerts the phone and the Watch; other jobs go on; stopping
/// the job drops it, and a restart leaves the job interrupted, keeping it.
extension Desk {
    /// One prompt waiting for the user: the agent's call, and its card.
    struct Ask {
        var call: ToolCall
        var permission: Permission
    }

    static let modeKey = "permissions.mode"

    /// Settings › Permissions: the mode new jobs get, in this machine's `oby.sqlite`. Bypass, as
    /// before modes, until the user picks another.
    var defaultMode: PermissionMode {
        get { store.setting(Self.modeKey).flatMap(PermissionMode.init(rawValue:)) ?? .bypass }
        set { store.save(setting: Self.modeKey, newValue.rawValue) }
    }

    /// Every saved rule, oldest first, and the ones for one repository.
    var permissionRules: [PermissionRule] { store.rules() }
    func rules(for repo: String) -> [PermissionRule] { store.rules().filter { $0.repo == repo } }

    /// Saves a rule for a repository, once: the same rule twice is the one saved before.
    @discardableResult
    func saveRule(_ rule: String, repo: String, decision: PermissionRule.Decision = .allow) -> PermissionRule {
        if let same = store.rules().first(where: { $0.rule == rule && $0.repo == repo && $0.decision == decision }) { return same }
        let saved = PermissionRule(id: "r" + String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(8)), rule: rule, repo: repo,
                                   decision: decision, created: .now)
        store.save(saved)
        // Prompts waiting now, in any job, follow it too.
        for id in asks.keys { reconsider(id) }
        return saved
    }

    func forgetRule(_ id: String) throws {
        guard store.delete(rule: id) else { throw Shell.Failure(message: "There's no rule \(id).") }
    }

    /// A prompt Policy let through: the job's mode and the repository's rules allow or refuse it
    /// now, or it waits for the user.
    func ask(_ call: ToolCall, job: Job) {
        let id = job.id
        let worktree = Workspace.worktree(id)
        switch Permissions.decide(call, mode: job.currentMode, rules: rules(for: job.repo), worktree: worktree) {
        case .allow:
            tally(id, denied: nil)
            agents[id]?.answer(call, .allow)
        case .deny(let why):
            Logger.jobs.notice("denied \(call.tool, privacy: .public) in job \(id, privacy: .public): \(why, privacy: .public)")
            agents[id]?.answer(call, .deny(why))
            tally(id, denied: why)
        case .ask:
            let permission = Permissions.permission(for: call, id: Permissions.newID(), repo: job.repo, worktree: worktree)
            asks[id, default: []].append(Ask(call: call, permission: permission))
            if asks[id]?.count == 1 { show(id) }
        }
    }

    /// The job shows its first waiting prompt (a permission, or a plan as its question), its clocks
    /// paused; with none left, it goes on, its step saying what happened.
    func show(_ id: String, step: String? = nil) {
        guard var job = job(id), job.isActive else { return }
        if let first = asks[id]?.first {
            if let plan = first.call.plan {
                job.question = Permissions.planQuestion(plan)
                job.permission = nil
                job.step = "Waiting for your OK on the plan"
            } else {
                job.permission = first.permission
                job.step = "Waiting for your OK"
            }
            pauseClocks(id)
        } else {
            job.permission = nil
            if let step { job.step = step }
            resumeClocks(id)
        }
        replace(job)
    }

    /// The job's waiting prompts after its mode or the rules changed: what's allowed or refused
    /// now is answered, the rest keep waiting. A plan waits for its own answer.
    func reconsider(_ id: String) {
        guard let job = job(id), job.isActive, let waiting = asks[id], !waiting.isEmpty else { return }
        let rules = rules(for: job.repo)
        var kept: [Ask] = []
        var answered: String?
        for ask in waiting {
            guard ask.call.plan == nil else { kept.append(ask); continue }
            switch Permissions.decide(ask.call, mode: job.currentMode, rules: rules, worktree: Workspace.worktree(id)) {
            case .allow:
                agents[id]?.answer(ask.call, .allow)
                answered = answered ?? "Allowed: \(ask.permission.title)"
            case .deny(let why):
                agents[id]?.answer(ask.call, .deny(why))
                answered = answered ?? "Refused: \(ask.permission.title)"
            case .ask:
                kept.append(ask)
            }
        }
        guard kept.count != waiting.count else { return }
        asks[id] = kept
        show(id, step: answered)
    }

    /// The user answers a waiting permission: allow it once, always (a rule for the repository,
    /// and the agent's own for its session), or no, with their words for the agent. A permission
    /// kept from before a restart picks the job's session up again with the answer.
    func answerPermission(_ id: String, _ permissionID: String, _ decision: PermissionDecision, message: String? = nil) throws {
        guard let job = job(id) else { throw Shell.Failure(message: "There's no job \(id).") }
        let words = message.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        guard (words?.count ?? 0) <= 2000 else { throw Shell.Failure(message: "Tell the agent something of up to 2,000 characters.") }
        let said = switch decision {
        case .allow: Inbox.allow
        case .always: Inbox.alwaysAllow
        case .deny: words ?? Inbox.deny
        }
        guard let ask = asks[id]?.first, job.isActive else {
            guard let permission = job.permission, permission.id == permissionID else {
                throw Shell.Failure(message: "That permission isn't waiting any more.")
            }
            if decision == .always {
                guard let rule = permission.rule else { throw Shell.Failure(message: "This one has no rule to save: allow it once instead.") }
                saveRule(rule, repo: job.repo)
            }
            let answer: ToolAnswer = decision == .deny ? .deny(words ?? Permissions.saidNo) : .allow
            return try tell(id, said, agentText: Permissions.later(permission, answer))
        }
        guard ask.call.plan == nil, ask.permission.id == permissionID else { throw Shell.Failure(message: "That permission isn't waiting any more.") }
        var answer = ToolAnswer.allow
        switch decision {
        case .allow: break
        case .always:
            guard ask.permission.rule != nil else { throw Shell.Failure(message: "This one has no rule to save: allow it once instead.") }
            answer = .always
        case .deny: answer = .deny(words ?? Permissions.saidNo)
        }
        asks[id]?.removeFirst()
        agents[id]?.answer(ask.call, answer)
        if decision != .deny { tally(id, denied: nil) }
        if var noted = self.job(id), words != nil {
            noted.notes = (noted.notes ?? []) + [said]
            replace(noted, save: false)
        }
        // Saving the rule answers the job's other prompts it covers, and other jobs' in the repository.
        if decision == .always, let rule = ask.permission.rule { saveRule(rule, repo: job.repo) }
        show(id, step: decision == .deny ? "You said no: \(ask.permission.title)" : "Allowed: \(ask.permission.title)")
    }

    /// The job's mode changes: Claude Code's session or Codex's next turn follows, and the prompts
    /// waiting now that the new mode allows are answered. A plan waiting for approval is approved
    /// in the new mode.
    @discardableResult
    func setMode(_ id: String, _ mode: PermissionMode) throws -> Job {
        guard var job = job(id) else { throw Shell.Failure(message: "There's no job \(id).") }
        if job.question?.plan != nil, mode != .plan {
            try approvePlan(id, mode)
            return self.job(id) ?? job
        }
        job.mode = mode
        replace(job)
        agents[id]?.setMode(mode)
        reconsider(id)
        return self.job(id) ?? job
    }

    /// The user's answer to a plan: an approval in a mode ("Approve: Accept edits"), or words for
    /// changes, which reach the agent (Change it alone asks it to revise).
    func answerPlan(_ id: String, _ text: String) throws {
        if let mode = Permissions.approval(text) { return try approvePlan(id, mode, said: text) }
        let words = text == Permissions.changeIt ? Permissions.changePlan : text
        if let ask = asks[id]?.first, ask.call.plan != nil, var job = job(id), job.isActive {
            asks[id]?.removeFirst()
            job.question = nil
            job.notes = (job.notes ?? []) + [text]
            replace(job)
            agents[id]?.answer(ask.call, .deny(words))
            return show(id, step: "You: \(text)")
        }
        try tell(id, text, agentText: words)
    }

    /// The plan is approved: the job takes `mode`, and its agent carries the plan out. Claude Code's
    /// waiting ExitPlanMode is allowed; a plan given as a turn's summary gets the go-ahead as the
    /// next message (or picks the session up again, after a restart).
    func approvePlan(_ id: String, _ mode: PermissionMode, said: String? = nil) throws {
        guard var job = job(id), job.question?.plan != nil else { throw Shell.Failure(message: "There's no plan waiting for approval.") }
        let said = said ?? "Approve: \(mode.title)"
        job.mode = mode
        if let ask = asks[id]?.first, ask.call.plan != nil, job.isActive, let agent = agents[id] {
            job.question = nil
            job.notes = (job.notes ?? []) + [said]
            replace(job)
            asks[id]?.removeFirst()
            agent.setMode(mode)
            agent.answer(ask.call, .allow)
            reconsider(id)
            return show(id, step: "Plan approved: \(mode.title)")
        }
        replace(job)
        agents[id]?.setMode(mode)
        try tell(id, said, agentText: Permissions.approved(mode))
    }

    /// What the brain's answer_permission and set_mode do, here or elsewhere, and what Oby says.
    /// Agents' words stay out of the reply: it joins the conversation the brain reads.
    func act(on plan: Plan) async -> String {
        let named = plan.jobs ?? []
        let others = Dictionary(elsewhere().flatMap(\.jobs).map { ($0.id, $0) }) { first, _ in first }
        switch plan.action {
        case .answerPermission:
            guard let id = named.first, let decision = plan.decision else { return "Say which job to answer." }
            let message = plan.message.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            let said = { (job: Job) -> String in
                switch decision {
                case .allow: "Allowed it for \(job.heading)."
                case .always: "Allowed it for \(job.heading), and saved the rule for \(job.repoName): it won't ask again for that."
                case .deny: "Told \(job.heading) no" + (message == nil ? "." : ", with your words.")
                }
            }
            if let job = job(id) {
                do {
                    if job.question?.plan != nil {
                        if decision == .deny { try answerPlan(id, message ?? Permissions.changeIt); return "Sent \(job.heading)'s plan back." }
                        try approvePlan(id, .acceptEdits)
                        return "Approved \(job.heading)'s plan: it goes on in Accept edits."
                    }
                    guard let permission = job.permission ?? asks[id]?.first?.permission else { return "\(job.heading) isn't waiting for your OK." }
                    try answerPermission(id, permission.id, decision, message: message)
                    return said(job)
                } catch {
                    return error.localizedDescription
                }
            }
            guard let job = others[id] else { return "That job isn't waiting for your OK any more." }
            if let why = await answerElsewhere(job, decision, message) { return "Couldn't answer \(job.heading): \(why)" }
            return said(job)
        case .setMode:
            guard let mode = plan.mode else { return "Say which mode." }
            var done: [String] = []
            var failed: [String] = []
            for id in named {
                if job(id) != nil {
                    do { done.append(try setMode(id, mode).heading) } catch { failed.append(error.localizedDescription) }
                } else if let job = others[id] {
                    if let why = await modeElsewhere(job, mode) { failed.append("Couldn't change \(job.heading): \(why)") } else { done.append(job.heading) }
                }
            }
            var reply = done.isEmpty ? "" : "\(done.joined(separator: ", ")) \(done.count == 1 ? "is" : "are") in \(mode.title) mode now."
            for line in failed { reply += (reply.isEmpty ? "" : " ") + line }
            return reply.isEmpty ? "That job isn't running any more." : reply
        default:
            return ""
        }
    }
}
