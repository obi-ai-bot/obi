import Foundation
import OSLog

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
    private(set) var jobs: [Job]
    /// "Max · name@example.com", from the agent's own login.
    private(set) var accountName = "Your account"
    /// Called when a job ends, for the notch's one line.
    var onFinish: (Job) -> Void = { _ in }

    private let store = JobStore(url: Workspace.root.appending(path: "oby.sqlite"))
    private let planner = Planner()
    private var repos: [String] = []
    private var agents: [String: any AgentRun] = [:]
    /// Setting up worktrees in the same clone one at a time keeps git's locks out of the way.
    private var setups: [String: Task<Void, Never>] = [:]

    init() {
        jobs = store.recent()
        // Running when Oby last quit (or crashed): it didn't finish.
        for index in jobs.indices where jobs[index].isActive {
            jobs[index].status = .interrupted
            jobs[index].finished = jobs[index].finished ?? .now
            store.save(jobs[index])
        }
    }

    var active: [Job] { jobs.filter(\.isActive) }

    func refresh() async {
        if let repos = try? await Workspace.knownRepos(), !repos.isEmpty { self.repos = repos }
        if let status = try? await Shell.ok(["claude", "auth", "status"]),
           let json = try? JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any],
           let email = json["email"] as? String {
            let plan = (json["subscriptionType"] as? String).map { $0.capitalized + " · " } ?? ""
            accountName = plan + email
        }
    }

    // MARK: Planning

    func ask(_ words: String) {
        let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        talk = .thinking(said)
        Task {
            if repos.isEmpty { await refresh() }
            let context = BrainContext(accounts: ["claude": ["default"]], repos: repos)
            let result = await planner.plan(said, context: context)
            // Cancelled or replaced while the brain was thinking.
            guard talk == .thinking(said) else { return }
            show(result, said: said)
        }
    }

    /// The user picked one of the brain's options: plan again with the answer.
    func answer(_ option: String, said: String, question: String) {
        ask("\(said)\n\n(Oby asked: \(question) The user answered: \(option))")
    }

    func cancel() { talk = .none }

    private func show(_ result: Planner.Result, said: String) {
        let plan = result.plan
        switch plan.action {
        case .dispatch:
            guard let dispatch = plan.dispatch else { talk = .none; return }
            let id = String(UUID().uuidString.prefix(8)).lowercased()
            let job = Job(id: id, request: said, agent: dispatch.agent, account: dispatch.account, repo: dispatch.repo,
                          branch: Job.branch(kind: dispatch.kind, pr: dispatch.pr, id: id), base: dispatch.baseBranch,
                          pr: dispatch.pr, kind: dispatch.kind, task: dispatch.task)
            let reply = plan.reply.isEmpty ? "Claude Code will \(dispatch.kind.rawValue) in \(job.repoName)." : plan.reply
            talk = .plan(Draft(said: said, reply: reply, job: job, guessed: result.by == "rules"))
        case .askUser:
            talk = plan.question.map { .question(said: said, $0) } ?? .reply(plan.reply)
        case .replyOnly, .stopAgent:
            talk = .reply(plan.reply.isEmpty ? "Stop a job with the × next to it." : plan.reply)
        case .ignore:
            talk = plan.reply.isEmpty ? .none : .reply(plan.reply)
        }
    }

    // MARK: Jobs

    func dispatch(_ draft: Draft) {
        talk = .none
        var job = draft.job
        job.step = "Getting \(job.repoName) ready"
        jobs.insert(job, at: 0)
        store.save(job)

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
        job.step = "Starting Claude Code"
        replace(job)
        let agent = ClaudeAgent(worktree: Workspace.worktree(job.id))
        agents[job.id] = agent
        do {
            try agent.start(prompt: Prompts.agent(job)) { [weak self] event in self?.handle(event, job: job.id) }
        } catch {
            finish(job.id, .failed, "Claude Code didn't start: \(error.localizedDescription)")
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
            break
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
    }

    private func replace(_ job: Job, save: Bool = true) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job
        if save { store.save(job) }
    }
}
