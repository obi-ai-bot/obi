import Foundation
import Observation

/// Oby's desk: the conversation that turns words into a plan, and the jobs it dispatched.
@Observable
final class Desk {
    enum Talk: Equatable {
        case none
        case thinking(String)
        case plan(Draft)
        case reply(String)
        case question(said: String, Plan.Question)
    }

    /// A plan on the card, before the user presses Dispatch.
    struct Draft: Equatable {
        var said: String
        var reply: String
        var job: Job
        /// Made by rules because the brain didn't answer.
        var guessed: Bool
    }

    var talk: Talk = .none
    private(set) var jobs: [Job] {
        didSet { accounts.countRunning(jobs) }
    }
    let accounts: AccountStore
    /// Called when a job ends, for the notch's one line.
    var onFinish: (Job) -> Void = { _ in }
    /// Called with every job that's added or changes, for the runner's event stream.
    var onJobChange: (Job) -> Void = { _ in }

    private let store: JobStore
    private var repos: [String] = []
    /// The latest plans until they're dispatched: the runner's API dispatches them by job id.
    private var drafts: [Draft] = []
    private var agents: [String: any AgentRun] = [:]
    /// Setting up worktrees in the same clone one at a time keeps git's locks out of the way.
    private var setups: [String: Task<Void, Never>] = [:]

    init(accounts: AccountStore = AccountStore(), store: JobStore = JobStore(url: Workspace.root.appending(path: "oby.sqlite"))) {
        self.accounts = accounts
        self.store = store
        jobs = store.recent()
        // Running when Oby last quit (or crashed): it didn't finish.
        for index in jobs.indices where jobs[index].isActive {
            jobs[index].status = .interrupted
            jobs[index].finished = jobs[index].finished ?? .now
            store.save(jobs[index])
        }
        accounts.countRunning(jobs)
    }

    var active: [Job] { jobs.filter(\.isActive) }

    func refresh() async {
        if let repos = try? await Workspace.knownRepos(), !repos.isEmpty { self.repos = repos }
        await accounts.refresh()
    }

    /// The brain picks "auto" or an account by name; Swift turns that into a real account.
    private var brainContext: BrainContext {
        let signedIn = accounts.accounts.filter(\.signedIn).map(\.account)
        let known = signedIn.isEmpty ? accounts.accounts.map(\.account) : signedIn
        var choices = ["auto": ["auto"] + known.map(\.name)]
        for (agent, list) in Dictionary(grouping: known, by: \.agent) { choices[agent] = ["auto"] + list.map(\.name) }
        return BrainContext(accounts: choices, repos: repos)
    }

    // MARK: Planning

    func ask(_ words: String) {
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        talk = .thinking(said)
        Task {
            let result = await plan(said)
            // Cancelled or replaced while the brain was thinking.
            guard talk == .thinking(said) else { return }
            talk = result
        }
    }

    /// What the brain makes of the user's words: a plan, a question or a reply. Takes 3–20 seconds.
    func plan(_ said: String) async -> Talk {
        if repos.isEmpty { await refresh() }
        // The brain thinks with the least busy Claude account too, so a busy one doesn't slow it.
        let brain = ClaudeBrain(home: AccountStore.route(accounts.accounts, agent: "claude")?.home)
        let talk = card(for: await Planner(adapters: [brain]).plan(said, context: brainContext), said: said)
        if case .plan(let draft) = talk {
            // ponytail: the last 20 plans, in memory; a plan made before a restart is made again.
            drafts.append(draft)
            if drafts.count > 20 { drafts.removeFirst() }
        }
        return talk
    }

    /// The user picked one of the brain's options: plan again with the answer.
    func answer(_ option: String, said: String, question: String) {
        ask(Self.answered(said, question: question, option: option))
    }

    /// The user's words with the brain's question and the option they picked, to plan again.
    nonisolated static func answered(_ said: String, question: String, option: String) -> String {
        "\(said)\n\n(Oby asked: \(question) The user answered: \(option))"
    }

    func cancel() { talk = .none }

    private func card(for result: Planner.Result, said: String) -> Talk {
        let plan = result.plan
        switch plan.action {
        case .dispatch:
            guard let dispatch = plan.dispatch else { return .none }
            let agent = dispatch.agent == "auto" ? nil : dispatch.agent
            let named = accounts.accounts.first { $0.signedIn && $0.account.name == dispatch.account && (agent == nil || $0.account.agent == agent) }
            if dispatch.account != "auto", named == nil {
                return .reply("\(dispatch.account) isn't signed in. Sign in from Settings › Accounts.")
            }
            guard let account = named?.account ?? AccountStore.route(accounts.accounts, agent: agent) else {
                let tool = agent.map { Job.agentNames[$0] ?? $0 } ?? "coding tool"
                return .reply("No \(tool) account is signed in with room to spare. Check Settings › Accounts.")
            }
            let id = String(UUID().uuidString.prefix(8)).lowercased()
            let job = Job(id: id, request: said, agent: account.agent, account: account.id, repo: dispatch.repo,
                          branch: Job.branch(kind: dispatch.kind, pr: dispatch.pr, id: id), base: dispatch.baseBranch,
                          pr: dispatch.pr, kind: dispatch.kind, task: dispatch.task)
            let reply = plan.reply.isEmpty ? "\(job.agentName) will \(dispatch.kind.rawValue) in \(job.repoName)." : plan.reply
            return .plan(Draft(said: said, reply: reply, job: job, guessed: result.by == "rules"))
        case .askUser:
            return plan.question.map { .question(said: said, $0) } ?? .reply(plan.reply)
        case .replyOnly, .stopAgent:
            return .reply(plan.reply.isEmpty ? "Stop a job with the × next to it." : plan.reply)
        case .ignore:
            return plan.reply.isEmpty ? .none : .reply(plan.reply)
        }
    }

    // MARK: Jobs

    @discardableResult
    func dispatch(_ draft: Draft) -> Job {
        talk = .none
        drafts.removeAll { $0.job.id == draft.job.id }
        var job = draft.job
        job.step = "Getting \(job.repoName) ready"
        jobs.insert(job, at: 0)
        store.save(job)
        onJobChange(job)

        let previous = setups[job.repo]
        let ready = Task { () async throws -> Job in
            await previous?.value
            return try await Workspace.prepare(job)
        }
        setups[job.repo] = Task { _ = await ready.result }
        Task {
            do {
                let prepared = try await ready.value
                // Stopped while Oby was getting the repository ready.
                guard self.job(prepared.id)?.status == .queued else { return }
                start(prepared)
            } catch {
                finish(job.id, .failed, "Couldn't get \(job.repoName) ready: \(error.localizedDescription)")
            }
        }
        return job
    }

    /// Dispatches one of the latest plans, by its job's id, with the user's changes (the runner's API).
    func dispatch(_ id: String, branch: String, account: String) throws -> Job {
        guard var draft = drafts.first(where: { $0.job.id == id }) else {
            throw Shell.Failure(message: "Oby doesn't have that plan any more. Ask again.")
        }
        draft.job = try Self.edit(draft.job, branch: branch, account: accounts.state(account))
        return dispatch(draft)
    }

    /// A plan's job with the only changes the user may make: a branch name Oby can create, and a
    /// signed-in account, whose tool the job then runs with.
    nonisolated static func edit(_ job: Job, branch: String, account: AccountState?) throws -> Job {
        guard Plan.isBranchName(branch) else { throw Shell.Failure(message: "That isn't a branch name Oby can create.") }
        guard let account, account.signedIn else { throw Shell.Failure(message: "That account isn't signed in.") }
        var job = job
        job.branch = branch
        job.account = account.account.id
        job.agent = account.account.agent
        return job
    }

    /// Pushes the job's branch and opens a draft pull request once `approve` lets the action
    /// through: Touch ID on the Mac, a phone's signature on the runner. Never a merge.
    @discardableResult
    func publish(_ id: String, approve: (String) async throws -> Void) async throws -> URL {
        guard let job = job(id), job.canPublish, let base = job.base else { throw Shell.Failure(message: "Nothing to publish.") }
        let url = try await Publish.publish(job, base: base, approve: approve)
        if var job = self.job(id) {
            job.published = url.absoluteString
            replace(job)
        }
        return url
    }

    func stop(_ id: String) {
        let agent = agents[id]
        finish(id, .stopped, "Stopped by you.")
        agent?.stop()
    }

    /// Oby is quitting: agents end now, and their jobs show as interrupted next time.
    func quit() {
        for (id, agent) in agents {
            agent.kill()
            finish(id, .interrupted, "Oby quit while this was running.")
        }
    }

    func job(_ id: String) -> Job? { jobs.first { $0.id == id } }

    private func start(_ prepared: Job) {
        var job = prepared
        job.status = .running
        job.started = .now
        job.step = "Starting \(job.agentName)"
        replace(job)
        let home = accounts.state(job.account)?.account.home.map { URL(filePath: $0) }
        let agent: any AgentRun
        switch job.agent {
        case "claude": agent = ClaudeAgent(worktree: Workspace.worktree(job.id), configDirectory: home)
        case "codex": agent = CodexAgent(worktree: Workspace.worktree(job.id), home: home)
        default: finish(job.id, .failed, "\(job.agentName) can't run jobs yet."); return
        }
        agents[job.id] = agent
        do {
            try agent.start(prompt: Prompts.agent(job)) { [weak self] event in self?.handle(event, job: job.id) }
        } catch {
            finish(job.id, .failed, "\(job.agentName) didn't start: \(error.localizedDescription)")
        }
    }

    private func handle(_ event: AgentEvent, job id: String) {
        guard var job = job(id), job.isActive else { return }
        switch event {
        case .session(let session):
            job.session = session
            replace(job)
        case .step(let step):
            job.step = step
            replace(job, save: false)
        case .usage:
            accounts.record(event, for: job.account)
        case .finished(let summary, let failed):
            finish(id, failed ? .failed : .done, summary)
        }
    }

    private func finish(_ id: String, _ status: Job.Status, _ summary: String) {
        guard var job = job(id), job.isActive else { return }
        job.status = status
        job.summary = summary
        job.step = ""
        job.finished = .now
        replace(job)
        agents[id] = nil
        onFinish(job)
        guard status == .done, let base = job.base else { return }
        Task {
            let count = try? await Shell.ok(["git", "-C", Workspace.worktree(id).path, "rev-list", "--count", "refs/remotes/origin/\(base)..HEAD"])
            if var job = self.job(id) {
                job.commits = count.flatMap { Int($0) }
                replace(job)
            }
        }
    }

    private func replace(_ job: Job, save: Bool = true) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job
        if save { store.save(job) }
        onJobChange(job)
    }
}
