import Foundation

/// Where the user moves a job (`Desk.move`, `POST /v1/jobs/{id}/move`): a tool, an account and a
/// model, each nil to keep the job's or let Oby pick. `account` is an account's id or its name;
/// `model` is a model's id, or `Moves.toolDefault` for the tool's own from Settings › Models.
nonisolated struct MoveTarget: Codable, Equatable, Sendable {
    var agent: String?
    var account: String?
    var model: String?

    init(agent: String? = nil, account: String? = nil, model: String? = nil) {
        self.agent = agent
        self.account = account
        self.model = model
    }
}

/// Moving a job to another tool, account or model (issue #118). Swift decides where it goes:
/// the brain and the apps only say what the user asked for.
nonisolated enum Moves {
    /// The model `MoveTarget.model` names to drop the job's own and run the tool's from Settings › Models.
    static let toolDefault = "default"
    /// The tools that run jobs.
    static let agents = ["claude", "codex", "cursor"]

    /// The models a job can move to, by tool: every Claude Code model, Codex's from Settings ›
    /// Models and its strongest, and Cursor's from Settings › Models. Codex and Cursor have more;
    /// the runner lists them (`/v1/settings/models/options`).
    static var models: [String: [String]] {
        var codex = [AgentModels.value("codex", "model")]
        if let stronger = AgentModels.stronger["codex"], !codex.contains(stronger) { codex.append(stronger) }
        let cursor = AgentModels.value("cursor", "model")
        return ["claude": AgentModels.claude.map(\.0), "codex": codex.filter { !$0.isEmpty },
                "cursor": cursor.isEmpty || cursor == "auto" ? [] : [cursor]]
    }

    /// The tool a model belongs to: Claude Code's start with "claude-". Of the rest, the tool whose
    /// list (`known`: each tool's model ids) has it; one both Codex and Cursor list needs the tool
    /// named ("Say which tool: Codex or Cursor"). A model no list has is Codex's, as it was before
    /// Cursor ran jobs.
    static func tool(ofModel model: String, among known: [String: [String]]) throws -> String {
        if model.hasPrefix("claude-") { return "claude" }
        let tools = ["codex", "cursor"].filter { known[$0]?.contains(model) == true }
        if tools.count > 1 { throw Shell.Failure(message: "Say which tool: Codex or Cursor") }
        return tools.first ?? "codex"
    }

    /// The tool a model belongs to without a list to look it up in: Claude Code's start with
    /// "claude-", the rest are Codex's.
    static func agent(ofModel model: String) -> String { model.hasPrefix("claude-") ? "claude" : "codex" }

    /// "Claude Code · Personal", with " · Fable 5.1" when the job runs a model of its own.
    static func place(_ job: Job, accounts: [AccountState]) -> String {
        let heading = accounts.first { $0.account.id == job.account }?.account.heading ?? job.agentName
        return heading + (job.model.map { " · " + AgentModels.name($0) } ?? "")
    }

    /// The account and model `job` moves to, or why it can't. Each part of `target` the user left
    /// out stays as it is or follows from the rest: a model names its tool, an account its tool too.
    /// The account named must be signed in and not stopped at its limit; otherwise Oby keeps the
    /// job's own when the tool stays, or picks one of the tool's accounts under `room` the way it
    /// picks for any job (`AccountStore.choose`).
    /// `known`: the models each tool offers (`Moves.models`, and the lists the runner loaded), which
    /// tell whose a model is when the user named no tool.
    static func choose(_ job: Job, to target: MoveTarget, accounts: [AccountState], now: Date = .now,
                       known: [String: [String]] = Moves.models) throws -> (account: Account, model: String?) {
        let clean = { (value: String?) -> String? in
            value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 }
        }
        let wanted = clean(target.agent), named = clean(target.account), model = clean(target.model)
        guard wanted != nil || named != nil || model != nil else {
            throw Shell.Failure(message: "Say where to move it: a tool, an account or a model.")
        }
        if let wanted, !agents.contains(wanted) { throw Shell.Failure(message: "\(Job.agentNames[wanted] ?? wanted) can't run jobs.") }
        let chosenModel = model == toolDefault ? nil : model
        // The model's tool: the one named when Codex's and Cursor's lists both have it (Cursor lists
        // ids like gpt-5 too), else the one whose list has it.
        var modelTool: String?
        if let model = chosenModel {
            guard model.count <= 100, model.wholeMatch(of: /[A-Za-z0-9._-]+/) != nil else { throw Shell.Failure(message: "That isn't a model.") }
            let both = !model.hasPrefix("claude-") && ["codex", "cursor"].allSatisfy { known[$0]?.contains(model) == true }
            // A named account's tool says it as well as a named tool does.
            let said = wanted ?? named.flatMap { name in
                accounts.first { $0.account.id == name || $0.account.name.caseInsensitiveCompare(name) == .orderedSame }?.account.agent
            }
            if both, let said, ["codex", "cursor"].contains(said) {
                modelTool = said
            } else {
                modelTool = try tool(ofModel: model, among: known)
            }
            if modelTool == "claude", !AgentModels.claude.contains(where: { $0.0 == model }) {
                throw Shell.Failure(message: "Claude Code has no model \(model).")
            }
            if let wanted, modelTool != wanted {
                throw Shell.Failure(message: "\(AgentModels.name(model)) is a \(Job.agentNames[modelTool ?? ""] ?? "") model, not \(Job.agentNames[wanted] ?? wanted)'s.")
            }
        }
        // The account the user named, by id or by name (of the tool they named, if any).
        var account: Account?
        if let named {
            let tool = wanted ?? modelTool
            let matches = accounts.filter { $0.account.id == named || $0.account.name.caseInsensitiveCompare(named) == .orderedSame }
            guard let state = matches.first(where: { tool == nil || $0.account.agent == tool }) ?? matches.first else {
                throw Shell.Failure(message: "There's no account called \(named).")
            }
            if let tool, state.account.agent != tool {
                throw Shell.Failure(message: "\(state.account.name) is a \(Job.agentNames[state.account.agent] ?? state.account.agent) account, not \(Job.agentNames[tool] ?? tool)'s.")
            }
            guard state.signedIn else { throw Shell.Failure(message: "\(state.account.heading) isn't signed in. Sign in from Settings › Accounts.") }
            if state.isFull(at: now), let until = state.fullUntil {
                throw Shell.Failure(message: "\(state.account.heading) hit its usage limit; it resets at \(Limits.clock(until)).")
            }
            account = state.account
        }
        let tool = account?.agent ?? wanted ?? modelTool ?? job.agent
        if account == nil {
            if tool == job.agent, let own = accounts.first(where: { $0.account.id == job.account }),
               (model != nil && own.signedIn && !own.isFull(at: now) && !own.weekNearlyFull(at: now))
                   || AccountStore.choose([own], agent: tool, now: now) != nil {
                account = own.account
            }
        }
        if account == nil {
            // A move without an account follows the same routing rule as new work, including the
            // 95% ceiling that still applies when a weekly reserve was lifted (#323).
            account = AccountStore.route(accounts, agent: tool, now: now)
        }
        if account == nil, wanted != nil {
            // The user named the tool ("put them on Codex"): that names its accounts too, however
            // busy, the least busy first, as long as one isn't stopped at its limit (2026-10-12).
            account = accounts.filter { $0.signedIn && $0.account.agent == tool && !$0.isFull(at: now) }
                .min { ($0.fiveHour ?? 0) < ($1.fiveHour ?? 0) }?.account
        }
        guard let account else {
            let name = Job.agentNames[tool] ?? tool
            throw Shell.Failure(message: "No \(name) account has room: each is signed out, stopped at its limit, or past 80% of its 5-hour or weekly limit. Name one to use it anyway.")
        }
        // The model: the one named; the job's own on the same tool; on another, its strongest when
        // the job ran the strongest, else the tool's from Settings › Models.
        let next: String?
        if model != nil {
            next = chosenModel
        } else if account.agent == job.agent {
            next = job.model
        } else {
            next = job.model != nil && job.model == AgentModels.stronger[job.agent] ? AgentModels.stronger[account.agent] : nil
        }
        if account.id == job.account, next == job.model {
            throw Shell.Failure(message: "It's on \(place(job, accounts: accounts)) already.")
        }
        return (account, next)
    }

    /// What Oby says once a job moved: where from and to, and when its work goes on there.
    static func reply(_ job: Job) -> String {
        let moved = job.moves?.last.map { "Moved \(job.heading) from \($0.from) to \($0.to)." } ?? "Moved \(job.heading)."
        switch job.status {
        case .running: return moved + " It goes on there now."
        case .queued: return moved + " It starts there."
        default: return moved + " Its next round runs there: tell it something, or Try again."
        }
    }
}
