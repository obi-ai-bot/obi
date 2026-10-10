import Foundation
import Observation
#if canImport(OSLog)
import OSLog
#endif

/// Oby's desk: the conversation that turns words into a plan, and the jobs it dispatched.
@Observable
final class Desk {
    enum Talk: Equatable {
        case none
        case thinking(String)
        /// One draft per job, at least one.
        case plan([Draft])
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
        /// A stronger model for complex work, offered on the card and used only if the user turns it on.
        var suggestedModel: String? = nil
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
    /// Jobs whose one turn ended: their agent is finishing and takes no more words.
    private var ending: Set<String> = []
    /// Jobs that ended done and are counting their commits and publishing.
    private var finishing: Set<String> = []
    /// Jobs whose agent this run of Oby started, with the commits each had then. Only they publish
    /// by themselves, and only with commits made since: a job that ended before Oby started never
    /// does, and one whose own publish failed isn't retried (Publish by hand is).
    private var ranHere: [String: Int] = [:]
    /// Jobs whose agent was cut off mid-turn and picked up again: that happens once, then the job fails.
    private var pickedUp: Set<String> = []
    /// Setting up worktrees in the same clone one at a time keeps git's locks out of the way.
    private var setups: [String: Task<Void, Never>] = [:]
    /// Gets a job's worktree ready, and makes its agent (nil for a tool that can't run jobs yet). Tests put in their own.
    @ObservationIgnored var prepare: (Job) async throws -> Job = { try await Workspace.prepare($0) }
    @ObservationIgnored var makeAgent: (Job, _ home: URL?, _ resume: String?) -> (any AgentRun)? = Desk.agent
    /// How many commits the job's worktree has beyond `since`, or nil when git can't say. Tests put in their own.
    @ObservationIgnored var countCommits: (_ id: String, _ since: String) async -> Int? = { id, since in
        (try? await Shell.ok(["git", "-C", Workspace.worktree(id).path, "rev-list", "--count", "\(since)..HEAD"])).flatMap { Int($0) }
    }
    /// Publishes a job that ended done with commits, with no one to approve it: the check passed
    /// and the secret scan gates it (case 4.1). Tests put in their own.
    @ObservationIgnored var publishOnItsOwn: (Job, _ base: String) async throws -> URL = { try await Publish.publish($0, base: $1) { _ in } }
    /// Publishes by hand, once `approve` lets the action through. Tests put in their own.
    @ObservationIgnored var publishByHand: (Job, _ base: String, _ approve: (String) async throws -> Void) async throws -> URL = {
        try await Publish.publish($0, base: $1, approve: $2)
    }

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
        await Agents.readIdentity()
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
        var result = await Planner(adapters: [brain]).plan(said, context: brainContext)
        record(BrainTurn(said: said, by: result.by, plan: result.plan, refused: result.refused))
        var epics: [Int: Int] = [:]
        (result.plan.dispatches, epics) = await Self.expandEpics(result.plan.dispatches)
        if result.plan.action == .dispatch, result.plan.dispatches.isEmpty {
            return .reply(epics.isEmpty ? "Oby couldn't plan that. Try saying it another way." : "That epic has no open sub-issues to work on.")
        }
        let talk = card(for: result, said: said)
        if case .plan(let list) = talk {
            // ponytail: the last 20 drafts, in memory; a plan made before a restart is made again.
            drafts.append(contentsOf: list)
            if drafts.count > 20 { drafts.removeFirst(drafts.count - 20) }
        }
        return talk
    }

    /// Every turn of the brain goes to the log (the runner's journal) and `oby.sqlite`, with the words.
    func record(_ turn: BrainTurn) {
        Logger.brain.notice("\(turn.line, privacy: .public)")
        store.save(turn)
    }

    /// An epic becomes one job per open sub-issue (10 at most): GitHub's sub-issues, otherwise the
    /// issues its task list names. Returns the jobs and, per epic, how many sub-issues it had.
    nonisolated static func expandEpics(_ dispatches: [Plan.Dispatch]) async -> ([Plan.Dispatch], [Int: Int]) {
        var jobs: [Plan.Dispatch] = []
        var epics: [Int: Int] = [:]
        for dispatch in dispatches {
            guard let epic = dispatch.epic else { jobs.append(dispatch); continue }
            let subIssues = await Workspace.openSubIssues(of: epic, in: dispatch.repo)
            epics[epic] = subIssues.count
            for (number, title) in subIssues.prefix(max(0, 10 - jobs.count)) {
                var job = dispatch
                job.epic = nil
                job.issue = number
                job.task = "Work on issue #\(number) (\(title)), part of epic #\(epic). What the user asked for the epic: \(dispatch.task)"
                jobs.append(job)
            }
        }
        return (jobs, epics)
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

    /// What the user sees for the brain's plan. Stopping happens here: there's nothing to confirm.
    func card(for result: Planner.Result, said: String) -> Talk {
        let plan = result.plan
        switch plan.action {
        case .dispatch:
            // Each job is routed knowing where the ones before it went, so a plan spreads out.
            var states = accounts.accounts
            var drafts: [Draft] = []
            for dispatch in plan.dispatches {
                let agent = dispatch.agent == "auto" ? nil : dispatch.agent
                let named = states.first { $0.signedIn && $0.account.name == dispatch.account && (agent == nil || $0.account.agent == agent) }
                if dispatch.account != "auto", named == nil {
                    return .reply("\(dispatch.account) isn't signed in. Sign in from Settings › Accounts.")
                }
                guard let account = named?.account ?? AccountStore.route(states, agent: agent) else {
                    let tool = agent.map { Job.agentNames[$0] ?? $0 } ?? "coding tool"
                    return .reply("No \(tool) account is signed in with room to spare. Check Settings › Accounts.")
                }
                if let index = states.firstIndex(where: { $0.account.id == account.id }) { states[index].running += 1 }
                let id = String(UUID().uuidString.prefix(8)).lowercased()
                var job = Job(id: id, request: said, agent: account.agent, account: account.id, repo: dispatch.repo,
                              branch: Job.branch(kind: dispatch.kind, pr: dispatch.pr, issue: dispatch.issue, id: id),
                              base: dispatch.baseBranch, pr: dispatch.pr, kind: dispatch.kind, task: dispatch.task)
                job.issue = dispatch.issue
                job.rounds = dispatch.rounds > 1 ? dispatch.rounds : nil
                job.check = dispatch.check
                let reply = plan.reply.isEmpty ? "\(job.agentName) will \(dispatch.kind.rawValue) in \(job.repoName)." : plan.reply
                drafts.append(Draft(said: said, reply: reply, job: job, guessed: result.by == "rules",
                                    suggestedModel: dispatch.complexity == .complex ? AgentModels.stronger[account.agent] : nil))
            }
            return drafts.isEmpty ? .none : .plan(drafts)
        case .askUser:
            return plan.question.map { .question(said: said, $0) } ?? .reply(plan.reply)
        case .stopAgent:
            // The count, not the brain's reply: it doesn't know what was running.
            let stopped = stopAll()
            return .reply(stopped == 0 ? "Nothing is running." : "Stopped \(stopped) job\(stopped == 1 ? "" : "s").")
        case .replyOnly, .ignore:
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
            return try await self.prepare(job)
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
    /// Rounds and check keep the plan's values unless the client sends them.
    func dispatch(_ id: String, branch: String, account: String, rounds: Int? = nil, check: String?? = nil, model: String?? = nil) throws -> Job {
        guard var draft = drafts.first(where: { $0.job.id == id }) else {
            throw Shell.Failure(message: "Oby doesn't have that plan any more. Ask again.")
        }
        draft.job = try Self.edit(draft.job, branch: branch, account: accounts.state(account), rounds: rounds, check: check)
        if let model {
            // Only the stronger model the plan offered (for the tool the job ended up with), or none.
            guard model == nil || (draft.suggestedModel != nil && AgentModels.stronger.values.contains(model ?? "")) else {
                throw Shell.Failure(message: "That model wasn't offered for this job.")
            }
            draft.job.model = model == nil ? nil : AgentModels.stronger[draft.job.agent]
        }
        return dispatch(draft)
    }

    /// A plan's job with the only changes the user may make: a branch name Oby can create, a
    /// signed-in account (whose tool the job then runs with), and how it loops: 1 to 10 rounds,
    /// and a one-line check or none.
    nonisolated static func edit(_ job: Job, branch: String, account: AccountState?, rounds: Int? = nil, check: String?? = nil) throws -> Job {
        guard Plan.isBranchName(branch) else { throw Shell.Failure(message: "That isn't a branch name Oby can create.") }
        guard let account, account.signedIn else { throw Shell.Failure(message: "That account isn't signed in.") }
        var job = job
        job.branch = branch
        job.account = account.account.id
        job.agent = account.account.agent
        if let rounds {
            guard (1...10).contains(rounds) else { throw Shell.Failure(message: "Rounds go from 1 to 10.") }
            job.rounds = rounds > 1 ? rounds : nil
        }
        if let check {
            let trimmed = check?.trimmingCharacters(in: .whitespaces) ?? ""
            guard trimmed.isEmpty || Plan.isCheck(trimmed) else { throw Shell.Failure(message: "The check is one line of up to 200 characters.") }
            job.check = trimmed.isEmpty ? nil : trimmed
        }
        return job
    }

    /// Publishing by hand, for a job whose own publish failed: pushes the job's branch and opens
    /// its pull request once `approve` lets the action through: Touch ID on the Mac, a phone's
    /// signature on the runner. Never a merge. Commits already on the base leave nothing to
    /// publish, as when the job publishes by itself: it stops waiting for Publish, and the reason
    /// is thrown too.
    @discardableResult
    func publish(_ id: String, approve: (String) async throws -> Void) async throws -> URL {
        guard let job = job(id), job.canPublish, let base = job.base else { throw Shell.Failure(message: "Nothing to publish.") }
        do {
            let url = try await publishByHand(job, base, approve)
            if var job = self.job(id) {
                job.published = url.absoluteString
                job.publishError = nil
                replace(job)
            }
            return url
        } catch let merged as Publish.AlreadyOnBase {
            if var job = self.job(id), job.canPublish {
                job.summary = (merged.errorDescription ?? "Not published.") + "\n\n" + job.summary
                job.commits = 0
                job.publishError = nil
                replace(job)
            }
            throw merged
        } catch {
            if var job = self.job(id), job.canPublish {
                job.publishError = error.localizedDescription
                replace(job)
            }
            throw error
        }
    }

    func stop(_ id: String) {
        let agent = agents[id]
        finish(id, .stopped, "Stopped by you.")
        agent?.stop()
    }

    /// Stops every queued and running job, and says how many.
    @discardableResult
    func stopAll() -> Int {
        let ids = active.map(\.id)
        for id in ids { stop(id) }
        return ids.count
    }

    /// The user talks to a job. A running one hears it now; a finished one picks its session up
    /// again in the same worktree, for one more round.
    func message(_ id: String, _ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(text.count) else { throw Shell.Failure(message: "Tell the agent something of 1 to 2,000 characters.") }
        guard let job = job(id) else { throw Shell.Failure(message: "There's no job \(id).") }
        if job.isActive {
            guard let agent = agents[id], !ending.contains(id) else {
                throw Shell.Failure(message: job.status == .queued ? "\(job.agentName) hasn't started yet. Tell it again in a moment."
                                    : "\(job.agentName) is wrapping up. Tell it again once it's done.")
            }
            replace(Self.heard(job, text))
            agent.send(text)
        } else {
            guard let session = job.session else { throw Shell.Failure(message: "This job never started, so there's no session to pick up.") }
            let resumed = Self.resumed(job, text)
            replace(resumed)
            run(resumed, prompt: text, resume: session)
        }
    }

    /// The job with the user's words saved, and shown as its step until the agent moves on.
    nonisolated static func heard(_ job: Job, _ text: String) -> Job {
        var job = job
        job.notes = (job.notes ?? []) + [text]
        job.step = "You: \(text)"
        return job
    }

    /// A finished job running again for the user's words: same id and branch, a new round, and
    /// one more round on a loop's limit so the limit still holds.
    nonisolated static func resumed(_ job: Job, _ text: String) -> Job {
        var job = heard(job, text)
        job.status = .running
        job.finished = nil
        job.round = job.currentRound + 1
        if let rounds = job.rounds { job.rounds = rounds + 1 }
        return job
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
        run(job, prompt: Prompts.agent(job))
    }

    /// Starts the job's agent in its worktree: a new session, or the job's own picked up again.
    private func run(_ job: Job, prompt: String, resume: String? = nil) {
        let home = accounts.state(job.account)?.account.home.map { URL(filePath: $0) }
        guard let agent = makeAgent(job, home, resume) else { return finish(job.id, .failed, "\(job.agentName) can't run jobs yet.") }
        agents[job.id] = agent
        ranHere[job.id] = job.commits ?? 0
        do {
            // Only the job's current agent speaks for it: one that was stopped or ended may still report.
            try agent.start(prompt: prompt) { [weak self, weak agent] event in
                guard let self, let agent, self.agents[job.id] === agent else { return }
                self.handle(event, job: job.id)
            }
        } catch {
            finish(job.id, .failed, "\(job.agentName) didn't start: \(error.localizedDescription)")
        }
    }

    /// Claude Code or Codex in the job's worktree, or nil for a tool that can't run jobs yet.
    static func agent(for job: Job, home: URL?, resume: String?) -> (any AgentRun)? {
        switch job.agent {
        case "claude":
            let claude = ClaudeAgent(worktree: Workspace.worktree(job.id), configDirectory: home, resume: resume)
            claude.model = job.model
            return claude
        case "codex":
            let codex = CodexAgent(worktree: Workspace.worktree(job.id), home: home, resume: resume)
            codex.model = job.model
            return codex
        default: return nil
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
        case .turnEnded(let summary, let failed):
            job.summaries = (job.summaries ?? []) + [summary]
            replace(job)
            // One turn and no check: the job ends when the agent does, after any background work.
            guard job.loops else {
                ending.insert(id)
                agents[id]?.end()
                return
            }
            let heard = job.notes?.count ?? 0
            Task { await afterTurn(id, summary: summary, failed: failed, heard: heard) }
        case .finished(let summary, let failed):
            finish(id, failed ? .failed : .done, summary)
        case .cutOff(let summary):
            // Its process died mid-turn (killed, out of memory): the session picks up again once.
            guard let session = job.session, !ending.contains(id), pickedUp.insert(id).inserted else {
                let again = pickedUp.contains(id) ? "\n\nOby picked its session up once, and it was cut off again." : ""
                return finish(id, .failed, summary + again)
            }
            Logger.jobs.notice("job \(id, privacy: .public): \(summary, privacy: .public) Picking its session up again.")
            job.step = "Picking up where \(job.agentName) was cut off"
            replace(job)
            run(job, prompt: Self.cutOff, resume: session)
        }
    }

    /// What an agent that was cut off mid-turn hears when its session picks up again.
    static let cutOff = "You were cut off mid-turn. Continue where you left off, then finish with a short summary as asked."

    /// Runs the job's check, if it has one, then ends the job or sends the agent another round.
    /// `heard` is how many of the user's words the turn had taken in.
    private func afterTurn(_ id: String, summary: String, failed: Bool, heard: Int) async {
        guard var job = job(id), job.isActive, let agent = agents[id] else { return }
        var check: Rounds.Check?
        if let command = job.check, !failed {
            job.step = "Checking: \(command)"
            replace(job, save: false)
            let worktree = Workspace.worktree(id)
            let result = try? await Shell.run(Agents.sandboxed(["sh", "-c", command], in: worktree, own: nil), in: worktree,
                                              env: Agents.overrides, timeout: 1200)
            let output = result.map { String(decoding: $0.out, as: UTF8.self) + $0.err } ?? "Oby couldn't run it."
            check = Rounds.Check(command: command, passed: result?.status == 0, output: String(output.suffix(4000)))
            // Stopped while the check ran.
            guard let latest = self.job(id), latest.isActive else { return }
            job = latest
        }
        // The user spoke since the turn ended: the agent took it up, and that turn decides.
        guard (job.notes?.count ?? 0) == heard else { return }
        switch Rounds.next(job, summary: summary, failed: failed, check: check) {
        case let .finish(status, text):
            agent.end()
            finish(id, status, text)
        case let .again(message):
            job.round = job.currentRound + 1
            job.step = "Round \(job.currentRound) of \(job.maxRounds)"
            replace(job)
            agent.send(message)
        }
    }

    /// Ends the job. A job that's done counts its commits first, so one that should have committed
    /// and didn't ends as "nothing committed" rather than done. One that's done with commits its
    /// pull request doesn't have yet, made since its agent started in this run of Oby, publishes
    /// them before it ends (case 4.1): commits already on the base by patch leave nothing to
    /// publish; a possible secret fails it, naming where; any other failure leaves it done, with
    /// the reason and Publish offered.
    private func finish(_ id: String, _ status: Job.Status, _ summary: String) {
        guard var job = job(id), job.isActive else { return }
        guard status == .done, let base = job.base else { return end(id, status, summary) }
        // Already finishing: the agent's process ending after its last turn changes nothing.
        guard finishing.insert(id).inserted else { return }
        job.step = "Counting commits"
        replace(job, save: false)
        // Its agent is done and takes no more words.
        ending.insert(id)
        Task {
            defer { finishing.remove(id) }
            let commits = await countCommits(id, "refs/remotes/origin/\(base)")
            // A pull request's branch has its own commits beyond the base: only the ones after its head are the job's.
            let made = job.pr == nil ? commits : await countCommits(id, "refs/oby/pr-\(job.pr ?? 0)")
            guard var running = self.job(id), running.isActive else { return }
            // The job as it would end, which is what gets published.
            var ended = running
            (ended.status, ended.summary) = Job.ending(ended, status, summary, made: made)
            ended.commits = commits
            guard ended.canPublish, let before = ranHere[id], (commits ?? 0) > before else {
                // Still waiting for Publish by hand: why its own publish failed still holds.
                return end(id, status, summary, commits: commits, made: made, publishError: ended.canPublish ? ended.publishError : nil)
            }
            running.step = "Publishing"
            replace(running, save: false)
            do {
                let url = try await publishOnItsOwn(ended, base)
                end(id, status, summary, commits: commits, made: made, published: url)
            } catch let merged as Publish.AlreadyOnBase {
                // Merged already (a squash merge changes the hashes): nothing is left to publish.
                end(id, status, (merged.errorDescription ?? "Not published.") + "\n\n" + ended.summary, commits: 0, made: made)
            } catch let blocked as Publish.Blocked {
                end(id, .failed, (blocked.errorDescription ?? "Not published.") + "\n\n" + ended.summary, commits: commits, made: made)
            } catch {
                end(id, status, summary, commits: commits, made: made, publishError: error.localizedDescription)
            }
        }
    }

    /// `commits`: beyond the base, what Publish would push. `made`: the ones this job made.
    /// `published`: the pull request it just published to, or `publishError`, why it couldn't.
    private func end(_ id: String, _ status: Job.Status, _ summary: String, commits: Int? = nil, made: Int? = nil,
                     published: URL? = nil, publishError: String? = nil) {
        guard var job = job(id) else { return }
        guard job.isActive else {
            // Stopped while publishing: the pull request is out all the same.
            if let published {
                job.commits = commits ?? job.commits
                job.published = published.absoluteString
                replace(job)
            }
            return
        }
        (job.status, job.summary) = Job.ending(job, status, summary, made: made)
        job.commits = commits
        // After commits, so it counts them as pushed.
        if let published { job.published = published.absoluteString }
        job.publishError = publishError
        job.step = ""
        job.finished = .now
        replace(job)
        agents[id] = nil
        ranHere[id] = nil
        pickedUp.remove(id)
        ending.remove(id)
        onFinish(job)
    }

    private func replace(_ job: Job, save: Bool = true) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job
        if save { store.save(job) }
        onJobChange(job)
    }
}

/// What happens after an agent's turn in a job that loops: the job's check decides, or the
/// agent's own last line (`GOAL MET` / `GOAL NOT MET: …`), within the job's rounds.
nonisolated enum Rounds {
    struct Check: Equatable, Sendable {
        var command: String
        var passed: Bool
        /// The end of what the command printed: what the agent needs to fix it.
        var output: String
    }

    enum Next: Equatable {
        case finish(Job.Status, String)
        /// Another round, with this message to the agent.
        case again(String)
    }

    enum Verdict: Equatable {
        case met
        case notMet(String)
    }

    static func next(_ job: Job, summary: String, failed: Bool, check: Check?) -> Next {
        let last = job.currentRound >= job.maxRounds
        let rounds = "\(job.maxRounds) round\(job.maxRounds == 1 ? "" : "s")"
        if failed { return .finish(.failed, summary) }
        if let check {
            if check.passed { return .finish(.done, summary + "\n\nChecked: `\(check.command)` passed.") }
            if last { return .finish(.failed, "`\(check.command)` still fails after \(rounds).\n\n" + summary) }
            return .again("Oby ran `\(check.command)` and it failed:\n\n```\n\(check.output)\n```\n\nFix it, run it again yourself, and finish with a short summary.")
        }
        switch verdict(summary) {
        // No verdict line: take the agent at its word rather than loop on a missing line.
        case .met, nil: return .finish(.done, summary)
        case .notMet(let left):
            if last { return .finish(.failed, "Not finished after \(rounds): \(left)\n\n" + summary) }
            return .again("Keep going: \(left)")
        }
    }

    /// The agent's verdict on its own work: its summary's last line.
    static func verdict(_ summary: String) -> Verdict? {
        guard let line = summary.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let plain = line.filter { $0 != "`" && $0 != "*" }.trimmingCharacters(in: .whitespaces)
        if plain.uppercased() == "GOAL MET" { return .met }
        guard plain.uppercased().hasPrefix("GOAL NOT MET") else { return nil }
        let left = plain.dropFirst("GOAL NOT MET".count).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return .notMet(left.isEmpty ? "the goal isn't met yet" : left)
    }
}
