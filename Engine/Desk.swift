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
    /// The repositories the brain and the Lead may choose from; `refresh` reads them, tests set them.
    var repos: [String] = []
    /// The roadmap board as the Lead last read it (Engine/Lead.swift), for claims.
    private var board: Board?
    /// Jobs ready to run that wait for an earlier job touching the same files to end (case 2.1), in order.
    private var waiting: [Job] = []
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
    /// Jobs running again for the user's words (`message` on a finished job): that round is theirs,
    /// so ending it with nothing committed is done, not "nothing committed".
    private var asked: Set<String> = []
    /// The message that started a looping job's current round (the check's output, "Keep going"),
    /// for an agent that takes the round over; nil when the round began with the task or the user's words.
    private var roundMessage: [String: String] = [:]
    /// How each job moved between accounts when one hit its limit, oldest first: the report says so.
    private var handoffs: [String: [String]] = [:]
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
    @ObservationIgnored var publishOnItsOwn: (Job, _ base: String, Publish.Hooks) async throws -> URL = {
        try await Publish.publish($0, base: $1, hooks: $2) { _ in }
    }
    /// Publishes by hand, once `approve` lets the action through. Tests put in their own.
    @ObservationIgnored var publishByHand: (Job, _ base: String, _ approve: (String) async throws -> Void, Publish.Hooks) async throws -> URL = {
        try await Publish.publish($0, base: $1, hooks: $3, approve: $2)
    }
    /// Oby's review of a job's pull request (Engine/Review.swift): posts it as a comment, after the
    /// secret scan, and quotes it as a file for the author's next round. Tests put in their own.
    @ObservationIgnored var postReview: (_ author: Job, _ body: String) async throws -> URL = Review.post
    @ObservationIgnored var quoteReview: (_ author: Job, _ file: String, _ text: String) throws -> Void = Review.quote
    /// The Lead (Engine/Lead.swift): reads the roadmap board before a turn, runs the turn on the
    /// Claude account whose home is given, and claims an issue when a job starts on it. Tests put in their own.
    @ObservationIgnored var readBoard: (_ repos: [String]) async throws -> Board = { try await Board.read(repos: $0) }
    @ObservationIgnored var makeLead: (_ home: String?) -> [any LeadAdapter] = Lead.adapters
    @ObservationIgnored var claim: (Job, Board?) async throws -> String = Lead.claim
    /// Where each goal's context files go: `leads/<goal>/.oby/context/`.
    @ObservationIgnored var leadRoot = Workspace.root.appending(path: "leads")

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
        // A review that was running: its author stops waiting for it.
        for job in jobs where job.reviewOf != nil && job.status == .interrupted { reviewEnded(job) }
    }

    var active: [Job] { jobs.filter(\.isActive) }

    func refresh() async {
        if let repos = try? await Workspace.knownRepos(), !repos.isEmpty { self.repos = repos }
        await Agents.readIdentity()
        await accounts.refresh()
        // Reviews that were waiting for an account with room when Oby last ran: start them now that
        // the sign-ins are known, or watch for room (also a five-minute safety net).
        startWaitingReviews()
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
    /// A vague goal ("work on the roadmap") goes to the Lead instead, when a Claude account is
    /// signed in: it starts the jobs itself and answers with a reply or a question.
    func plan(_ said: String) async -> Talk {
        if repos.isEmpty { await refresh() }
        // The brain and the Lead think with the least busy Claude account too, so a busy one doesn't slow them.
        let thinker = AccountStore.route(accounts.accounts, agent: "claude")
        if Lead.leads(said), let thinker { return await lead(said, account: thinker) }
        let brain = ClaudeBrain(home: thinker?.home)
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

    /// Every turn of the Lead too, in the same table.
    func record(_ turn: LeadTurn) {
        Logger.brain.notice("\(turn.line, privacy: .public)")
        store.save(turn)
    }

    // MARK: The Lead

    /// One Lead turn for the user's words (Engine/Lead.swift): Swift reads the board, builds the
    /// skipped list and writes the context files; the Lead answers a typed plan; Swift checks it
    /// and starts its jobs right away, routed across the accounts with room. Nothing to confirm.
    func lead(_ said: String, account thinker: Account) async -> Talk {
        let goal = String(UUID().uuidString.prefix(8)).lowercased()
        let board: Board
        do {
            board = try await readBoard(repos)
        } catch {
            record(LeadTurn(goal: goal, said: said, by: "none", refused: ["the board couldn't be read: \(error.localizedDescription)"]))
            return .reply("Oby couldn't read the roadmap: \(error.localizedDescription)")
        }
        self.board = board
        let skipped = Lead.skipped(board.items, jobs: jobs, user: board.user)
        let directory = leadRoot.appending(path: goal)
        var checkouts: [String: String] = [:]
        for repo in Set(repos + board.items.map(\.repo)) where FileManager.default.fileExists(atPath: Workspace.clone(repo).appending(path: ".git").path) {
            checkouts[repo] = Workspace.clone(repo).path
        }
        do {
            try Lead.writeContext(roadmap: Lead.roadmap(board, skipped: skipped, checkouts: checkouts), jobs: Lead.jobsList(jobs), to: directory)
        } catch {
            record(LeadTurn(goal: goal, said: said, by: "none", refused: ["the context couldn't be written: \(error.localizedDescription)"], skipped: skipped))
            return .reply("Oby couldn't write the Lead's context: \(error.localizedDescription)")
        }
        var context = LeadContext(repos: Array(Set(repos + board.items.map(\.repo))).sorted())
        context.workable = Set(board.items.map { "\($0.repo)#\($0.number)" })
        for item in skipped {
            context.refused["\(item.repo)#\(item.number)"] = item.reason
            context.workable.remove("\(item.repo)#\(item.number)")
        }
        // Issues off the board with a running job are refused too.
        for job in jobs where job.isActive && job.pr == nil {
            guard let issue = job.issue, context.refused["\(job.repo)#\(issue)"] == nil else { continue }
            context.refused["\(job.repo)#\(issue)"] = "job \(job.id) is \(job.status.rawValue) on it"
        }
        var adapters = makeLead(thinker.home)
        for index in adapters.indices { if var claude = adapters[index] as? ClaudeLead { claude.checkouts = Array(checkouts.values); adapters[index] = claude } }
        let result = await LeadPlanner(adapters: adapters).plan(said, context: context, in: directory)
        Lead.prune(leadRoot)
        var turn = LeadTurn(goal: goal, said: said, by: result.by, plan: result.plan, refused: result.refused, skipped: skipped)
        guard let plan = result.plan else {
            record(turn)
            // The last reason, without the refused plan's JSON after it.
            var why = result.refused.last ?? "no Claude account answered"
            if let end = why.range(of: "): ") { why = String(why[..<end.lowerBound]) + ")" }
            return .reply("The Lead couldn't plan that (\(why.prefix(200))). Try saying it another way.")
        }
        switch plan.action {
        case .askUser:
            record(turn)
            return plan.question.map { .question(said: said, $0) } ?? .reply(plan.reply)
        case .reply:
            record(turn)
            return .reply(plan.reply.isEmpty ? "Nothing to start." : plan.reply)
        case .startJobs:
            var states = accounts.accounts
            var started: [Job] = []
            var taken: [Int] = []
            var unrouted = 0
            for brief in plan.jobs {
                // The turn took a while: a repeated request (the Mac and the iPhone, a retry after the
                // app gave up waiting) may have started a job on this issue meanwhile.
                if let job = Lead.taken(brief, by: jobs) {
                    taken.append(brief.issue)
                    turn.refused.append("#\(brief.issue) not started: job \(job.id) is \(job.status.rawValue) on it already")
                    continue
                }
                guard let account = AccountStore.pick(&states, agent: nil) else { unrouted += 1; continue }
                started.append(enqueue(Lead.job(brief, said: said, goal: goal, account: account)))
            }
            turn.started = started.map(\.id)
            record(turn)
            guard !started.isEmpty else {
                if !taken.isEmpty, unrouted == 0 { return .reply("Nothing new to start: " + taken.map { "#\($0)" }.joined(separator: ", ") + " already \(taken.count == 1 ? "has" : "have") a job.") }
                return .reply("No account is signed in with room to spare. Check Settings › Accounts.")
            }
            var text = "Started \(started.count) job\(started.count == 1 ? "" : "s"): "
                + started.map { "\($0.heading) (#\($0.issue ?? 0))" }.joined(separator: ", ") + "."
            if !taken.isEmpty { text += " " + taken.map { "#\($0)" }.joined(separator: ", ") + " already \(taken.count == 1 ? "has" : "have") a job." }
            if unrouted > 0 { text += " \(unrouted) more had no account with room." }
            if !skipped.isEmpty { text += " Skipped \(skipped.count) on the board." }
            return .reply(text)
        }
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
                // The epic's title doesn't name one sub-issue: these show "Fix oby #12".
                job.title = nil
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
                job.title = dispatch.title
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
        return enqueue(draft.job)
    }

    /// Queues a job: its worktree gets ready, then its agent starts. Oby's own jobs (reviews) start here.
    @discardableResult
    func enqueue(_ job: Job) -> Job {
        var job = job
        job.phase = .prepare
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
                startOrWait(prepared)
            } catch {
                finish(job.id, .failed, "Couldn't get \(job.repoName) ready: \(error.localizedDescription)")
            }
        }
        return job
    }

    /// A job that's ready runs now, unless an earlier active job expects to touch the same files
    /// (case 2.1): then it waits, queued, until that job ends.
    private func startOrWait(_ prepared: Job) {
        guard let blocker = blocker(of: prepared) else { return start(prepared) }
        var job = prepared
        job.step = "Waiting for \(blocker.heading) (\(blocker.id)): both touch \(Self.overlap(prepared, blocker).joined(separator: ", "))"
        replace(job)
        waiting.append(job)
    }

    /// The earlier job (older in the list, queued or running) this one would collide with, if any.
    private func blocker(of job: Job) -> Job? {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return nil }
        return jobs[(index + 1)...].first { $0.isActive && !Self.overlap(job, $0).isEmpty }
    }

    /// A job ended: the waiting jobs it was blocking run now, in order, unless another blocks them.
    private func releaseWaiting() {
        for waiter in waiting {
            guard let latest = job(waiter.id), latest.status == .queued, blocker(of: latest) == nil else { continue }
            waiting.removeAll { $0.id == waiter.id }
            start(latest)
        }
    }

    /// The files two jobs would both touch: the same repository, and a path of one that is the
    /// other's or inside a folder the other names (ending in `/`). Empty when either has no list.
    nonisolated static func overlap(_ a: Job, _ b: Job) -> [String] {
        guard a.repo == b.repo, let ours = a.files, let theirs = b.files else { return [] }
        var shared: [String] = []
        for path in ours where theirs.contains(where: { Lead.same(path, $0) }) && !shared.contains(path) { shared.append(path) }
        return shared
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
            let url = try await publishByHand(job, base, approve, hooks(id, stoppable: false))
            if var job = self.job(id) {
                job.pullRequest = nil
                job.pullRequestError = nil
                job.published = url.absoluteString
                job.publishError = nil
                replace(job)
                reviewPublished(job)
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

    /// The user lets go of a job that needs them (Publish, failed, interrupted): it stays as it
    /// ended, in the list and in history, needing nothing. Telling it something undoes this.
    /// A job dismissed already is left as it is.
    func dismiss(_ id: String) throws {
        guard var job = job(id) else { throw Shell.Failure(message: "There's no job \(id).") }
        guard job.dismissed == nil else { return }
        guard job.needsYou else {
            throw Shell.Failure(message: job.isActive ? "It's still running: stop it instead." : "Nothing to dismiss: this job doesn't need you.")
        }
        job.dismissed = .now
        replace(job)
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
            asked.insert(id)
            roundMessage[id] = nil
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
    /// one more round on a loop's limit so the limit still holds. Dismissed no more: it's theirs again.
    nonisolated static func resumed(_ job: Job, _ text: String) -> Job {
        var job = heard(job, text)
        job.status = .running
        job.phase = .work
        job.publishStep = nil
        job.finished = nil
        job.dismissed = nil
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
        job.phase = .work
        job.started = .now
        job.step = "Starting \(job.agentName)"
        replace(job)
        run(job, prompt: Prompts.agent(job))
        // A job the Lead started claims its issue (case 1.3): assigned to the user, status:in-progress
        // with the branch, In progress on the board. The job says how it went.
        if job.lead != nil, job.issue != nil {
            let board = board
            Task {
                var line: String
                do {
                    line = try await claim(job, board)
                } catch {
                    line = "Not claimed: \(error.localizedDescription)"
                }
                if line.isEmpty { return }
                Logger.jobs.notice("job \(job.id, privacy: .public): \(line, privacy: .public)")
                guard var latest = self.job(job.id) else { return }
                latest.claim = line
                replace(latest)
            }
        }
    }

    /// Starts the job's agent in its worktree: a new session, or the job's own picked up again.
    func run(_ job: Job, prompt: String, resume: String? = nil) {
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
        case .limit(let resets):
            // Its turn died on the account's limit. One that's finishing after its last turn is left to end.
            guard !ending.contains(id) else { return }
            moveOn(job, resets: resets)
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

    /// The job's account hit its usage limit mid-round: the account is full until `resets` (an
    /// hour when the tool named no time), and the job does the round over on the next account with
    /// room, the same tool first, in the same worktree and branch with a new session. With no
    /// account to go to, it fails, saying when the first one resets.
    private func moveOn(_ job: Job, resets: Date?) {
        let id = job.id
        let from = accounts.state(job.account)?.account.heading ?? job.agentName
        accounts.markFull(job.account, until: resets ?? .now.addingTimeInterval(3600))
        let when = resets.map { " (resets \(Limits.clock($0)))" } ?? ""
        // Dropped before it's killed, so nothing it says as it dies counts.
        let agent = agents[id]
        agents[id] = nil
        agent?.kill()
        guard let next = AccountStore.next(accounts.accounts, agent: job.agent) else {
            let first = accounts.accounts.filter(\.signedIn).compactMap(\.fullUntil).min()
            let soonest = first.map { " The first resets at \(Limits.clock($0))." } ?? ""
            Logger.jobs.error("job \(id, privacy: .public): \(from, privacy: .public) hit its limit, and no account has room")
            return finish(id, .failed, "\(from) hit its usage limit\(when), and no other account has room.\(soonest)")
        }
        Logger.jobs.notice("job \(id, privacy: .public): \(from, privacy: .public) hit its limit\(when, privacy: .public); continuing on \(next.heading, privacy: .public)")
        handoffs[id, default: []].append("\(from) hit its limit\(when); continued on \(next.heading).")
        var moved = job
        moved.account = next.id
        moved.agent = next.agent
        moved.session = nil
        // The stronger model is the tool's own.
        if moved.model != nil { moved.model = AgentModels.stronger[next.agent] }
        moved.step = "\(from) hit its limit; continuing on \(next.heading)"
        replace(moved)
        pickedUp.remove(id)
        run(moved, prompt: Prompts.takeover(moved, from: from, round: roundMessage[id]))
    }

    /// Runs the job's check, if it has one, then ends the job or sends the agent another round.
    /// `heard` is how many of the user's words the turn had taken in.
    private func afterTurn(_ id: String, summary: String, failed: Bool, heard: Int) async {
        guard var job = job(id), job.isActive, let agent = agents[id] else { return }
        var check: Rounds.Check?
        if let command = job.check, !failed {
            job.phase = .check
            job.step = "Checking: \(command)"
            replace(job)
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
            job.phase = .work
            job.step = "Round \(job.currentRound) of \(job.maxRounds)"
            replace(job)
            roundMessage[id] = message
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
            (ended.status, ended.summary) = Job.ending(ended, status, summary, made: made, asked: asked.contains(id))
            ended.commits = commits
            guard ended.canPublish, let before = ranHere[id], (commits ?? 0) > before else {
                // Still waiting for Publish by hand: why its own publish failed still holds.
                return end(id, status, summary, commits: commits, made: made, publishError: ended.canPublish ? ended.publishError : nil)
            }
            running.phase = .publish
            running.publishStep = .scan
            running.step = "Publishing"
            replace(running)
            do {
                let url = try await publishOnItsOwn(ended, base, hooks(id, stoppable: true))
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
                job.pullRequest = nil
                job.pullRequestError = nil
                replace(job)
            }
            return
        }
        (job.status, job.summary) = Job.ending(job, status, summary, made: made, asked: asked.contains(id))
        if job.status == .failed && status == .done { job.phase = .work }
        // How it moved between accounts, for the report.
        if let moves = handoffs[id], !moves.isEmpty { job.summary += "\n\n" + moves.joined(separator: "\n") }
        job.commits = commits
        // After commits, so it counts them as pushed.
        if let published {
            job.pullRequest = nil
            job.pullRequestError = nil
            job.published = published.absoluteString
        }
        job.publishError = publishError
        job.step = ""
        job.finished = .now
        replace(job)
        agents[id] = nil
        ranHere[id] = nil
        pickedUp.remove(id)
        ending.remove(id)
        asked.remove(id)
        roundMessage[id] = nil
        handoffs[id] = nil
        waiting.removeAll { $0.id == id }
        // Oby reviews what was just published, and a review that ended reaches its author (Engine/Review.swift).
        if published != nil { reviewPublished(job) }
        if job.reviewOf != nil { reviewEnded(job) }
        onFinish(job)
        // A job that waited on this one for the same files runs now (case 2.1).
        releaseWaiting()
    }

    /// What publishing `id` reports as it goes. A job publishing as it ends is `stoppable`: once
    /// it's stopped, nothing more goes out.
    private func hooks(_ id: String, stoppable: Bool) -> Publish.Hooks {
        Publish.Hooks(progress: { [weak self] in self?.publishing(id, $0) },
                      proceed: { [weak self] in if stoppable, self?.job(id)?.isActive != true { throw Publish.Stopped() } },
                      sent: { [weak self] in self?.sent(id, $0) })
    }

    private func publishing(_ id: String, _ step: PublishStep) {
        guard var job = job(id) else { return }
        job.phase = .publish
        job.publishStep = step
        job.publishError = nil
        replace(job)
    }

    /// Includes older published jobs beyond the UI's recent 50. Live jobs win over saved steps.
    var pullRequestsToFollow: [Job] {
        var all = Dictionary(uniqueKeysWithValues: store.recent(-1).map { ($0.id, $0) })
        for job in jobs { all[job.id] = job }
        return all.values.filter {
            $0.published != nil && ($0.pullRequest == nil || $0.pullRequest?.state == .open)
        }.sorted { $0.id < $1.id }
    }

    /// Apply only the observation to the latest job: it may have resumed while gh was running.
    func followed(_ id: String, published: String, pushed: Int?, status: PullRequestStatus?, error: String?) {
        guard var latest = job(id) ?? store.recent(-1).first(where: { $0.id == id }),
              latest.published == published, latest.pushed == pushed else { return }
        if let status { latest.pullRequest = status }
        latest.pullRequestError = error
        if job(id) != nil { replace(latest) }
        else { store.save(latest); onJobChange(latest) }
    }

    func replace(_ job: Job, save: Bool = true) {
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
