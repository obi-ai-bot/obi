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
        /// The account routing chose and why, or nil when the user named it.
        var route: AccountStore.Route? = nil
    }

    var talk: Talk = .none
    /// The conversation (Engine/Conversation.swift): what the user said and what Oby answered,
    /// oldest first, the last `Conversation.stored`. The window's thread, and the brain's memory
    /// (it reads the last `Conversation.kept`).
    private(set) var turns: [Turn]
    /// Called with every turn that's added or changes (a job dispatched from it), for the runner's
    /// event stream. Not when a cancelled turn leaves the thread: that happens only on the Mac.
    var onTurnChange: (Turn) -> Void = { _ in }
    /// The jobs the Lead just started, for the reply turn that tells of them.
    private var justStarted: [String] = []
    private(set) var jobs: [Job] {
        didSet { accounts.countRunning(jobs) }
    }
    let accounts: AccountStore
    /// Called when a job ends, for the notch's one line.
    var onFinish: (Job) -> Void = { _ in }
    /// Called with Oby's reply when a turn of `ask` ends, and whether the user spoke it (the Mac
    /// then speaks the reply). Not for a turn that was cancelled or replaced.
    var onReply: (_ text: String, _ spoken: Bool) -> Void = { _, _ in }
    /// Jobs and inbox items elsewhere for the brain's briefing: the runner's, on the Mac.
    @ObservationIgnored var elsewhere: () -> [Briefing.Place] = { [] }
    /// Stops jobs elsewhere, by id, when the brain names them or stops everything. Answers once
    /// they're stopped, with why each that couldn't be wasn't, by id.
    @ObservationIgnored var stopElsewhere: ([String]) async -> [String: String] = { _ in [:] }
    /// Moves a job elsewhere, by id, when the brain names it (`Desk.move` there): the job as it is
    /// now, or why it couldn't move.
    @ObservationIgnored var moveElsewhere: (_ id: String, _ target: MoveTarget, _ why: String?) async throws -> Job = { _, _, _ in
        throw Shell.Failure(message: "That job isn't here.")
    }
    /// The brain's adapters, on the Claude account whose home is given. Tests put in their own.
    @ObservationIgnored var makeBrain: (_ home: String?, Vault) -> [any BrainAdapter] = { [ClaudeBrain(home: $0, vault: $1)] }
    /// How long `ask` waits for an answer before the turn ends with `Conversation.timedOut`, so
    /// the island never stays on Thinking. A Lead goal gets twice this.
    @ObservationIgnored var patience: Duration = .seconds(45)
    /// Counts asks: a result from a turn that was cancelled or replaced is ignored.
    private var asking = 0
    /// The user's turn waiting for its answer, in `turns`, or nil.
    private var pending: String?
    /// Called with every job that's added or changes, for the runner's event stream.
    var onJobChange: (Job) -> Void = { _ in }
    /// What only the user can answer (Engine/Inbox.swift), oldest first, done ones too: the same
    /// need never comes back once it's done.
    private(set) var inbox: [InboxItem] = []
    /// Called with every inbox item that's added or changes, for the runner's event stream.
    var onInboxChange: (InboxItem) -> Void = { _ in }
    /// Whether open inbox items are rewritten in plain words by the brain's model (`InboxRewriter`,
    /// through `makeBrain`), in the background: an item comes at once with its text, and its
    /// headline follows. Off until the runner turns it on, so a desk never calls a model by itself;
    /// turning it on rewrites the open items that have none yet.
    @ObservationIgnored var rewritesInbox = false {
        didSet { if rewritesInbox { for item in inbox where item.isOpen && item.headline == nil { rewrite(item) } } }
    }
    /// How long a rewrite may take before the item keeps its text.
    @ObservationIgnored var rewritePatience: TimeInterval = 20
    /// Rewrites by item id and text, so the same item is never rewritten twice, and the ones under way.
    private var rewrites: [String: InboxRewrite] = [:]
    private var rewriting: Set<String> = []

    /// Runner updates pause every entry to an agent, including review and follow-up rounds.
    @ObservationIgnored var drainingForUpdate = false
    /// A moved job's handover, by job: its new agent starts once the agent it left and that one's
    /// check have ended (`move`).
    private var handovers: [String: Task<Void, Never>] = [:]
    /// The messages held for agents while draining, with what `run` was given (the prompt's on disk too).
    private var updateWaiting: [String: (job: Job, prompt: String, resume: String?, notice: String?)] = [:]
    private var updatePreparing: Set<String> = []
    var updateIsIdle: Bool {
        active.allSatisfy { $0.status == .queued || updateWaiting[$0.id] != nil || $0.question != nil } && updateIsBetweenSteps
    }
    /// No job is inside a step of its end of turn: counting its commits and publishing, a review's
    /// verdict reaching its author (its check run, then the round or the Mac check), merging. A
    /// runner update restarts only here, even past its drain limit (#212).
    var updateIsBetweenSteps: Bool {
        updatePreparing.isEmpty && finishing.isEmpty && finishingChecks.isEmpty && wrappingUp.isEmpty
    }
    /// End-of-turn work under way outside a job's own run, by kind and job, like `review:<author>` (`wrapUp`).
    @ObservationIgnored var wrappingUp: Set<String> = []

    /// Runs `work` as end-of-turn work a runner update waits for, once at a time per `key`: false
    /// when it's under way already.
    @discardableResult
    func wrapUp(_ key: String, _ work: @escaping @MainActor () async -> Void) -> Bool {
        guard wrappingUp.insert(key).inserted else { return false }
        Task {
            defer { wrappingUp.remove(key) }
            await work()
        }
        return true
    }

    func cancelUpdateDrain() {
        drainingForUpdate = false
        let waiting = updateWaiting
        updateWaiting.removeAll()
        for (id, held) in waiting where job(id)?.isActive == true {
            run(held.job, prompt: held.prompt, resume: held.resume, notice: held.notice)
        }
        releaseWaiting()
    }

    /// The runner's journal (Engine/Restarts.swift), or nil on the Mac, where quitting leaves jobs interrupted.
    @ObservationIgnored let restarts: Restarts?
    /// Jobs that were queued or running when the runner went down, oldest first, for `resumeAfterRestart`.
    @ObservationIgnored var wentDown: [String] = []

    func updateFailed(_ item: InboxItem) {
        guard !inbox.contains(where: { $0.id == item.id }) else { return }
        inbox.append(item)
        store.save(item)
        onInboxChange(item)
    }

    private let store: JobStore
    /// The repositories the brain and the Lead may choose from; `refresh` reads them, tests set them.
    var repos: [String] = []
    /// The roadmap board as the Lead last read it (Engine/Lead.swift), for claims.
    private var board: Board?
    @ObservationIgnored lazy var issueSync = IssueSync(desk: self, store: store)
    /// Failure records and their post-mortems (Engine/Failures.swift): on for the runner.
    @ObservationIgnored lazy var failureLog = Failures(desk: self, store: store)
    /// Jobs ready to run that wait for a free slot (`maxRunning`) or for a runner update to end.
    private var waiting: [Job] = []
    /// At most this many jobs run at once (#237): a new job, or Oby's review, waits, queued, for a
    /// slot, and they start oldest first as slots free up. A round of a job that started already
    /// (a review's changes, a rebase, a failed Mac check, the user's words) takes a slot too, but
    /// never waits for one. Raising it starts waiting jobs at once.
    @ObservationIgnored var maxRunning = JobSlots.saved {
        didSet { if maxRunning > oldValue { releaseWaiting() } }
    }
    /// Jobs on their way to the slot they took: brought up to date with their base before they start.
    private var startingUp: Set<String> = []
    /// Jobs ready to run that wait for their `startWhen` (#216, Engine/StartWhen.swift), checked every
    /// `startWhenEvery`; the ones the user chose to keep waiting though a condition can't hold; and
    /// pull requests' states as last read for them, by `repo#number`.
    @ObservationIgnored var scheduled: Set<String> = []
    @ObservationIgnored var keptWaiting: Set<String> = []
    @ObservationIgnored var pullRequestStates: [String: PullRequestStatus.State] = [:]
    @ObservationIgnored var startWhenTimer: Task<Void, Never>?
    @ObservationIgnored var startWhenEvery: Duration = .seconds(60)
    /// The time conditions are checked at. Tests put in their own.
    @ObservationIgnored var clock: () -> Date = { .now }
    /// A pull request's state on GitHub, or nil when it can't be read. Tests put in their own.
    @ObservationIgnored var pullRequestState: (_ repo: String, _ number: Int) async -> PullRequestStatus.State? = { repo, number in
        guard let text = try? await Shell.ok(["gh", "pr", "view", "\(number)", "-R", repo, "--json", "state"], as: .app),
              let info = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return (info["state"] as? String).flatMap(PullRequestStatus.State.init(rawValue:))
    }
    /// Whether job `id` is on its way to its slot.
    func isStartingUp(_ id: String) -> Bool { startingUp.contains(id) }
    /// Takes job `id` out of the jobs waiting for a slot: whether it was there.
    func dropFromSlotQueue(_ id: String) -> Bool {
        guard waiting.contains(where: { $0.id == id }) else { return false }
        waiting.removeAll { $0.id == id }
        return true
    }
    /// A line for job `id`'s report, with how routing chose its account.
    func noteStart(_ line: String, for id: String) { handoffs[id, default: []].append(line) }
    /// How many slots are taken: jobs running (`Job.takesSlot`), and those about to.
    var runningCount: Int { jobs.filter(\.takesSlot).count + startingUp.count }
    /// The latest plans until they're dispatched: the runner's API dispatches them by job id.
    private var drafts: [Draft] = []
    private var agents: [String: any AgentRun] = [:]
    /// Agents told to stop whose own stop hasn't ended them yet (`Halt.grace`): quitting ends them too.
    private var stopping: [ObjectIdentifier: any AgentRun] = [:]
    /// Jobs whose one turn ended: their agent is finishing and takes no more words.
    private var ending: Set<String> = []
    /// Jobs that ended done and are counting their commits and publishing.
    private var finishing: Set<String> = []
    /// Jobs whose agent this run of Oby started, with the commits each had then and how many of them
    /// weren't on its pull request. Only they publish by themselves, and only with commits made (or
    /// rebased) since: a job that ended before Oby started never does, and one whose own publish
    /// failed isn't retried (Publish by hand is).
    private var ranHere: [String: (commits: Int, unpublished: Int)] = [:]
    /// Jobs whose agent was cut off mid-turn and picked up again: that happens once, then the job fails.
    private var pickedUp: Set<String> = []
    /// Jobs running again for the user's words (`message` on a finished job): that round is theirs,
    /// so ending it with nothing committed is done, not "nothing committed".
    private var asked: Set<String> = []
    /// Jobs that had their round to commit work they'd left uncommitted (#220): that's once, then
    /// ending with nothing committed fails.
    private var committingRound: Set<String> = []
    /// The message that started a looping job's current round (the check's output, "Keep going"),
    /// for an agent that takes the round over; nil when the round began with the task or the user's words.
    private var roundMessage: [String: String] = [:]
    /// Why routing chose each job's account, and how it moved between accounts when one hit its
    /// limit, oldest first: the report says so.
    private var handoffs: [String: [String]] = [:]
    /// Each running job's round timer and job cap (case 3.1): one ending first holds the job. The
    /// round's clock stands still while its agent waits for an Apple check (`paceRound`, #203).
    private var roundTimers: [String: RoundTimer] = [:]
    private var jobTimers: [String: Task<Void, Never>] = [:]
    /// The fingerprint of each looping job's last failing round (Engine/Guards.swift).
    private var failures: [String: String] = [:]
    /// How many actions in a row Oby denied each running job.
    private var denials: [String: Int] = [:]
    /// Each looping job's work after a turn (its check, then the round that follows): stopping the
    /// job cancels it, which ends a check still running.
    private var afterTurns: [String: Task<Void, Never>] = [:]
    /// Jobs failing now because every account hit its limit: their inbox item says so.
    private var limited: Set<String> = []
    /// Setting up worktrees in the same clone one at a time keeps git's locks out of the way.
    private var setups: [String: Task<Void, Never>] = [:]
    /// The files an issue claims (`Claims`), for a plan's job about it, or nil: none named, or it
    /// couldn't be read. Nothing on a desk that doesn't read issues while planning (the job claims
    /// them when its worktree gets ready, `Workspace.inputs`); the runner reads them with gh. Tests put in their own.
    @ObservationIgnored var issueFiles: (_ repo: String, _ issue: Int) async -> [String]? = { _, _ in nil }
    /// Gets a job's worktree ready, and makes its agent (nil for a tool that can't run jobs yet). Tests put in their own.
    @ObservationIgnored var prepare: (Job) async throws -> Job = { try await Workspace.prepare($0) }
    @ObservationIgnored var makeAgent: (Job, _ home: URL?, _ resume: String?) -> (any AgentRun)? = Desk.agent
    /// How many commits the job's worktree has beyond `since`, or nil when git can't say. Tests put in their own.
    @ObservationIgnored var countCommits: (_ id: String, _ since: String) async -> Int? = { id, since in
        (try? await Shell.ok(["git", "-C", Workspace.worktree(id).path, "rev-list", "--count", "\(since)..HEAD"])).flatMap { Int($0) }
    }
    /// The files the job's worktree has changed but not committed; none when git can't say. Ignored
    /// files (`.oby/`) aren't among them. Read untrimmed: a record's first column can be a space. Tests put in their own.
    @ObservationIgnored var changedFiles: (_ id: String) async -> [String] = { id in
        guard let status = try? await Shell.run(["git", "-C", Workspace.worktree(id).path, "status", "--porcelain", "-z"]),
              status.status == 0 else { return [] }
        return Job.changedFiles(porcelain: String(decoding: status.out, as: UTF8.self))
    }
    /// How many commits the job's worktree has beyond `since` that `pushed` (the commit Oby pushed
    /// last) doesn't: the new ones, or all of them after a rebase. Nil when git can't say. Tests put in their own.
    @ObservationIgnored var countUnpushed: (_ id: String, _ since: String, _ pushed: String) async -> Int? = { id, since, pushed in
        (try? await Shell.ok(["git", "-C", Workspace.worktree(id).path, "rev-list", "--count", "HEAD", "^\(since)", "^\(pushed)"])).flatMap { Int($0) }
    }
    /// Brings origin/<base> up to date from GitHub in the job's clone, before a rebase round, and
    /// returns the commit it's at. Tests put in their own.
    @ObservationIgnored var fetchBase: (_ job: Job, _ base: String) async throws -> String = { job, base in
        let worktree = Workspace.worktree(job.id)
        try await Publish.fetch(base, of: job, into: worktree)
        return try await Shell.ok(["git", "-C", worktree.path, "rev-parse", "--verify", "refs/remotes/origin/\(base)^{commit}"])
    }
    /// Moves a job's worktree from commit `from` to `to`, only while its head is still `from` (no
    /// work of its own): whether it moved. Ignored files (`.oby/`) stay. Tests put in their own.
    @ObservationIgnored var moveWorktree: (_ id: String, _ from: String, _ to: String) async throws -> Bool = { id, from, to in
        let path = Workspace.worktree(id).path
        guard try await Shell.ok(["git", "-C", path, "rev-parse", "--verify", "HEAD^{commit}"]) == from,
              try await Shell.ok(["git", "-C", path, "status", "--porcelain"]).isEmpty else { return false }
        try await Shell.ok(["git", "-C", path, "reset", "--quiet", "--hard", to])
        return true
    }
    /// Whether a rebase round published the same patch it had before (`Rebase.samePatch`), from the
    /// job's worktree: its old head, the base it was rebased onto, its new head. Tests put in their own.
    @ObservationIgnored var samePatch: (_ id: String, _ from: String, _ onto: String, _ to: String) async -> Bool = { id, from, onto, to in
        await Rebase.samePatch(worktree: Workspace.worktree(id), from: from, onto: onto, to: to)
    }
    /// The limits every job is held to (case 3.1). Tests put in their own.
    @ObservationIgnored var limits = JobLimits()
    /// `oby-check apple` as the runner installed it, or nil (Engine/AppleChecks.swift). Tests put in their own.
    @ObservationIgnored var appleTool: () -> AppleCheck.Tool? = { AppleCheck.installed }
    /// Runs a job's check in its worktree with `env` (no vault secret), ending it after `timeout`
    /// seconds. Tests put in their own.
    @ObservationIgnored var runCheck: (_ id: String, _ command: String, _ timeout: TimeInterval, _ env: [String: String?]) async -> Rounds.Check = { id, command, timeout, env in
        await Rounds.run(command, in: Workspace.worktree(id), timeout: timeout, env: env)
    }
    /// What a job's work does to the tests since its branch started (case 3.2): what weakens them,
    /// and other changes to existing tests. Tests put in their own.
    /// The job's commits since `since` and their Tetrix sessions (Engine/TetrixUse.swift). Tests put in their own.
    @ObservationIgnored var readStamps: (_ id: String, _ since: String) async -> TetrixUse.Stamps? = { id, since in
        await TetrixUse.stamps(worktree: Workspace.worktree(id), since: since)
    }
    @ObservationIgnored var integrity: (Job) async -> Integrity.Report = { job in
        guard let ref = Integrity.ref(job) else { return Integrity.Report() }
        return await Integrity.check(worktree: Workspace.worktree(job.id), against: ref)
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
    /// Oby's review of a job's pull request (Engine/Review.swift): writes it as a check run, after the
    /// secret scan, and quotes it as a file for the author's next round. Tests put in their own.
    @ObservationIgnored var postReview: (_ author: Job, _ run: CheckRun) async throws -> URL = CheckRun.post
    @ObservationIgnored var quoteReview: (_ author: Job, _ file: String, _ text: String) throws -> Void = Review.quote
    /// Merge checks on the user's Mac (Engine/Checks.swift): the commit a review job read, the
    /// results' check run, the secret scan of what a merge lands, and the merge. Tests put in their own.
    @ObservationIgnored var reviewedHead: (_ review: String) async -> String? = { id in
        try? await Shell.ok(["git", "-C", Workspace.worktree(id).path, "rev-parse", "--verify", "HEAD^{commit}"])
    }
    @ObservationIgnored var postCheck: (_ author: Job, _ run: CheckRun) async throws -> URL = CheckRun.post
    @ObservationIgnored var scanForMerge: (_ job: Job, _ head: String) async throws -> [Publish.Finding] = MacCheck.scan
    @ObservationIgnored var mergePullRequest: (_ job: Job, _ check: MacCheck) async throws -> Void = MacCheck.merge
    /// Called with every Mac check that's queued, taken or ends, for the runner's event stream.
    var onCheckChange: (MacCheck) -> Void = { _ in }
    /// Jobs whose Xcode Cloud failure is being handed to their author (`recoverCloud`), once at a time.
    @ObservationIgnored var cloudRecovering: Set<String> = []
    /// Jobs whose Mac check result is being posted and merged or handed back (`finishCheck`), once at a time.
    @ObservationIgnored var finishingChecks: Set<String> = []
    /// Whether an approval queues a Mac check: on the runner, which Macs ask for checks. The Mac's
    /// own desk has no one to take them, so its approved jobs wait for a person to merge them.
    @ObservationIgnored var queuesMacChecks = false
    /// Apple checks agents ask for (Engine/AppleChecks.swift): the commit a job's worktree is on,
    /// the git bundle a Mac fetches a check's commits from, and what each check printed (by the
    /// check's id: a job's latest and the latest that ran), for its agent and its reviewer, never
    /// stored. Tests put in their own.
    @ObservationIgnored var worktreeHead: (_ id: String) async -> String? = { id in
        try? await Shell.ok(["git", "-C", Workspace.worktree(id).path, "rev-parse", "--verify", "HEAD^{commit}"])
    }
    @ObservationIgnored var bundleCommits: (MacCheck) async throws -> Data = { try await AppleCheck.bundle($0) }
    /// What job `id`'s worktree has that isn't committed (`git status --porcelain`), or nil when
    /// git can't say: a job whose round ran out publishes only work it committed (#203).
    @ObservationIgnored var worktreeStatus: (_ id: String) async -> String? = { id in
        try? await Shell.ok(["git", "-C", Workspace.worktree(id).path, "status", "--porcelain"])
    }
    @ObservationIgnored var appleLogs: [String: String] = [:]
    /// What everything on its way to an agent is checked against (Engine/Vault.swift): prompts,
    /// messages, files, reviews and environments. Tests put in their own.
    @ObservationIgnored var vault = Vault.shared
    /// The Lead (Engine/Lead.swift): reads the roadmap board before a turn, runs the turn on the
    /// Claude account whose home is given, and claims an issue when a job starts on it. Tests put in their own.
    @ObservationIgnored var readBoard: (_ repos: [String]) async throws -> Board = { try await Board.read(repos: $0) }
    @ObservationIgnored var makeLead: (_ home: String?) -> [any LeadAdapter] = Lead.adapters
    /// Where each goal's context files go: `leads/<goal>/.oby/context/`.
    @ObservationIgnored var leadRoot = Workspace.root.appending(path: "leads")

    /// How many of the newest jobs the desk lists when Oby starts, with the outstanding ones however old.
    static let listed = 50

    init(accounts: AccountStore = AccountStore(), store: JobStore = JobStore(url: Workspace.root.appending(path: "oby.sqlite")), restarts: Restarts? = nil) {
        self.accounts = accounts
        self.store = store
        self.restarts = restarts
        // ponytail: every job is read to find the outstanding ones; a column to query when there are many thousands.
        let all = store.recent(-1)
        jobs = Array(all.prefix(Self.listed))
        inbox = store.inbox()
        turns = store.conversation()
        let byID = Dictionary(all.map { ($0.id, $0) }) { first, _ in first }
        // Every job that still needs something, however old (#223): its pull request is followed,
        // and it can be dismissed or told something, after any number of restarts.
        let outstanding = all.filter(\.outstanding)
        // The jobs open inbox items are about, however old: answering one needs its job.
        // A review item's One more round quotes the review, so that job comes too.
        let asking = Set(inbox.filter(\.isOpen).map(\.job))
        let reviews = asking.compactMap { byID[$0]?.review?.job }
        // On the runner, every job that went down with it, however old, and the authors of the reviews among them.
        let down = restarts == nil ? [] : all.filter(\.isActive)
        // And the reviews whose verdict a restart kept from their authors, with them (`resumeReviews`).
        let unapplied = restarts == nil ? [] : all.filter { $0.reviewOf == nil && ($0.review?.applying == true || $0.reviewing != nil) }
        let applying = unapplied.map(\.id) + unapplied.compactMap(\.reviewing) + unapplied.compactMap { $0.review?.applying == true ? $0.review?.job : nil }
        let wanted = Set(outstanding.map(\.id)).union(outstanding.compactMap(\.reviewOf)).union(asking).union(reviews)
            .union(down.map(\.id)).union(down.compactMap(\.reviewOf)).union(applying).subtracting(jobs.map(\.id))
        jobs += all.filter { wanted.contains($0.id) }
        // Running when Oby last quit (or crashed): it didn't finish. On the runner it carries on
        // (`resumeAfterRestart`), unless it waits for the user's answer.
        for index in jobs.indices.reversed() where jobs[index].isActive {
            // One waiting for its `startWhen` asks only about that, and keeps waiting (#216).
            if restarts != nil && (jobs[index].question == nil || jobs[index].waitsToStart) {
                wentDown.append(jobs[index].id)
                continue
            }
            // One waiting for the user's answer keeps waiting, nothing running (#206): the answer
            // picks its session up again (`message`).
            if restarts != nil {
                jobs[index].step = "Waiting for your answer"
                store.save(jobs[index])
                continue
            }
            jobs[index].status = .interrupted
            jobs[index].finished = jobs[index].finished ?? .now
            store.save(jobs[index])
        }
        accounts.countRunning(jobs)
        // A review that was running: its author stops waiting for it.
        for job in jobs where job.reviewOf != nil && job.status == .interrupted { reviewEnded(job) }
        // What the jobs need now, the interrupted ones too.
        for job in jobs { syncInbox(job) }
    }

    var active: [Job] { jobs.filter(\.isActive) }

    func refresh() async {
        if let repos = try? await Workspace.knownRepos(), !repos.isEmpty { self.repos = repos }
        await Agents.readIdentity()
        await accounts.refresh()
        // Reviews that were waiting for an account with room when Oby last ran: start them now that
        // the sign-ins are known, or watch for room (also a five-minute safety net).
        startWaitingReviews()
        // Merges a restart cut short, or that failed on something that may pass now (Engine/Checks.swift).
        resumeChecks()
    }

    /// The brain picks "auto" or an account by name; Swift turns that into a real account. With
    /// the briefing: these `turns` (the conversation so far), the jobs here and elsewhere, the
    /// inbox and the accounts.
    func brainContext(turns: [Turn]) -> BrainContext {
        let signedIn = accounts.accounts.filter(\.signedIn).map(\.account)
        let known = signedIn.isEmpty ? accounts.accounts.map(\.account) : signedIn
        var choices = ["auto": ["auto"] + known.map(\.name)]
        for (agent, list) in Dictionary(grouping: known, by: \.agent) { choices[agent] = ["auto"] + list.map(\.name) }
        let briefing = briefing(turns: turns)
        // A job may move to any account the briefing knows, here or elsewhere: Swift checks it when it moves.
        var moveAccounts: [String: [String]] = [:]
        for state in accounts.accounts + elsewhere().flatMap(\.accounts) where !(moveAccounts[state.account.agent] ?? []).contains(state.account.name) {
            moveAccounts[state.account.agent, default: []].append(state.account.name)
        }
        return BrainContext(accounts: choices, repos: repos, briefing: briefing.text, quoted: briefing.quoted, jobs: briefing.stoppable,
                            movable: briefing.jobs.map(\.job.id), models: Moves.models, moveAccounts: moveAccounts)
    }

    /// What the brain is told before the user's words (Engine/Conversation.swift).
    func briefing(turns: [Turn]) -> Briefing {
        Briefing(turns: turns, places: [Briefing.Place(name: "this Mac", jobs: jobs, inbox: inbox)] + elsewhere(), accounts: accounts.accounts,
                 failures: failureLog.week())
    }

    // MARK: The conversation

    /// The user said something: it joins the thread, and Oby thinks. The answer joins the thread
    /// too, or the island hears why not within `patience`. `shown` is what the thread shows when
    /// the brain gets more (an answer with its question). `spoken`: the user talked, so the Mac
    /// speaks the reply. A bare "never mind", "stop" or "cancel" never reaches the brain: it ends
    /// the turn under way (its words leave the thread) and otherwise does nothing, so no job stops
    /// on a word; stopping work takes a job's name or "stop everything". Any other words replace
    /// the turn under way.
    func ask(_ words: String, shown: String? = nil, spoken: Bool = false) {
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        if Conversation.cancels(said) { return cancel() }
        cancel()
        asking += 1
        let mine = asking
        let turn = Turn(who: .user, text: shown ?? said, voice: spoken ? true : nil)
        pending = turn.id
        add(turn)
        talk = .thinking(said)
        let limit = Lead.leads(said) ? patience * 2 : patience
        let deadline = ContinuousClock.now + limit
        Task {
            // Cancelled, replaced or past its time while the brain was thinking: its plan does
            // nothing, whichever of the plan and the clock is heard first.
            let live = { self.asking == mine && ContinuousClock.now < deadline }
            let result = await Self.within(limit) { await self.plan(said, live: live) }
            guard asking == mine else { return }
            // Too long: the turn ends here, and the plan, when it comes, is dead.
            let late = result == nil || (result == .none && ContinuousClock.now >= deadline)
            if late { asking += 1 }
            let talk = late ? .reply(Conversation.timedOut) : result ?? .none
            pending = nil
            self.talk = talk
            if let reply = Self.reply(in: talk) {
                addReply(reply)
                onReply(reply, spoken)
            }
        }
    }

    /// Drops the turn under way: its words leave the thread, and its answer, when it comes, is
    /// ignored. Also takes a plan's card down.
    func cancel() {
        asking += 1
        if let pending {
            remove(pending)
            self.pending = nil
        }
        talk = .none
    }

    /// One exchange for the runner's API: the user's words and Oby's answer join the thread, and
    /// the brain reads `turns` as the conversation so far (the client's, when it sent them, else
    /// the runner's own). A bare cancel word is answered with nothing. The plan acts unless the
    /// request's task was cancelled meanwhile; a client that merely stopped waiting can't be told apart.
    func converse(_ said: String, shown: String? = nil, turns given: [Turn]? = nil) async -> Talk {
        guard !Conversation.cancels(said) else { return .none }
        let talk = await plan(said, turns: given) { !Task.isCancelled }
        add(Turn(who: .user, text: shown ?? said))
        if let reply = Self.reply(in: talk) { addReply(reply) }
        return talk
    }

    /// The conversation's turns before `before` (a turn's id; nil for the newest), at most `limit`,
    /// oldest first: one page of the thread for `GET /v1/conversation`. Nil for an id that isn't in it.
    func conversation(before: String? = nil, limit: Int) -> [Turn]? {
        var end = turns.count
        if let before {
            guard let index = turns.firstIndex(where: { $0.id == before }) else { return nil }
            end = index
        }
        let start = max(0, end - max(0, limit))
        return Array(turns[start..<end])
    }

    /// What Oby says for a talk, as the thread shows it and the Mac speaks it: a plan's line,
    /// the question, or the reply. Nothing for nothing.
    static func reply(in talk: Talk) -> String? {
        switch talk {
        case .plan(let drafts): drafts.first?.reply
        case .question(_, let question): question.text
        case .reply(let text): text
        case .none, .thinking: nil
        }
    }

    private func add(_ turn: Turn) {
        turns.append(turn)
        if turns.count > Conversation.stored { turns.removeFirst(turns.count - Conversation.stored) }
        store.save(turn)
        onTurnChange(turn)
    }

    /// Oby's reply joins the thread, with the jobs the Lead just started for it, if any.
    private func addReply(_ text: String) {
        let started = justStarted
        justStarted = []
        add(Turn(who: .oby, text: text, jobs: started.isEmpty ? nil : started))
    }

    /// A job dispatched from Oby's latest plan joins the turn that proposed it: the window shows
    /// it as a card under Oby's words. The turn is saved again and sent again (`onTurnChange`).
    private func link(_ job: String) {
        guard let index = turns.lastIndex(where: { $0.who == .oby }) else { return }
        var turn = turns[index]
        guard !(turn.jobs ?? []).contains(job) else { return }
        turn.jobs = (turn.jobs ?? []) + [job]
        turns[index] = turn
        store.save(turn)
        onTurnChange(turn)
    }

    private func remove(_ id: String) {
        turns.removeAll { $0.id == id }
        store.delete(turn: id)
    }

    /// Runs `work`, waiting for it at most `limit`: its result, or nil when it took too long.
    /// The work goes on by itself; whoever asked has moved on.
    private static func within(_ limit: Duration, _ work: @escaping () async -> Talk) async -> Talk? {
        let (first, done) = AsyncStream.makeStream(of: Talk?.self)
        Task { done.yield(await work()) }
        Task {
            try? await Task.sleep(for: limit)
            done.yield(nil)
        }
        for await result in first { return result }
        return nil
    }

    // MARK: Planning

    /// What the brain makes of the user's words: a plan, a question or a reply. Takes 3–20 seconds.
    /// A vague goal ("work on the roadmap") goes to the Lead instead, when a Claude account is
    /// signed in: it starts the jobs itself and answers with a reply or a question. The brain reads
    /// `turns` as the conversation so far: the thread's, but for the words waiting for this answer.
    /// `live` is asked before anything happens for the plan (a job stopped or started): false once
    /// the turn was cancelled, replaced or given up on, and then nothing does, and the answer is `.none`.
    func plan(_ said: String, turns given: [Turn]? = nil, live: @escaping () -> Bool = { true }) async -> Talk {
        if repos.isEmpty { await refresh() }
        // The brain and the Lead think with the least busy Claude account too, so a busy one doesn't slow them.
        let thinker = AccountStore.route(accounts.accounts, agent: "claude")
        if Lead.leads(said), let thinker { return await lead(said, account: thinker, live: live) }
        let context = brainContext(turns: given ?? turns.filter { $0.id != pending })
        var result = await Planner(adapters: makeBrain(thinker?.home, vault)).plan(said, context: context)
        guard live() else {
            result.refused.append("the turn was cancelled before the plan came: nothing done")
            record(BrainTurn(said: said, by: result.by, plan: result.plan, refused: result.refused))
            return .none
        }
        record(BrainTurn(said: said, by: result.by, plan: result.plan, refused: result.refused))
        var epics: [Int: Int] = [:]
        (result.plan.dispatches, epics) = await Self.expandEpics(result.plan.dispatches)
        if result.plan.action == .dispatch, result.plan.dispatches.isEmpty {
            return .reply(epics.isEmpty ? "Oby couldn't plan that. Try saying it another way." : "That epic has no open sub-issues to work on.")
        }
        let talk = await card(for: result, said: said)
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
    /// Unless `live` says the turn was cancelled meanwhile: then no job starts.
    func lead(_ said: String, account thinker: Account, live: () -> Bool = { true }) async -> Talk {
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
            try Lead.writeContext(roadmap: Lead.roadmap(board, skipped: skipped, checkouts: checkouts), jobs: Lead.jobsList(jobs), to: directory, vault: vault)
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
        guard live() else {
            turn.refused.append("the turn was cancelled before the plan came: nothing started")
            record(turn)
            return .none
        }
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
                guard let route = AccountStore.pick(&states, agent: nil) else { unrouted += 1; continue }
                started.append(enqueue(Lead.job(brief, said: said, goal: goal, account: route.account), why: route.why))
            }
            turn.started = started.map(\.id)
            record(turn)
            justStarted = started.map(\.id)
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

    /// The user picked one of the brain's options: plan again with the answer. The thread shows
    /// the option alone; the brain gets the question too.
    func answer(_ option: String, said: String, question: String) {
        ask(Self.answered(said, question: question, option: option), shown: option)
    }

    /// The user's words with the brain's question and the option they picked, to plan again.
    nonisolated static func answered(_ said: String, question: String, option: String) -> String {
        "\(said)\n\n(Oby asked: \(question) The user answered: \(option))"
    }

    /// What the user sees for the brain's plan. Stopping happens here: there's nothing to confirm,
    /// and the reply says what stopped once it has, here and elsewhere.
    func card(for result: Planner.Result, said: String) async -> Talk {
        let plan = result.plan
        switch plan.action {
        case .dispatch:
            // Each job is routed knowing where the ones before it went, so a plan spreads out.
            var states = accounts.accounts
            var drafts: [Draft] = []
            // Each job's claim (case 2.1): the files its issue names, read all at once.
            let claims = plan.dispatches.map { dispatch in
                Task { () async -> [String]? in
                    guard let issue = dispatch.issue else { return nil }
                    return await self.issueFiles(dispatch.repo, issue)
                }
            }
            for (index, dispatch) in plan.dispatches.enumerated() {
                let agent = dispatch.agent == "auto" ? nil : dispatch.agent
                // A job waiting for an account's room runs on that account (#216).
                let waitsOn = dispatch.startWhen?.compactMap(\.account).first
                let wanted = waitsOn ?? dispatch.account
                let named = states.first { $0.signedIn && $0.account.name == wanted && (agent == nil || $0.account.agent == agent) }
                    ?? states.first { $0.signedIn && $0.account.name == waitsOn }
                if wanted != "auto", named == nil {
                    return .reply("\(wanted) isn't signed in. Sign in from Settings › Accounts.")
                }
                let route = named == nil ? AccountStore.choose(states, agent: agent) : nil
                guard let account = named?.account ?? route?.account else {
                    let tool = agent.map { Job.agentNames[$0] ?? $0 } ?? "coding tool"
                    return .reply("No \(tool) account is signed in with room to spare. Check Settings › Accounts.")
                }
                if let index = states.firstIndex(where: { $0.account.id == account.id }) { states[index].running += 1 }
                let id = String(UUID().uuidString.prefix(8)).lowercased()
                // An issue and a pull request ("finish #19 from PR #124", #219): the issue's work,
                // started from the pull request's head.
                let from = dispatch.issue == nil ? nil : dispatch.pr
                let pr = from == nil ? dispatch.pr : nil
                var job = Job(id: id, request: said, agent: account.agent, account: account.id, repo: dispatch.repo,
                              branch: Job.branch(kind: dispatch.kind, pr: pr, issue: dispatch.issue, id: id),
                              base: dispatch.baseBranch, pr: pr, kind: dispatch.kind, task: dispatch.task)
                job.issue = dispatch.issue
                job.fromPR = from
                job.title = dispatch.title
                job.rounds = dispatch.rounds > 1 ? dispatch.rounds : nil
                job.check = dispatch.check
                job.files = await claims[index].value
                if let conditions = dispatch.startWhen, !conditions.isEmpty {
                    // Its account's name is the one it runs on, by id.
                    let named = conditions.map { condition -> StartCondition in
                        switch condition {
                        case .window(_, let window, let under): .window(account: account.id, window, under: under)
                        case .onPace: .onPace(account: account.id)
                        default: condition
                        }
                    }
                    do {
                        job.startWhen = try StartWhen.checked(named, job: id, jobs: startWhenLookup.job, accounts: accounts.accounts)
                    } catch {
                        return .reply("Oby couldn't plan when that starts: \(error.localizedDescription)")
                    }
                }
                let reply = plan.reply.isEmpty ? "\(job.agentName) will \(dispatch.kind.rawValue) in \(job.repoName)." : plan.reply
                drafts.append(Draft(said: said, reply: reply, job: job, guessed: result.by == "rules",
                                    suggestedModel: dispatch.complexity == .complex ? AgentModels.stronger[account.agent] : nil, route: route))
            }
            return drafts.isEmpty ? .none : .plan(drafts)
        case .askUser:
            return plan.question.map { .question(said: said, $0) } ?? .reply(plan.reply)
        case .stopAgent:
            // The jobs the brain named ("cancel it"), here or elsewhere; or everything, here and
            // elsewhere, only when the user asked for all of it in so many words. What was
            // stopped, not the brain's reply: it doesn't know what was running.
            let named = plan.jobs ?? []
            guard !named.isEmpty || plan.all == true else { return .reply("Say which job to stop, or “stop everything”.") }
            let others = Dictionary(elsewhere().flatMap(\.jobs).filter(\.isActive).map { ($0.id, $0) }) { first, _ in first }
            var here: [Job] = []
            var away: [Job] = []
            if named.isEmpty {
                here = active
                away = others.values.sorted { $0.created > $1.created }
            } else {
                for id in named {
                    if let job = job(id), job.isActive { here.append(job) } else if let job = others[id] { away.append(job) }
                }
            }
            for job in here { stop(job.id) }
            let failed = away.isEmpty ? [:] : await stopElsewhere(away.map(\.id))
            let stopped = here + away.filter { failed[$0.id] == nil }
            var reply: String
            if named.isEmpty {
                reply = stopped.isEmpty ? "Nothing is running." : "Stopped \(stopped.count) job\(stopped.count == 1 ? "" : "s")."
            } else {
                reply = stopped.isEmpty && failed.isEmpty ? "That job isn't running any more." : stopped.isEmpty ? "" : "Stopped \(stopped.map(\.heading).joined(separator: ", "))."
            }
            for job in away where failed[job.id] != nil {
                reply += (reply.isEmpty ? "" : " ") + "Couldn't stop \(job.heading): \(failed[job.id] ?? "")"
            }
            return .reply(reply)
        case .moveJob:
            // The job the brain named, here or elsewhere, to where the user said: Swift picks the
            // account and checks the model (`Moves.choose`), and the reply says what happened.
            guard let id = plan.jobs?.first, let move = plan.move else { return .reply("Say which job to move, and where.") }
            let auto = { (value: String) in value == "auto" ? nil : value }
            let target = MoveTarget(agent: auto(move.agent), account: auto(move.account), model: auto(move.model))
            do {
                if job(id) != nil { return .reply(Moves.reply(try self.move(id, to: target, why: said))) }
                guard elsewhere().flatMap(\.jobs).contains(where: { $0.id == id }) else { return .reply("That job isn't here any more.") }
                return .reply(Moves.reply(try await moveElsewhere(id, target, said)))
            } catch {
                return .reply("Couldn't move it: \(error.localizedDescription)")
            }
        case .replyOnly, .ignore:
            guard !plan.reply.isEmpty else { return .none }
            // The brain counted wrong: with agents working here or on the runner, Oby never says
            // nothing is running. The facts come from the jobs the header counts (#11).
            let places = [Briefing.Place(name: "this Mac", jobs: jobs, inbox: [])] + elsewhere()
            if Briefing.working(places) > 0, Briefing.contradicts(plan.reply) { return .reply(Briefing.workingLine(places)) }
            return .reply(plan.reply)
        }
    }

    // MARK: Jobs

    @discardableResult
    func dispatch(_ draft: Draft) -> Job {
        talk = .none
        drafts.removeAll { $0.job.id == draft.job.id }
        // Why routing chose its account, unless the user picked another on the card.
        let job = enqueue(draft.job, why: draft.route.flatMap { $0.id == draft.job.account ? $0.why : nil })
        link(job.id)
        return job
    }

    /// Queues a job: its worktree gets ready, then its agent starts. Oby's own jobs (reviews) start here.
    /// `why` says why routing chose its account, for its report.
    @discardableResult
    func enqueue(_ job: Job, why: String? = nil) -> Job {
        if let why { handoffs[job.id, default: []].append(why) }
        var job = job
        job.phase = .prepare
        job.step = "Getting \(job.repoName) ready"
        jobs.insert(job, at: 0)
        store.save(job)
        onJobChange(job)

        updatePreparing.insert(job.id)
        let previous = setups[job.repo]
        let ready = Task { () async throws -> Job in
            await previous?.value
            return try await self.prepare(job)
        }
        setups[job.repo] = Task { _ = await ready.result }
        Task {
            do {
                defer { updatePreparing.remove(job.id) }
                var prepared = try await ready.value
                // Stopped while Oby was getting the repository ready.
                guard let latest = self.job(prepared.id), latest.status == .queued else { return }
                // Moved meanwhile: it starts where it was moved to, and waits for what it waits for now
                // (started now, or told to wait for something else, #216).
                (prepared.agent, prepared.account, prepared.model, prepared.moves) = (latest.agent, latest.account, latest.model, latest.moves)
                (prepared.startWhen, prepared.question) = (latest.startWhen, latest.question)
                startOrWait(prepared)
            } catch {
                updatePreparing.remove(job.id)
                finish(job.id, .failed, "Couldn't get \(job.repoName) ready: \(error.localizedDescription)")
            }
        }
        return job
    }

    /// A job that's ready runs now when a slot is free (`maxRunning`) and no older job waits for
    /// one; else it waits, queued, and starts in its turn, oldest first (#237). Its `files` never hold
    /// it back: jobs on the same files run side by side, each agent told about the others
    /// (`Prompts.agent`), and conflicts are settled when they merge (`nextMacCheck`, `rebaseConflicted`).
    /// `catchUp`: its worktree was set up a while ago (a restart), so it's brought up to date first.
    /// A job with a `startWhen` waits for it first (#216, `holdsToStart`).
    func startOrWait(_ prepared: Job, catchUp: Bool = false) {
        var prepared = prepared
        if prepared.startWhen != nil {
            if holdsToStart(prepared) { return }
            prepared = job(prepared.id) ?? prepared
        }
        if drainingForUpdate { return start(prepared) }
        let older = waiting.contains { $0.id != prepared.id && $0.created < prepared.created }
        if runningCount < maxRunning && !older { return catchUp ? startCaughtUp(prepared) : start(prepared) }
        var job = prepared
        job.step = JobSlots.waitLine(running: runningCount, of: maxRunning)
        replace(job)
        if !waiting.contains(where: { $0.id == job.id }) { waiting.append(job) }
        // It waits behind an older job with a slot free (one it caught up for, given back): the
        // oldest takes it, rather than leave it unused with nothing to wake them.
        if runningCount < maxRunning { releaseWaiting() }
    }

    /// A slot freed up (a job stopped running, the cap went up, a runner update was called off): the
    /// waiting jobs start, oldest first, as many as there are free slots.
    func releaseWaiting() {
        guard !drainingForUpdate else { return }
        waiting.removeAll { job($0.id)?.status != .queued }
        for waiter in waiting.sorted(by: { $0.created < $1.created }) {
            guard runningCount < maxRunning else { return }
            guard let latest = job(waiter.id) else { continue }
            waiting.removeAll { $0.id == waiter.id }
            startCaughtUp(latest)
        }
    }

    /// A job whose worktree was set up a while ago (it waited for a slot, or for a restart): its
    /// branch moves to the base as GitHub has it now, then it starts (or waits again), so it works on
    /// top of what merged meanwhile rather than conflict with it (#209). It fails, saying why, when
    /// that can't be done. It holds its slot meanwhile (`startingUp`).
    private func startCaughtUp(_ job: Job) {
        var job = job
        job.step = "Bringing \(job.branch) up to date with \(job.base ?? "its base")"
        replace(job, save: false)
        updatePreparing.insert(job.id)
        startingUp.insert(job.id)
        Task {
            defer { updatePreparing.remove(job.id) }
            do {
                let caught = try await caughtUp(job)
                startingUp.remove(job.id)
                guard var latest = self.job(job.id), latest.status == .queued else { return releaseWaiting() }
                // Moved meanwhile: it starts where it was moved to, on the commit it caught up to.
                latest.startCommit = caught.startCommit
                startOrWait(latest)
            } catch {
                startingUp.remove(job.id)
                finish(job.id, .failed, "Couldn't bring \(job.branch) up to date with \(job.base ?? "its base"): \(error.localizedDescription)")
            }
        }
    }

    /// The job with its branch on the base as GitHub has it now (`fetchBase`), when it has no work of
    /// its own yet: its worktree is still at `startCommit`, which becomes the base's commit. Not a job
    /// on a pull request, nor one started from one's head: its branch holds the pull request's commits.
    func caughtUp(_ job: Job) async throws -> Job {
        guard job.pr == nil, job.fromPR == nil, let base = job.base, let start = job.startCommit else { return job }
        let onto = try await fetchBase(job, base)
        guard onto != start, try await moveWorktree(job.id, start, onto) else { return job }
        var job = job
        job.startCommit = onto
        return job
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
    /// `files`, when the client sends them, replace the plan's claim (an empty list claims none).
    /// `startWhen`, when the client sends it, replaces what the plan's job waits for (#216; an empty
    /// list starts it at once), and a condition on an account runs it on that account.
    func dispatch(_ id: String, branch: String, account: String, rounds: Int? = nil, check: String?? = nil, model: String?? = nil,
                  files: [String]? = nil, startWhen: [StartCondition]? = nil) throws -> Job {
        guard var draft = drafts.first(where: { $0.job.id == id }) else {
            throw Shell.Failure(message: "Oby doesn't have that plan any more. Ask again.")
        }
        var account = account
        if let startWhen {
            draft.job.startWhen = startWhen.isEmpty ? nil : try StartWhen.checked(startWhen, job: id, jobs: startWhenLookup.job, accounts: accounts.accounts)
        }
        if let waitsOn = draft.job.startWhen?.compactMap(\.account).first { account = waitsOn }
        draft.job = try Self.edit(draft.job, branch: branch, account: accounts.state(account), rounds: rounds, check: check)
        if let files { draft.job.files = try Claims.validated(files) }
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
        // Out before the job ends, so it's ended by its own stop, after the grace for its turn.
        let agent = agents.removeValue(forKey: id)
        finish(id, .stopped, "Stopped by you.")
        if let agent { halt(agent) }
    }

    /// Asks an agent that no longer speaks for its job to stop, and keeps it until its own stop
    /// has ended it, so quitting ends it too.
    private func halt(_ agent: any AgentRun) {
        agent.stop()
        let key = ObjectIdentifier(agent)
        stopping[key] = agent
        Task {
            try? await Task.sleep(for: .seconds(Halt.grace + Halt.stopping))
            stopping[key] = nil
        }
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

    /// The user moves a job to another tool, account or model (`Moves.choose` picks and checks
    /// where). It keeps its id, worktree, branch and history, and notes the move. A queued job
    /// starts there; a running one's agent is stopped and, once it and any check of its have ended,
    /// the round starts over there with a new session, hearing the work so far and why it moved; a
    /// finished one's next round runs there.
    /// Not Oby's own reviews, and not a job that's wrapping up or publishing.
    @discardableResult
    func move(_ id: String, to target: MoveTarget, why: String? = nil) throws -> Job {
        guard let job = job(id) else { throw Shell.Failure(message: "There's no job \(id).") }
        guard job.reviewOf == nil else { throw Shell.Failure(message: "Oby's own reviews pick their account themselves.") }
        guard !finishing.contains(id), !(job.isActive && ending.contains(id)) else {
            throw Shell.Failure(message: "\(job.agentName) is wrapping up. Move it once it's done.")
        }
        let (account, model) = try Moves.choose(job, to: target, accounts: accounts.accounts)
        let reason = why.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)) }.flatMap { $0.isEmpty ? nil : $0 }
        let from = Moves.place(job, accounts: accounts.accounts)
        var moved = job
        moved.account = account.id
        moved.agent = account.agent
        moved.model = model
        let to = Moves.place(moved, accounts: accounts.accounts)
        moved.moves = (job.moves ?? []) + [Job.Move(from: from, to: to, why: reason, date: .now)]
        // Waiting on the room of an account it left: it runs where it went (#216). A new model alone keeps its wait.
        if moved.account != job.account { moved.startWhen = Self.movedStartWhen(moved.startWhen, leaving: job.account) }
        // Sessions belong to a tool and an account: the next round starts a new one.
        moved.session = nil
        Logger.jobs.notice("job \(id, privacy: .public): moved from \(from, privacy: .public) to \(to, privacy: .public)")
        guard job.status == .running else {
            replace(moved)
            // Waiting to start: nothing left to wait for starts it, else it waits for the rest there.
            if moved.startWhen?.isEmpty == true { try startNow(id) } else if scheduled.contains(id) { startOrWait(moved, catchUp: true) }
            return self.job(id) ?? moved
        }
        // Dropped before it's stopped, so nothing it says as it ends counts; a check under way ends too.
        let leaving = agents.removeValue(forKey: id)
        if let leaving { halt(leaving) }
        let check = afterTurns.removeValue(forKey: id)
        check?.cancel()
        handoffs[id, default: []].append("Moved from \(from) to \(to) by you.")
        moved.question = nil
        moved.phase = .work
        moved.step = "Moving to \(to)"
        replace(moved)
        pickedUp.remove(id)
        let round = roundMessage[id], count = moved.moves?.count
        let earlier = handovers[id]
        handovers[id] = Task { [weak self] in
            // The agent it left and its check work in the same worktree: the new agent starts only
            // once they (and a move before this one) have ended, so their edits can't cross.
            await earlier?.value
            await leaving?.ended()
            await check?.value
            guard let self, self.job(id)?.moves?.count == count else { return }
            self.handovers[id] = nil
            // Stopped meanwhile, or another agent took it.
            guard var latest = self.job(id), latest.status == .running, self.agents[id] == nil else { return }
            latest.step = "Moved to \(to)"
            self.replace(latest)
            self.run(latest, prompt: Prompts.moved(latest, from: from, why: reason, round: round, apple: self.offersAppleChecks))
        }
        return moved
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
        // Waiting for its answer since the runner restarted: no agent hears it, so the answer
        // picks its session up again, in the same round (#206).
        let waiting = job.isActive && job.question != nil && agents[id] == nil && updateWaiting[id] == nil && handovers[id] == nil
        if job.isActive && !waiting {
            let held = updateWaiting[id]
            guard let agent = agents[id], !ending.contains(id) else {
                if let held {
                    // Its message waits for the update: the words join it, neither replaces the other.
                    _ = try vault.forAgent(text)
                    replace(Self.heard(job, text))
                    restarts?.give(id, text, adding: true)
                    updateWaiting[id]?.prompt = [held.prompt, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    return
                }
                if handovers[id] != nil { throw Shell.Failure(message: "It's moving to \(job.agentName). Tell it again in a moment.") }
                throw Shell.Failure(message: job.status == .queued ? "\(job.agentName) hasn't started yet. Tell it again in a moment."
                                    : "\(job.agentName) is wrapping up. Tell it again once it's done.")
            }
            let said = try vault.forAgent(text)
            replace(Self.heard(job, text))
            let betweenTurns = roundTimers[id] == nil || job.question != nil
            // Words between turns (while the check runs) start a turn: it gets a round timer too.
            if roundTimers[id] == nil { timeRound(id) }
            restarts?.give(id, text, adding: true)
            if drainingForUpdate && betweenTurns {
                agents.removeValue(forKey: id)?.kill()
                roundTimers.removeValue(forKey: id)?.cancel()
                updateWaiting[id] = (self.job(id) ?? job, text, job.session, nil)
            } else { agent.send(said) }
        } else {
            // Moved since its last round: a new session on the new choice takes it over.
            let moved = job.session == nil && job.started != nil ? job.moves?.last : nil
            guard job.session != nil || moved != nil else { throw Shell.Failure(message: "This job never started, so there's no session to pick up.") }
            // Nothing is picked up while the vault can't be read: the user hears why.
            _ = try vault.forAgents()
            let resumed = waiting ? Self.heard(job, text) : Self.resumed(job, text)
            replace(resumed)
            if let author = resumed.reviewOf { reconnect(review: id, to: author) }
            // A round the user asked for. Not an answer: its round goes on, checked as it would be live.
            if !waiting { asked.insert(id) }
            roundMessage[id] = nil
            // One the runner kept going down with still has the message it was about to get: it comes first.
            let prompt = [restarts?.message(id), text].compactMap { $0 }.joined(separator: "\n\n")
            if let moved {
                run(resumed, prompt: Prompts.moved(resumed, from: moved.from, why: moved.why, round: prompt, apple: offersAppleChecks))
            } else {
                run(resumed, prompt: prompt, resume: job.session)
            }
        }
    }

    /// A review that ended with no verdict runs again (Try again from the inbox, or the user's
    /// words): it's its author's review once more, so its verdict counts when it ends
    /// (`reviewEnded`). Not when the author has a review under way, this one's verdict already
    /// counted, or a newer review of the author's came since.
    private func reconnect(review id: String, to authorID: String) {
        guard var author = job(authorID), author.reviewing == nil, author.review?.job != id,
              jobs.filter({ $0.reviewOf == authorID }).max(by: { $0.created < $1.created })?.id == id else { return }
        author.reviewing = id
        author.reviewError = nil
        replace(author)
    }

    /// The job with the user's words saved, and shown as its step until the agent moves on.
    nonisolated static func heard(_ job: Job, _ text: String) -> Job {
        var job = job
        job.notes = (job.notes ?? []) + [text]
        job.step = "You: \(text)"
        // An answer to its question, or words that take its place.
        job.question = nil
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
        job.limit = nil
        return job
    }

    /// Oby is quitting: agents end now, and their jobs show as interrupted next time (the runner's
    /// carry on, `resumeAfterRestart`). Returns once what they started is gone too, at most
    /// `Halt.dropping` from now. `planned` (the runner's own update) isn't counted as a crash when
    /// its jobs are picked up again.
    func quit(planned: Bool = false) {
        if planned { restarts?.planRestart(active.map(\.id)) }
        for (id, agent) in agents {
            agent.kill()
            // On the runner it stays queued or running on disk, its message with it: the next start picks it up.
            if restarts == nil { finish(id, .interrupted, "Oby quit while this was running.") }
        }
        // Stopped a moment ago: its stop would end it after the grace, which is past Oby's exit.
        for agent in stopping.values { agent.kill() }
        stopping = [:]
        Halt.settle()
    }

    /// The job, however old (#223): the list's, else the store's.
    func job(_ id: String) -> Job? { jobs.first { $0.id == id } ?? store.job(id) }

    /// Whether the list holds the job. `replace` brings one only in the store onto the list.
    func lists(_ id: String) -> Bool { jobs.contains { $0.id == id } }

    private func start(_ prepared: Job) {
        if drainingForUpdate {
            var queued = prepared
            queued.step = "Waiting for runner update"
            replace(queued)
            if !waiting.contains(where: { $0.id == prepared.id }) { waiting.append(prepared) }
            return
        }
        var job = prepared
        job.status = .running
        job.phase = .work
        job.started = .now
        job.step = "Starting \(job.agentName)"
        replace(job)
        // The jobs in flight on the same files, for its agent to know about (#237).
        let alongside = jobs.filter { $0.id != job.id && $0.holdsClaim && !Self.overlap(job, $0).isEmpty }
        run(job, prompt: Prompts.agent(job, apple: offersAppleChecks, alongside: alongside))
    }

    /// Starts the job's agent in its worktree: a new session, or the job's own picked up again.
    /// The agent hears `notice` first, when there's one: then `prompt` is what was pending already.
    func run(_ job: Job, prompt: String, resume: String? = nil, notice: String? = nil) {
        // What the agent is about to get stays on disk until its turn ends (Engine/Restarts.swift).
        if notice == nil { restarts?.give(job.id, prompt) }
        if drainingForUpdate {
            agents.removeValue(forKey: job.id)?.kill()
            roundTimers.removeValue(forKey: job.id)?.cancel()
            jobTimers.removeValue(forKey: job.id)?.cancel()
            updateWaiting[job.id] = (job, prompt, resume, notice)
            return
        }
        // No vault secret reaches an agent, even one the user typed into the request; and when the
        // vault can't be read, no agent starts, and the job says why.
        let said: String
        do {
            said = try vault.forAgent([notice, prompt].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        } catch {
            return finish(job.id, .failed, "\(job.agentName) didn't start: \(error.localizedDescription)")
        }
        let home = accounts.state(job.account)?.account.home.map { URL(filePath: $0) }
        guard let agent = makeAgent(job, home, resume) else { return finish(job.id, .failed, "\(job.agentName) can't run jobs yet.") }
        agents[job.id] = agent
        ranHere[job.id] = (job.commits ?? 0, job.unpublished)
        (agent as? ClaudeAgent)?.maxTurns = limits.maxTurns
        // A new round, or one done over on another account: its own timer. The job's cap runs from
        // its first round until it ends.
        timeRound(job.id)
        if jobTimers[job.id] == nil {
            jobTimers[job.id] = after(limits.job) { [weak self] in self?.hold(job.id, "the job ran past \(JobLimits.span($0))") }
        }
        do {
            // Only the job's current agent speaks for it: one that was stopped or ended may still report.
            try agent.start(prompt: said) { [weak self, weak agent] event in
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
        case .permission(let denied):
            guard let denied else { denials[id] = nil; return }
            let count = (denials[id] ?? 0) + 1
            denials[id] = count
            if count >= limits.denials { hold(id, "\(count) actions in a row were denied", "The last one: \(denied)") }
        case .maxTurns:
            hold(id, "\(job.agentName) used its \(limits.maxTurns) turns in one round")
        case .tetrix(let seen):
            job.tetrix = (job.tetrix ?? TetrixUse()).noting(seen)
            if case .connected = seen { accounts.setTetrix(job.tetrix?.connected, for: job.account) }
            replace(job, save: false)
        case .turnEnded(let summary, let failed):
            roundTimers.removeValue(forKey: id)?.cancel()
            restarts?.took(id)
            job.summaries = (job.summaries ?? []) + [summary]
            job.tetrix?.endRound()
            // A question for the user (case I.1): the job waits for the answer, its agent idle, and
            // the inbox has it. The answer comes as its next message (`message`); others keep going.
            if !failed, let question = Inbox.question(in: summary) {
                job.question = question
                job.step = "Waiting for your answer"
                return replace(job)
            }
            replace(job)
            // One turn and no check: the job ends when the agent does, after any background work.
            guard job.loops else {
                ending.insert(id)
                agents[id]?.end()
                return
            }
            let heard = job.notes?.count ?? 0
            // A check still running for an earlier turn (the user's words started this one) is over.
            afterTurns[id]?.cancel()
            afterTurns[id] = Task { await afterTurn(id, summary: summary, failed: failed, heard: heard) }
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
            run(job, prompt: "", resume: session, notice: Self.cutOff)
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
        guard let route = AccountStore.next(accounts.accounts, agent: job.agent) else {
            let first = accounts.accounts.filter(\.signedIn).compactMap(\.fullUntil).min()
            let soonest = first.map { " The first resets at \(Limits.clock($0))." } ?? ""
            Logger.jobs.error("job \(id, privacy: .public): \(from, privacy: .public) hit its limit, and no account has room")
            limited.insert(id)
            return finish(id, .failed, "\(from) hit its usage limit\(when), and no other account has room.\(soonest)")
        }
        let next = route.account
        Logger.jobs.notice("job \(id, privacy: .public): \(from, privacy: .public) hit its limit\(when, privacy: .public); continuing on \(next.heading, privacy: .public)")
        handoffs[id, default: []].append("\(from) hit its limit\(when); continued on \(next.heading): \(route.reason).")
        var moved = job
        moved.account = next.id
        moved.agent = next.agent
        moved.session = nil
        // The stronger model is the tool's own.
        if moved.model != nil { moved.model = AgentModels.stronger[next.agent] }
        moved.step = "\(from) hit its limit; continuing on \(next.heading)"
        replace(moved)
        pickedUp.remove(id)
        run(moved, prompt: Prompts.takeover(moved, from: from, round: roundMessage[id], apple: offersAppleChecks))
    }

    /// Runs the job's check, if it has one, then ends the job or sends the agent another round.
    /// `heard` is how many of the user's words the turn had taken in.
    private func afterTurn(_ id: String, summary: String, failed: Bool, heard: Int) async {
        guard var job = job(id), job.isActive, let agent = agents[id] else { return }
        // Still this turn's work: not cancelled (a newer turn, or the job moved to another agent),
        // and the agent it's for still speaks for the job. Asked after every wait.
        let current = { [weak self] in !Task.isCancelled && self?.agents[id] === agent }
        var check: Rounds.Check?
        if let command = job.check, !failed {
            do {
                // Stopped or moved while the check ran.
                guard let result = try await checkWork(id, command, current: current), let checked = self.job(id) else { return }
                job = checked
                check = result
            } catch {
                agent.end()
                return finish(id, .failed, "The check didn't run: \(error.localizedDescription)")
            }
        }
        // The user spoke since the turn ended: the agent took it up, and that turn decides.
        guard (job.notes?.count ?? 0) == heard else { return }
        var next = Rounds.next(job, summary: summary, failed: failed, check: check, previous: failures[id])
        // Done with its work left uncommitted, and rounds left: one more round to commit it (#220).
        if case .finish(.done, _) = next {
            let files = await uncommitted(job)
            // Superseded while git looked (the user's words, another agent): that turn decides, whatever git said.
            guard current(), let latest = self.job(id), latest.isActive, (latest.notes?.count ?? 0) == heard else { return }
            job = latest
            if let files {
                committingRound.insert(id)
                next = .again(Prompts.commitRound(job, files: files))
            }
        }
        switch next {
        case let .finish(status, text):
            agent.end()
            finish(id, status, text)
        case let .again(message):
            let message = TetrixUse.remind(&job, message)
            let said: String
            do {
                said = try vault.forAgent(message)
            } catch {
                agent.end()
                return finish(id, .failed, error.localizedDescription)
            }
            failures[id] = check.map(Fingerprint.of)
            job.round = job.currentRound + 1
            job.phase = .work
            job.step = "Round \(job.currentRound) of \(job.maxRounds)"
            replace(job)
            roundMessage[id] = message
            restarts?.give(id, message)
            if drainingForUpdate {
                agents.removeValue(forKey: id)?.kill()
                roundTimers.removeValue(forKey: id)?.cancel()
                jobTimers.removeValue(forKey: id)?.cancel()
                updateWaiting[id] = (job, message, job.session, nil)
            } else {
                timeRound(id)
                agent.send(said)
            }
        case let .hold(limit, text):
            hold(id, limit, text)
        }
    }

    /// The files a committing job that's done left uncommitted, when it made no commits and has a
    /// round left for them: nil once it had its commit round, or for a round the user asked for.
    private func uncommitted(_ job: Job) async -> [String]? {
        guard Job.committing.contains(job.kind), let base = job.base, job.currentRound < job.maxRounds,
              !asked.contains(job.id), !committingRound.contains(job.id) else { return nil }
        let made = await countCommits(job.id, job.pr.map { "refs/oby/pr-\($0)" } ?? "refs/remotes/origin/\(base)")
        guard made == 0 else { return nil }
        let files = await changedFiles(job.id)
        return files.isEmpty ? nil : files
    }

    /// Runs job `id`'s check in its worktree, then compares its tests with where the branch started
    /// (case 3.2). Nil once `current` no longer holds (stopped, moved, a newer turn); throws when
    /// the check can't run.
    private func checkWork(_ id: String, _ command: String, current: () -> Bool) async throws -> Rounds.Check? {
        guard var job = job(id), job.isActive else { return nil }
        job.phase = .check
        job.step = "Checking: \(command)"
        replace(job)
        // The check runs the agent's code: it gets no variable that holds a vault secret, and doesn't run when the vault can't be read.
        // It has the agent's `oby-check apple`, waiting for the Mac up to the check's time limit (#68).
        let env = try Agents.overrides(vault: vault)
            .merging(AppleCheck.environment(worktree: Workspace.worktree(id), tool: appleTool(), wait: limits.testRun)) { $1 }
        let started = Date.now
        var result = await runCheck(id, command, limits.testRun, env)
        // No Mac took the Apple check it asked for (#68): the Apple apps weren't built, and the
        // rest of the command still decides. When it failed, it runs again without `oby-check`'s build.
        if appleUnbuilt(id, since: started) {
            if !result.passed, current(), var again = self.job(id), again.isActive {
                again.step = "Checking without the Apple build: \(command)"
                replace(again, save: false)
                result = await runCheck(id, command, limits.testRun, env.merging([AppleCheck.skipVariable: "1"]) { $1 })
            }
            result.appleUnbuilt = true
        }
        guard current(), var latest = self.job(id), latest.isActive else { return nil }
        // Oby compares the tests with where the branch started too: weakening them fails the round (case 3.2).
        latest.step = "Comparing the tests with where the branch started"
        replace(latest, save: false)
        let report = await integrity(latest)
        (result.problems, result.notes) = (report.problems, report.notes)
        guard current(), self.job(id)?.isActive == true else { return nil }
        return result
    }

    /// Starts the job's round timer over.
    private func timeRound(_ id: String) {
        roundTimers[id]?.cancel()
        roundTimers[id] = RoundTimer(clock: RoundClock(limit: limits.round, started: .now))
        paceRound(id)
    }

    /// Keeps job `id`'s round clock in step with its agent's Apple check (#203): it stands still
    /// while the agent waits for a check it asked for (`MacCheck.agentWaits`), and runs again once
    /// the check answers. Called whenever the job's Apple check changes.
    func paceRound(_ id: String, now: Date = .now) {
        guard var timer = roundTimers[id] else { return }
        if job(id)?.appleCheck?.agentWaits == true { timer.clock.pause(at: now) } else { timer.clock.resume(at: now) }
        guard timer.task == nil || timer.clock != roundTimers[id]?.clock else { return }
        timer.task?.cancel()
        timer.task = nil
        // Standing still, nothing runs out until the check answers.
        if !timer.clock.standing {
            let clock = timer.clock
            timer.task = after(max(0, clock.left(at: now))) { [weak self] _ in
                guard let self, self.roundTimers[id]?.clock == clock else { return }
                self.roundRanOut(id, after: clock.limit)
            }
        }
        roundTimers[id] = timer
    }

    /// Job `id`'s round ran out (case 3.1). When its work is all committed and the job's check
    /// passes on its last commit, it ends done and publishes as any finished job does (#203): the
    /// review still gates the merge. Otherwise, or with no check to run, it's held. Its agent is
    /// stopped and ended first, so nothing changes the worktree while the check runs.
    private func roundRanOut(_ id: String, after seconds: TimeInterval) {
        let limit = "the round ran past \(JobLimits.span(seconds))"
        guard let job = job(id), job.isActive, !finishing.contains(id), !ending.contains(id),
              let command = job.check, let agent = agents.removeValue(forKey: id) else { return hold(id, limit) }
        Logger.jobs.notice("job \(id, privacy: .public): \(limit, privacy: .public); checking its last commit")
        roundTimers.removeValue(forKey: id)?.cancel()
        afterTurns.removeValue(forKey: id)?.cancel()
        // Out of `agents` first: nothing it says as it stops counts.
        halt(agent)
        var stopped = job
        stopped.step = "The round ran out: checking its last commit"
        replace(stopped, save: false)
        let summary = job.summaries?.last
        afterTurns[id] = Task {
            await agent.ended()
            let current = { [weak self] in !Task.isCancelled && self?.job(id)?.isActive == true }
            let why = await self.unfinished(id)
            guard current() else { return }
            if let why { return self.hold(id, limit, Self.withSummary(why, summary)) }
            let check: Rounds.Check
            do {
                guard let result = try await self.checkWork(id, command, current: current) else { return }
                check = result
            } catch {
                return self.hold(id, limit, Self.withSummary("The check didn't run on its last commit: \(error.localizedDescription)", summary))
            }
            guard check.succeeded else {
                let failed = check.passed ? "it weakens the tests" : "`\(command)` fails on its last commit"
                return self.hold(id, limit, Self.withSummary("Oby checked the work when the round ran out, and \(failed).", summary))
            }
            self.finish(id, .done, Rounds.atLimit(after: seconds, agent: job.agentName, check: check, summary: summary))
        }
    }

    /// Why job `id`'s work can't go out as it is when its round ran out, or nil when it can be
    /// checked: nothing committed since it started, work left uncommitted, or its agent's Apple
    /// check of the last commit failed.
    private func unfinished(_ id: String) async -> String? {
        let head = await worktreeHead(id)
        guard let status = await worktreeStatus(id) else { return "Oby couldn't read its worktree's status." }
        guard let job = job(id) else { return nil }
        if head == nil || head == job.startCommit { return "It has no commits to check." }
        if !status.isEmpty { return "It left work uncommitted." }
        if let apple = job.appleRan, apple.head == head, apple.state == .failed { return "Its Apple check of the last commit failed." }
        return nil
    }

    nonisolated static func withSummary(_ text: String, _ summary: String?) -> String {
        [text, summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Calls `then` with `seconds` once they've passed, unless the task is cancelled first.
    private func after(_ seconds: TimeInterval, _ then: @escaping (TimeInterval) -> Void) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { then(seconds) }
        }
    }

    /// The job stopped at one of Oby's limits (case 3.1): its agent is stopped, and it ends
    /// `failed` with the limit, keeping its branch and pushing nothing. One more round is possible:
    /// telling it something runs one. `summary` is what to add, else the agent's last round summary.
    /// Not once it's publishing: that's past every round.
    private func hold(_ id: String, _ limit: String, _ summary: String? = nil) {
        guard var job = job(id), job.isActive, !finishing.contains(id) else { return }
        Logger.jobs.notice("job \(id, privacy: .public) stopped at a limit: \(limit, privacy: .public)")
        let agent = agents[id]
        job.limit = limit
        replace(job, save: false)
        end(id, .failed, Rounds.held(limit, summary: summary ?? job.summaries?.last))
        agent?.stop()
    }

    /// Ends the job. A job that's done counts its commits first, so one that should have committed
    /// and didn't ends as "nothing committed" rather than done. One that's done with commits its
    /// pull request doesn't have yet, made since its agent started in this run of Oby, publishes
    /// them before it ends (case 4.1): commits already on the base by patch leave nothing to
    /// publish; a possible secret fails it, naming where; any other failure leaves it done, with
    /// the reason and Publish offered.
    func finish(_ id: String, _ status: Job.Status, _ summary: String) {
        guard var job = job(id), job.isActive else { return }
        // Its agent ended while its question waits: the work isn't finished, so nothing is checked
        // or published. It's interrupted, keeping its question; the answer picks its session up again.
        if status == .done, job.question != nil { return end(id, .interrupted, summary) }
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
            // A pull request's branch has its own commits beyond the base: only the ones after its head
            // are the job's, on a job started from its head too.
            let from = job.pr ?? job.fromPR
            let made = from == nil ? commits : await countCommits(id, "refs/oby/pr-\(from ?? 0)")
            let pushed = await stillPushed(job, base: base, commits: commits)
            // Nothing committed: what it left uncommitted is why (#220).
            let dirty = made == 0 && Job.committing.contains(job.kind) ? await changedFiles(id) : []
            await noteTetrixStamps(id)
            guard var running = self.job(id), running.isActive else { return }
            // The job as it would end, which is what gets published.
            var ended = running
            (ended.status, ended.summary) = Job.ending(ended, status, summary, made: made, asked: asked.contains(id), dirty: dirty)
            ended.commits = commits
            ended.pushed = pushed
            guard ended.canPublish, let before = ranHere[id], (commits ?? 0) > before.commits || ended.unpublished > before.unpublished else {
                // Still waiting for Publish by hand: why its own publish failed still holds.
                return end(id, status, summary, commits: commits, pushed: pushed, made: made, dirty: dirty,
                           publishError: ended.canPublish ? ended.publishError : nil)
            }
            running.phase = .publish
            running.publishStep = .scan
            running.step = "Publishing"
            replace(running)
            do {
                let url = try await publishOnItsOwn(ended, base, hooks(id, stoppable: true))
                end(id, status, summary, commits: commits, pushed: pushed, made: made, published: url)
            } catch let merged as Publish.AlreadyOnBase {
                // Merged already (a squash merge changes the hashes): nothing is left to publish.
                end(id, status, (merged.errorDescription ?? "Not published.") + "\n\n" + ended.summary, commits: 0, made: made)
            } catch let blocked as Publish.Blocked {
                end(id, .failed, (blocked.errorDescription ?? "Not published.") + "\n\n" + ended.summary, commits: commits, pushed: pushed, made: made)
            } catch {
                end(id, status, summary, commits: commits, pushed: pushed, made: made, publishError: error.localizedDescription)
            }
        }
    }

    /// How many of the job's `commits` beyond `base` its pull request has: those in the commit Oby
    /// pushed last. A rebase rewrites them, so then it's none, and they're published again. The
    /// count from its last publish when there's no pushed commit to compare with or git can't say.
    private func stillPushed(_ job: Job, base: String, commits: Int?) async -> Int? {
        guard job.published != nil, let head = job.pushedHead, let commits,
              let unpushed = await countUnpushed(job.id, "refs/remotes/origin/\(base)", head) else { return job.pushed }
        return max(0, commits - unpushed)
    }

    /// `commits`: beyond the base, what Publish would push, and `pushed`, how many of them its pull
    /// request has. `made`: the ones this job made. `published`: the pull request it just published
    /// to, or `publishError`, why it couldn't.
    private func end(_ id: String, _ status: Job.Status, _ summary: String, commits: Int? = nil, pushed: Int? = nil, made: Int? = nil,
                     dirty: [String] = [], published: URL? = nil, publishError: String? = nil) {
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
        (job.status, job.summary) = Job.ending(job, status, summary, made: made, asked: asked.contains(id), dirty: dirty)
        if job.status == .failed && status == .done { job.phase = .work }
        // Why it went to its account, and how it moved between accounts, for the report.
        if let moves = handoffs[id], !moves.isEmpty { job.summary += "\n\n" + moves.joined(separator: "\n") }
        // What it asked Tetrix and saved there. Not on a review, whose last line is its verdict.
        if job.reviewOf == nil, let tetrix = TetrixUse.report(job) { job.summary += "\n\n" + tetrix }
        job.commits = commits
        if let pushed { job.pushed = pushed }
        // After commits, so it counts them as pushed. A new head starts its review, check and merge
        // over: why the last merge stopped (a conflict a rebase resolved) is past.
        if let published {
            job.pullRequest = nil
            job.pullRequestError = nil
            job.published = published.absoluteString
            job.mergeError = nil
        }
        job.publishError = publishError
        // A rebase round ends here: what it published is weighed once (`reviewOrCheck`).
        let rebasedFrom = job.rebasedFrom
        job.rebasedFrom = nil
        job.step = ""
        job.finished = .now
        replace(job)
        // Its agent goes with it: one still finishing after its last turn (a check passed, a round
        // limit) ends with what it started, rather than outlive its job.
        agents.removeValue(forKey: id)?.kill()
        ranHere[id] = nil
        pickedUp.remove(id)
        ending.remove(id)
        asked.remove(id)
        committingRound.remove(id)
        roundMessage[id] = nil
        handoffs[id] = nil
        restarts?.forget(id)
        roundTimers.removeValue(forKey: id)?.cancel()
        jobTimers.removeValue(forKey: id)?.cancel()
        afterTurns.removeValue(forKey: id)?.cancel()
        failures[id] = nil
        denials[id] = nil
        limited.remove(id)
        waiting.removeAll { $0.id == id }
        // Oby reviews what was just published (or, after a rebase that changed nothing else, checks
        // it on a Mac), and a review that ended reaches its author (Engine/Review.swift).
        if published != nil { reviewOrCheck(job, rebasedFrom: rebasedFrom) }
        if job.reviewOf != nil { reviewEnded(job) }
        onFinish(job)
        // A job waiting for a slot takes this one's (#237).
        releaseWaiting()
        // Jobs waiting for this one to end look now, not at their next minute (#216).
        if !scheduled.isEmpty { Task { await checkStartWhen() } }
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
        guard var latest = job(id), latest.published == published, latest.pushed == pushed else { return }
        if let status { latest.pullRequest = status }
        latest.pullRequestError = error
        if lists(id) { replace(latest) }
        else { store.save(latest); onJobChange(latest); issueSync.observe(latest) }
    }

    func replace(_ job: Job, save: Bool = true) {
        // A job only in the store, however old (#223), joins the list at the end with the older
        // ones when something changes it (dismissed, told something, moved), and is kept as any other.
        if !lists(job.id), let stored = store.job(job.id) { jobs.append(stored) }
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        var job = job
        // Only a queued job waits for something (#238).
        if job.status != .queued { job.waiting = nil }
        let tookSlot = jobs[index].takesSlot
        jobs[index] = job
        if save { store.save(job) }
        onJobChange(job)
        issueSync.observe(job)
        // Where a job ends or a stage fails: the failure is recorded and studied.
        failureLog.observe(job)
        // A step changes nothing the user must answer.
        if save { syncInbox(job) }
        // It ended, or waits for the user's answer: a waiting job takes its slot (#237).
        if tookSlot && !job.takesSlot { releaseWaiting() }
    }

    // MARK: The inbox

    /// How the user settles an inbox item: an answer (one of its options, or their own words),
    /// done without one, or later.
    enum Settle: Equatable {
        case answer(String)
        case done
        case later(Date)
    }

    /// The job's items as it is now: what it needs comes in (once: an item that's done stays done),
    /// and what it needs no more is done by itself (it runs again, was dismissed, answered elsewhere).
    private func syncInbox(_ job: Job) {
        let need = Inbox.need(of: job, limited: limited.contains(job.id))
        for index in inbox.indices where inbox[index].job == job.id && inbox[index].isOpen && inbox[index].id != need?.id {
            inbox[index].done = .now
            store.save(inbox[index])
            onInboxChange(inbox[index])
        }
        guard let need, !inbox.contains(where: { $0.id == need.id }) else { return }
        add(need)
    }

    func addIssueAudit(_ item: InboxItem) { add(item) }

    /// A new item: one open item per job, so a newer one settles the older, with no answer. Of the
    /// items with no job, audits share one; failures keep one open per signature (Engine/Failures.swift).
    /// Then it's rewritten in plain words, without waiting for it.
    private func add(_ item: InboxItem) {
        let shares = { (other: InboxItem) in
            other.job == item.job && (!item.job.isEmpty || (item.kind == .audit && other.kind == .audit))
        }
        for index in inbox.indices where shares(inbox[index]) && inbox[index].isOpen && inbox[index].id != item.id {
            inbox[index].done = .now
            store.save(inbox[index])
            onInboxChange(inbox[index])
        }
        inbox.append(item)
        store.save(item)
        onInboxChange(item)
        rewrite(item)
    }

    /// Rewrites an open item in plain words in the background (`InboxRewriter`), once per id and
    /// text, and applies it if the item still says the same; on failure it keeps its text.
    private func rewrite(_ item: InboxItem) {
        guard rewritesInbox, item.isOpen else { return }
        let key = item.id + "\n" + item.text
        if let cached = rewrites[key] { return apply(cached, to: item) }
        guard !rewriting.contains(key) else { return }
        rewriting.insert(key)
        // The brain's model, on the least busy Claude account, as the brain thinks.
        let thinker = AccountStore.route(accounts.accounts, agent: "claude")
        let rewriter = InboxRewriter(adapters: makeBrain(thinker?.home, vault), timeout: rewritePatience)
        Task {
            let rewrite = await rewriter.rewrite(item)
            rewriting.remove(key)
            guard let rewrite else { return }
            rewrites[key] = rewrite
            apply(rewrite, to: item)
        }
    }

    private func apply(_ rewrite: InboxRewrite, to item: InboxItem) {
        guard let index = inbox.firstIndex(where: { $0.id == item.id && $0.text == item.text }) else { return }
        inbox[index].headline = rewrite.headline
        inbox[index].happened = rewrite.happened
        inbox[index].recommended = rewrite.recommended
        inbox[index].why = rewrite.why
        store.save(inbox[index])
        onInboxChange(inbox[index])
    }

    func item(_ id: String) -> InboxItem? { inbox.first { $0.id == id } }

    /// The user settles an inbox item. An answer goes to its job: a question's answer as the
    /// agent's next message; Dismiss lets the job go; Try again (or their own words) runs it
    /// again; One more round hands the agent Oby's last review. Returns the item.
    @discardableResult
    func settle(_ id: String, _ how: Settle) throws -> InboxItem {
        guard var item = item(id) else { throw Shell.Failure(message: "There's no inbox item \(id).") }
        guard item.isOpen else { throw Shell.Failure(message: "That's done already.") }
        switch how {
        case .later(let date):
            item.later = date
        case .done:
            item.done = .now
        case .answer(let words):
            let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...2000).contains(text.count) else { throw Shell.Failure(message: "Answer with 1 to 2,000 characters.") }
            switch (item.kind, text) {
            case (.failed, Inbox.dismiss), (.limit, Inbox.dismiss), (.review, Inbox.dismiss), (.merge, Inbox.dismiss): try dismiss(item.job)
            case (.failed, Inbox.oneMoreRound) where job(item.job)?.cloudNeedsYou == true: try oneMoreCloudRound(item.job)
            case (.failed, Inbox.askOby) where job(item.job)?.cloudNeedsYou == true: try askAboutCloud(item.job)
            case (.merge, Inbox.tryAgain): try retryMerge(item.job)
            case (.merge, Inbox.oneMoreRound): try oneMoreMergeRound(item.job)
            case (.failed, Inbox.tryAgain), (.limit, Inbox.tryAgain), (.failed, Inbox.oneMoreRound): try message(item.job, Inbox.tryAgainMessage)
            case (.review, Inbox.oneMoreRound): try message(item.job, reviewAgain(item.job))
            case (.question, _) where asksAboutStart(item.job): try decideStart(item.job, text)
            default: try message(item.job, text)
            }
            // The job moved on, which settled the item already; the answer is what settled it.
            item = self.item(id) ?? item
            item.done = item.done ?? .now
            item.answer = text
        }
        guard let index = inbox.firstIndex(where: { $0.id == id }) else { return item }
        inbox[index] = item
        store.save(item)
        onInboxChange(item)
        return item
    }

    /// What the agent hears for One more round, after Oby's last review: quoted in a file, as
    /// review rounds are (Engine/Review.swift), when Oby still has it.
    private func reviewAgain(_ id: String) -> String {
        let plain = "Oby's last review of your pull request requested changes. Work on them, commit, and finish with a short summary."
        guard let job = job(id), let review = job.review, let summary = self.job(review.job)?.summary,
              let pr = Review.pullRequest(of: job) else { return plain }
        let file = "review-\(review.round).md"
        guard (try? quoteReview(job, file, Review.quoted(review, summary: summary, pr: pr))) != nil else { return plain }
        return "Oby's last review of your pull request requested changes. It's quoted in .oby/inputs/\(file): work on it, commit, and finish with a short summary."
    }
}

/// A running job's round timer: its clock, and the task that looks at it next (`Desk.paceRound`).
private struct RoundTimer {
    var clock: RoundClock
    var task: Task<Void, Never>?

    func cancel() { task?.cancel() }
}

/// What happens after an agent's turn in a job that loops: the job's check decides, or the
/// agent's own last line (`GOAL MET` / `GOAL NOT MET: …`), within the job's rounds.
nonisolated enum Rounds {
    struct Check: Equatable, Sendable {
        var command: String
        var passed: Bool
        /// The end of what the command printed: what the agent needs to fix it.
        var output: String
        /// What the work does to the tests (Integrity): any of these fails the round, even when the command passed.
        var problems: [String] = []
        /// Other changes to existing tests, said when the job ends, for review.
        var notes: [String] = []
        /// The failing tests' ids, read from all of the output before it's cut to its end; nil to
        /// read them from `output`.
        var failing: [String]? = nil
        /// What each failing test said, by its id (`MacCheck.messages`), read from all of the output too.
        var said: [String: String] = [:]
        /// No Mac took the Apple check it asked for (`Desk.appleUnbuilt`): it ran, or ran again, with
        /// `oby-check` passing over the build, so it passed without the Apple build.
        var appleUnbuilt = false

        var succeeded: Bool { passed && problems.isEmpty }
    }

    enum Next: Equatable {
        case finish(Job.Status, String)
        /// Another round, with this message to the agent.
        case again(String)
        /// Stop at a limit (case 3.1): the limit, and the summary to end with.
        case hold(String, String)
    }

    /// Runs a check in the worktree, as Oby's agents run (in bubblewrap on Linux) but with no
    /// account, and ends it after `timeout` seconds: then it fails, saying so.
    /// `env` is what changes from Oby's environment: `Agents.overrides(vault:)`, so no vault secret reaches it.
    static func run(_ command: String, in worktree: URL, timeout: TimeInterval, env: [String: String?], boxed: Bool = Agents.bubblewrap) async -> Check {
        let result = try? await Shell.run(Agents.sandboxed(["sh", "-c", command], in: worktree, own: nil, bubblewrap: boxed), in: worktree,
                                          env: env, timeout: timeout)
        var output = result.map { String(decoding: $0.out, as: UTF8.self) + $0.err } ?? "Oby couldn't run it."
        if result?.timedOut == true {
            // What the agent needs to find the hang: the test it was in, and the end of what it printed (below).
            let last = MacCheck.lastStarted(in: output).map { " The last test that started: \($0)." } ?? ""
            output += "\n\nOby stopped it after \(JobLimits.span(timeout)), the most a test run may take.\(last)"
        }
        return Check(command: command, passed: result?.status == 0 && result?.timedOut == false, output: String(output.suffix(4000)),
                     failing: Fingerprint.failingTests(output), said: MacCheck.messages(in: output))
    }

    /// The failing tests, each with what it said, at most 20 of them: the output's end the agent
    /// gets may hold none of them (#185), as `swift test` prints its summary and the build's warnings last.
    static func failingTests(_ check: Check) -> [String] {
        let ids = check.failing ?? Fingerprint.failingTests(check.output)
        let named = ids.prefix(20).map { id in check.said[id].map { "\(id): \(String($0.prefix(300)))" } ?? id }
        return named + (ids.count > 20 ? ["and \(ids.count - 20) more"] : [])
    }

    /// What a check that passed says in the job's summary, with the changes to existing tests for review.
    static func checked(_ check: Check) -> String {
        // No Mac took its Apple check (#68): the rest of it passed, and the merge stage's Mac check builds the apps.
        let passed = check.appleUnbuilt ? "passed without its Apple build. " + AppleCheck.unbuiltLine : "passed."
        let notes = check.notes.isEmpty ? "" : "\n\nChanged in the existing tests, for review:\n" + check.notes.map { "- " + $0 }.joined(separator: "\n")
        return "Checked: `\(check.command)` " + passed + notes
    }

    /// The summary of a job whose round ran out with its work committed and passing (#203): it's
    /// published like a finished one. `summary` is its agent's last round summary, if any.
    static func atLimit(after seconds: TimeInterval, agent: String, check: Check, summary: String?) -> String {
        "The round ran past \(JobLimits.span(seconds)) before \(agent) finished its turn; its work was all committed and passed the check, so Oby publishes it for review."
            + "\n\n" + checked(check) + (summary.map { $0.isEmpty ? "" : "\n\nIts last round summary:\n" + $0 } ?? "")
    }

    /// The summary of a job stopped at a limit.
    static func held(_ limit: String, summary: String?) -> String {
        "Stopped at a limit: \(limit). The branch is kept and nothing was pushed; one more round is possible."
            + (summary.map { $0.isEmpty ? "" : "\n\n" + $0 } ?? "")
    }

    enum Verdict: Equatable {
        case met
        case notMet(String)
    }

    /// `previous` is the fingerprint of the round before's failure, if it failed: the same failure
    /// again stops the job (no progress).
    static func next(_ job: Job, summary: String, failed: Bool, check: Check?, previous: String? = nil) -> Next {
        let last = job.currentRound >= job.maxRounds
        let rounds = "\(job.maxRounds) round\(job.maxRounds == 1 ? "" : "s")"
        if failed { return .finish(.failed, summary) }
        if let check {
            if check.succeeded { return .finish(.done, summary + "\n\n" + checked(check)) }
            if let previous, Fingerprint.of(check) == previous { return .hold("the same failure twice in a row", summary) }
            if last {
                return .hold(check.passed ? "the tests are still weakened after \(rounds)" : "`\(check.command)` still fails after \(rounds)", summary)
            }
            var parts: [String] = []
            if !check.passed {
                parts.append("Oby ran `\(check.command)` and it failed:\n\n```\n\(check.output)\n```")
                let tests = failingTests(check)
                if !tests.isEmpty {
                    parts.append("The tests that failed, from all of what it printed (its end above may not show them):\n\n```\n"
                                 + tests.joined(separator: "\n") + "\n```")
                }
            }
            if !check.problems.isEmpty {
                parts.append("Oby compared the tests with where this branch started, and this work weakens them:\n\n"
                             + check.problems.map { "- " + $0 }.joined(separator: "\n")
                             + "\n\nPut the existing tests, skip markers and test or CI config back as they were. New tests are welcome.")
            }
            return .again(parts.joined(separator: "\n\n") + "\n\nFix it, run `\(check.command)` again yourself, and finish with a short summary.")
        }
        switch verdict(summary) {
        // No verdict line: take the agent at its word rather than loop on a missing line.
        case .met, nil: return .finish(.done, summary)
        case .notMet(let left):
            if last { return .hold("not finished after \(rounds): \(left)", summary) }
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

/// What a job claims (case 2.1, #209): the files its issue says it will touch, so each agent hears
/// which in-flight jobs touch the same code, and overlapping pull requests merge oldest first (#237).
nonisolated enum Claims {
    /// At most as many paths as a Lead's brief holds, from a client. An issue's are all kept.
    static let most = 30
    /// What a file named without a folder ends with to count as one (`Package.swift`, `README.md`).
    static let extensions: Set<String> = ["swift", "md", "json", "yml", "yaml", "toml", "plist", "pbxproj", "xcscheme", "entitlements",
                                          "strings", "xcstrings", "html", "css", "js", "mjs", "ts", "tsx", "jsx", "py", "go", "rs", "rb",
                                          "kt", "kts", "java", "gradle", "sh", "c", "h", "m", "mm", "cpp", "sql", "txt", "xml", "service"]

    /// The files an issue claims: its `Files:` line (the owner's issues carry one, paths and
    /// folders), else the paths its title and body name. Nil when they name none.
    static func files(title: String, body: String) -> [String]? {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let line = lines.last(where: { $0.firstMatch(of: /^[\s>*_]*Files[*_]*:/) != nil }),
           let listed = listed(line), !listed.isEmpty {
            return listed
        }
        let named = named(title + "\n" + body)
        return named.isEmpty ? nil : named
    }

    /// The files an issue as `gh issue view --json` has it claims.
    static func files(issue info: [String: Any]) -> [String]? {
        files(title: info["title"] as? String ?? "", body: info["body"] as? String ?? "")
    }

    /// The paths a `Files:` line lists: the ones in backticks, else what its commas separate.
    static func listed(_ line: String) -> [String]? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let rest = String(line[line.index(after: colon)...])
        let ticked = rest.matches(of: /`([^`\n]+)`/).map { String($0.1) }
        let items = !ticked.isEmpty ? ticked : rest.split(whereSeparator: { ",;".contains($0) }).flatMap { $0.components(separatedBy: " and ") }
        return unique(items.map(cleaned).filter(isPath))
    }

    /// The paths a text names: in backticks, or on their own with a folder (`Engine/Checks.swift`, `MCP/`).
    static func named(_ text: String) -> [String] {
        var found: [String] = []
        for match in text.matches(of: /`([^`\n]+)`/) {
            let token = cleaned(String(match.1))
            if isPath(token), token.contains("/") ? looksLikeFile(token) : hasExtension(token) { found.append(token) }
        }
        let bare = text.replacing(/`[^`\n]*`/, with: " ")
        for word in bare.split(whereSeparator: { $0.isWhitespace || ",;()[]<>\"'|".contains($0) }) {
            let token = cleaned(String(word))
            if token.contains("/"), isPath(token), looksLikeFile(token) { found.append(token) }
        }
        return unique(found)
    }

    /// A path inside the repository, as a word: no spaces, no URL, no `#` or `@`.
    static func isPath(_ path: String) -> Bool {
        Lead.isPath(path) && path.wholeMatch(of: /[A-Za-z0-9_.\-\/+]+/) != nil && path.contains(where: \.isLetter)
            && !path.contains("//") && !path.hasPrefix("-")
    }

    /// A path with a folder that ends in a folder (`/`) or a file with an extension: not `and/or`.
    static func looksLikeFile(_ path: String) -> Bool {
        path.hasSuffix("/") || path.split(separator: "/").last.map(String.init)?.firstMatch(of: /\.[A-Za-z][A-Za-z0-9]{0,9}$/) != nil
    }

    static func hasExtension(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return extensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// A list `files` takes from a client: at most `most` paths inside the repository, all of them
    /// checked, none dropped. Throws why not.
    static func validated(_ files: [String]) throws -> [String] {
        let paths = unique(files.map(cleaned).filter { !$0.isEmpty })
        guard paths.count <= most else { throw Shell.Failure(message: "files holds at most \(most) paths, not \(paths.count).") }
        if let bad = paths.first(where: { !Lead.isPath($0) }) { throw Shell.Failure(message: "\(bad.debugDescription) isn't a path inside the repository.") }
        return paths
    }

    private static func cleaned(_ token: String) -> String {
        var text = token.trimmingCharacters(in: .whitespaces)
        while let last = text.last, ".:!?*_".contains(last) { text.removeLast() }
        while let first = text.first, "*_".contains(first) { text.removeFirst() }
        return Lead.normalized(text)
    }

    /// Each path once, in order, every one kept: a path left out would be a file left unclaimed.
    private static func unique(_ paths: [String]) -> [String] {
        var seen: [String] = []
        for path in paths where !seen.contains(path) { seen.append(path) }
        return seen
    }
}
