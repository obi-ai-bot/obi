import Foundation

// The Mac compiles Engine/, whose Job is what the runner sends: it reads jobs into that one, and
// has its own Account. Only the iPhone and the watch need these copies.
#if os(iOS) || os(watchOS)
/// A job on the runner (docs/runner-api.md).
nonisolated struct Job: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case queued, running, done, failed, stopped, interrupted }

    var id: String
    var request: String
    var agent: String
    var account: String
    var repo: String
    var branch: String
    var base: String?
    var pr: Int?
    var kind: String
    var task: String
    /// What to call the job (docs/runner-api.md): the brain's short title, else the runner's
    /// fallback. Older runners don't send it.
    var title: String?
    /// Whether `GET /v1/jobs/{id}/report` has a saved research report.
    var report: Bool?
    var status: Status
    var step: String
    var summary: String
    var session: String?
    var created: Date
    var started: Date?
    var finished: Date?
    var commits: Int?
    /// Setting it (a publish from this phone) counts what went out, as the runner does.
    var published: String? { didSet { if published != nil { pushed = commits } } }
    /// Commits on the pull request when it was last published.
    var pushed: Int?
    /// Why the runner couldn't publish it by itself, or nil (newer runners only).
    var publishError: String?
    /// Newer runners only, so all optional: the issue the work is about, how many rounds the agent
    /// may take and the one it's on, the command that must pass, the stronger model it runs on,
    /// and what the user told the agent along the way, oldest first.
    var issue: Int?
    var rounds: Int?
    var round: Int?
    var check: String?
    var model: String?
    var notes: [String]?
    /// Derived by Engine and sent by newer runners; old runners still decode.
    var pipeline: JobPipeline?
    var pullRequest: PullRequestStatus?
    var pullRequestError: String?
    /// When the user let the job go (Dismiss), or nil: it then needs nothing (newer runners only).
    var dismissed: Date?
    /// Oby's own review of the pull request (newer runners): the review job under way, the latest
    /// verdict, why none came, and, on a review job, the job it reviews.
    var reviewing: String?
    var review: Review?
    var reviewError: String?
    var reviewOf: String?
    /// Everything the runner sent out for the job, oldest first (newer runners only).
    var outgoing: [Outgoing]?
    /// What its agent asked the user and waits for (the inbox has it), or nil. Older runners don't send it.
    var question: Question?
    /// Oby's merge stopped where a person takes over (the runner derives it, docs/runner-api.md "Mac
    /// check"), or nil from older runners.
    var stoppedMerge: Bool?
    /// Oby's review stopped asking for changes, where a person takes over (the runner derives it,
    /// docs/runner-api.md "Oby's review"), or nil from older runners.
    var stoppedReview: Bool?
    /// Oby's Xcode Cloud recovery stopped, where a person takes over (the runner derives it,
    /// docs/runner-api.md "Xcode Cloud"), or nil from older runners.
    var stoppedCloud: Bool?
    /// How freely its agent works ("ask", "acceptEdits", "plan" or "bypass", `RunnerMode`).
    /// Nil from older runners, and for the runner's default.
    var mode: String?
    /// What its agent waits for the user's OK on, or nil. Older runners don't send it.
    var permission: RunnerPermission?
    /// Every time the user moved it to another tool, account or model, oldest first (newer runners only).
    var moves: [Move]?
    /// What a queued job waits for (#238), or nil: getting ready, about to start, not queued, or an older runner.
    var waiting: Waiting?
    /// The conversation whose words started it (obid only, #493), or nil.
    var conversation: String?
    /// The user's turn whose words started it (obid only): its card shows under them as it starts.
    var turn: String?
    /// What it made to be looked at (obid only, its `.obi/artifacts/`), or nil.
    var artifacts: [ArtifactRef]?
    /// The job this one follows up (obid only): the owner told that one something after it ended,
    /// and its page lists this one (Sangam's design). Nil otherwise.
    var followUpOf: String?
    /// obid only (#395): the routine whose run started it, or nil.
    var routine: RoutineMark?
    /// What its agent asked Tetrix, the session it saved and where the graph fell short, or nil.
    var tetrix: TetrixJobReport?
    /// Why it stopped without ending done, apart from its agent's summary (obid only), or nil.
    var reason: String?
    /// Interrupted on obid: its one next step, as its button says it ("One more round", "Try
    /// again"), or nil.
    var nextStep: String?
    /// When obid tries it again by itself, after its account's usage limit resets, or nil; one
    /// this phone can't read is left out, never failing the job.
    var resumesAt: Lenient<Date>?
    /// `resumesAt`, read.
    var resumes: Date? { resumesAt?.value }
    /// A stalled job's why and handoff note (obid only, #773), or nil; one this phone can't read
    /// is left out, never failing the job.
    var stalled: Lenient<Stalled>?
    /// The handoff note a stalled job left, or nil.
    var handoffNote: String? { stalled?.value?.note.flatMap { $0.isEmpty ? nil : $0 } }

    /// Why and where a stalled job stopped (obid's `stalled`, #773), as far as the apps show it:
    /// its handoff note. Every key optional, so a newer obid's object still decodes.
    struct Stalled: Codable, Equatable, Sendable {
        var why: String?
        var note: String?
    }
    /// The job page's facts (#739), each nil until obid serves it: its tools, tokens, share of the
    /// limit windows, the estimate, the check's commands, the secret scan, the diff and what the
    /// current stage is doing (`JobFacts`). Each is `Lenient`: one this phone can't read is left
    /// out, never failing the job (or the list it's in).
    var activity: Lenient<JobActivity>?
    var usage: Lenient<JobUsage>?
    var windowShare: Lenient<WindowShare>?
    var estimate: Lenient<JobEstimate>?
    var checks: Lenient<[CheckRound]>?
    var scan: Lenient<JobScan>?
    var diff: Lenient<JobDiff>?
    var context: Lenient<String>?

    /// The same facts as the Mac reads them, with each stage's times.
    var facts: JobFacts {
        var stages: [String: StageTiming] = [:]
        for stage in pipeline?.stages ?? [] {
            let timing = StageTiming(started: stage.started?.value, finished: stage.finished?.value, waited: stage.waited?.value,
                                     estimate: stage.estimate?.value)
            if timing != StageTiming() { stages[stage.id] = timing }
        }
        return JobFacts(activity: activity?.value, usage: usage?.value, windowShare: windowShare?.value, estimate: estimate?.value,
                        checks: checks?.value, scan: scan?.value, diff: diff?.value, context: context?.value, stages: stages)
    }

    /// What it waits for, as the runner words it: `text` like "after #223 merges" or "runner
    /// update"; `kind` ("job", "files", "update", "cap", "schedule", "limit") stays a string so a
    /// newer runner's kinds still decode.
    struct Waiting: Codable, Equatable, Sendable {
        var kind: String
        var text: String
        var job: String?
        /// Waiting for room while only these accounts' weekly reserves stand in the way (#278), by
        /// id: "Use Personal anyway" shows on each. Newer runners only.
        var reserved: [String]?
    }

    /// Queued until what its `startWhen` names happens (#216: `waiting`'s kind `schedule` or
    /// `limit`): it can start now (`Runner.startNow`).
    var waitsToStart: Bool { status == .queued && (waiting.map { ["schedule", "limit"].contains($0.kind) } ?? false) }

    /// One move, as the runner words it: "Codex · Deskree" to "Claude Code · Personal · Fable 5.1".
    struct Move: Codable, Equatable, Sendable {
        var from: String
        var to: String
        var why: String?
        var date: Date
    }

    private enum CodingKeys: String, CodingKey {
        case id, request, agent, account, repo, branch, base, pr, kind, task, title, status, step, summary, session, created,
             started, finished, commits, published, pushed, publishError, issue, rounds, round, check, model, notes, pipeline,
             pullRequest, pullRequestError, dismissed, reviewing, review, reviewError, reviewOf, outgoing, question, mode, permission, moves, waiting, report,
             conversation, turn, artifacts, followUpOf, routine, tetrix, activity, usage, windowShare, estimate, checks, scan, diff, context,
             reason, nextStep, resumesAt, stalled
        case stoppedMerge = "mergeNeedsYou"
        case stoppedReview = "reviewNeedsYou"
        case stoppedCloud = "cloudNeedsYou"
    }

    /// "Moved from Codex · Deskree to Claude Code · Personal": its latest move, or nil (as Engine's).
    var movedLine: String? { moves?.last.map { "Moved from \($0.from) to \($0.to)" } }

    /// Its merge stopped: it couldn't merge, or the Mac check failed with no round left.
    var mergeNeedsYou: Bool { dismissed == nil && stoppedMerge == true }

    /// Its Xcode Cloud recovery stopped: Cloud still fails, or it couldn't hand the failure on.
    var cloudNeedsYou: Bool { dismissed == nil && stoppedCloud == true }

    var isActive: Bool { status == .queued || status == .running }
    /// How many rounds it may take and the one it's on, as Engine's Job says them.
    var maxRounds: Int { rounds ?? 1 }
    var currentRound: Int { round ?? 1 }
    /// Queued behind something (`waiting`): listed under Waiting, not counted as working (#238).
    var isWaiting: Bool { status == .queued && waiting != nil }
    /// Running, or getting ready to: what every app counts as an agent working (as Engine's).
    var isWorking: Bool { isActive && !isWaiting }
    /// Its agent asked the user something and waits for the answer: its alert stays until then.
    var waitsForAnswer: Bool { question != nil && dismissed == nil && status != .stopped }
    /// Its agent waits for the user's OK (Allow, Always allow or Deny).
    var waitsForPermission: Bool { permission != nil && isActive }

    /// The report's list of what Oby sent out for the job, or nil when nothing went out.
    var sentLines: String? {
        guard let outgoing, !outgoing.isEmpty else { return nil }
        return "Sent by Oby:\n" + outgoing.map { "- \($0.line)" }.joined(separator: "\n")
    }
    var repoName: String { String(repo.split(separator: "/").last ?? Substring(repo)) }
    var agentName: String { ["codex": "Codex", "cursor": "Cursor"][agent] ?? "Claude Code" }

    /// The runner's title, like "Mac runner notifications", else "Review oby #33" or the first line
    /// of what the user asked.
    var heading: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let number = pr ?? issue { return "\(kind.capitalized) \(repoName) #\(number)" }
        return (task.isEmpty ? request : task).split(separator: "\n").first.map(String.init) ?? request
    }

    /// The one line a finished job is known by; a waiting one says what for.
    var line: String {
        if let waiting, status == .queued { return Self.waitingLine(waiting.text) }
        return switch status {
        case .queued, .running: step
        case .done: summary.split(separator: "\n").first.map(String.init) ?? "Done"
        case .interrupted: reason ?? summary.split(separator: "\n").first.map(String.init) ?? "Needs you"
        case .failed, .stopped: summary.split(separator: "\n").first.map(String.init) ?? status.rawValue.capitalized
        }
    }

    /// Commits not on its pull request yet: all of them before it's published, then later rounds' ones.
    var unpublished: Int { max(0, (commits ?? 0) - (published == nil ? 0 : pushed ?? commits ?? 0)) }
    /// Not once the user dismissed it, never on Oby's own review jobs, and never once its pull
    /// request was merged or closed (as Engine's `Job.canPublish`).
    var canPublish: Bool {
        status == .done && kind != "research" && kind != "review" && base != nil && unpublished > 0 && dismissed == nil && reviewOf == nil
            && (pullRequest?.state ?? "OPEN") == "OPEN"
    }

    /// Oby's review requested changes for the last time it may (a blocker came back) and the pull
    /// request is still open, as the runner says.
    var reviewNeedsYou: Bool { stoppedReview == true }

    /// Done with commits its pull request won't take: merged or closed before they went out (as Engine's `Job.stranded`).
    var stranded: Bool {
        status == .done && published != nil && unpublished > 0 && reviewOf == nil
            && (pullRequest.map { $0.state != "OPEN" } ?? false)
    }

    /// Waiting for Publish (the runner's own publish failed), failed, interrupted, out of review
    /// rounds, stranded or its merge stopped, and not dismissed: what the runner sends an alert for,
    /// and what Dismiss takes.
    var needsYou: Bool {
        dismissed == nil && (canPublish || stranded || status == .failed || status == .interrupted || reviewNeedsYou || mergeNeedsYou || cloudNeedsYou)
    }

    /// "Round 2 of 5 · Fable 5.1", or empty for a one-round job on the usual model.
    var extras: String {
        var parts: [String] = []
        if let rounds, rounds > 1 { parts.append("Round \(round ?? 1) of \(rounds)") }
        if let model { parts.append(ModelChoice.name(model)) }
        return parts.joined(separator: " · ")
    }
}

/// Wire types only. Pipeline state is derived by Engine, never by the phone.
nonisolated struct JobStage: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case done, current, upcoming, failed, skipped }
    var id: String
    var title: String
    var state: State
    var detail: String?
    var reason: String?
    /// Its times (#733), nil until obid serves them; one that can't be read is left out (`Lenient`).
    var started: Lenient<Date>?
    var finished: Lenient<Date>?
    var waited: Lenient<Double>?
    var estimate: Lenient<Span>?
}

nonisolated struct JobPipeline: Codable, Equatable, Sendable {
    var stages: [JobStage]
    var number: Int
    var total: Int
    var label: String { "Stage \(number) of \(total)" }
}

nonisolated struct PullRequestStatus: Codable, Equatable, Sendable {
    var state: String
    var reviewDecision: String?
    var base: String
    var mergedAt: Date?
    var checkedAt: Date
}

/// Oby's verdict on a job's pull request (docs/runner-api.md).
nonisolated struct Review: Codable, Equatable, Sendable {
    /// "approved" or "changesRequested".
    var verdict: String
    var job: String
    var agent: String
    var account: String
    var round: Int
    var date: Date
    /// The check run it went on the pull request as; `comment` from runners before check runs.
    var checkRun: String?
    var comment: String?
    var postError: String?

    var label: String { verdict == "approved" ? "Approved" : "Changes requested" }
}

/// Something the runner sent out for a job (docs/runner-api.md): ids only, never what was sent.
nonisolated struct Outgoing: Codable, Equatable, Sendable {
    /// "push", "pullRequest", "pullRequestEdit", "checkRun", "comment" (before check runs) or "merge";
    /// a newer runner may send others.
    var action: String
    var repo: String
    var id: String
    var branch: String?
    var date: Date

    /// As Engine/Outgoing.swift words it.
    var line: String {
        switch action {
        case "push": "Pushed \(id.prefix(7)) to \(branch ?? "its branch") in \(repo)"
        case "pullRequest": "Opened pull request \(id)"
        case "pullRequestEdit": "Updated the description of \(id)"
        case "comment": "Commented \(id)"
        case "checkRun": "Posted the check \(id)"
        case "merge": "Squash-merged \(id) into dev and deleted \(branch ?? "its branch")"
        default: "\(action) \(id)"
        }
    }
}

nonisolated struct Account: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var agent: String
    var name: String
    var label: String?
    var signedIn: Bool
    var fiveHour: Double?
    var sevenDay: Double?
    /// When each window resets (docs/runner-api.md). Older runners don't send them.
    var fiveHourResets: Date?
    var sevenDayResets: Date?
    var running: Int
    /// A job of its hit the account's usage limit: no job goes to it before then (newer runners only).
    var fullUntil: Date?
    /// Whether its agents have Tetrix connected (nil: not known yet), and of its recent jobs, how
    /// many used it (newer runners only).
    var tetrix: Bool?
    var tetrixJobs: Int?
    var tetrixUsed: Int?
    /// Whether it gets only jobs sent to it by name, its week at 80%, and until when the user let
    /// it past that (#278); newer runners only.
    var reserved: Bool?
    var reserveLiftedUntil: Date?

    /// "Personal · Claude Code"
    var title: String { "\(name) · \(Usage.tool(agent))" }

    /// What Settings' usage card shows.
    var usage: Usage.Snapshot {
        Usage.Snapshot(agent: agent, name: name, label: label, fiveHour: fiveHour, sevenDay: sevenDay,
                       fiveHourResets: fiveHourResets, sevenDayResets: sevenDayResets, running: running,
                       reserveLiftedUntil: reserveLiftedUntil, runnerSignedIn: signedIn)
    }
}
#endif

nonisolated struct Question: Codable, Equatable, Sendable {
    var text: String
    /// At most 3 (docs/runner-api.md); the user's own words answer too.
    var options: [String]
    /// What each option does, one line each, or nil. Older runners don't send it.
    var details: [String]? = nil
    /// The index of the option the asker recommends, or nil. Older runners don't send it.
    var recommended: Int? = nil
    /// The plan to approve, in markdown (Plan mode), or nil. Older runners don't send it.
    var plan: String? = nil
}

#if os(iOS) || os(watchOS)
/// Something only the user can answer, waiting in the inbox (docs/runner-api.md). The Mac reads
/// these into Engine's own InboxItem.
nonisolated struct InboxItem: Codable, Identifiable, Equatable, Sendable {
    /// `question`, `review`, `failed` or `limit`; more may come.
    var kind: String
    var id: String
    var job: String
    var title: String
    var text: String
    var options: [String]
    /// What each option does, one line each, from newer runners only (#215).
    var details: [String]? = nil
    var created: Date
    var done: Date?
    var later: Date?
    var answer: String?
    /// Oby's plain words for it (#65), from newer runners only: a headline of at most 8 words, what
    /// happened, the option it recommends (an index into `options`, or nil) and why.
    var headline: String?
    var happened: String?
    var recommended: Int?
    var why: String?
    /// On a `confirm` item (obid only, #546), what its Confirm carries out.
    var confirm: RunnerConfirm? = nil

    var isOpen: Bool { done == nil }
    /// Those words, for its card.
    var words: InboxWords { InboxWords(headline: headline, happened: happened, recommended: recommended, why: why, confirm: confirm) }
    func waiting(at now: Date = .now) -> Bool { done == nil && (later.map { $0 <= now } ?? true) }
}
#endif

#if os(macOS)
extension InboxItem {
    /// A runner's item as Engine's InboxItem, or nil for a kind Engine doesn't know yet (a newer
    /// runner may add one; permissions also come through job extras).
    ///
    /// Engine has no `confirm` kind (obid only, #546), and Engine is frozen: a confirm item reads
    /// as a `start`, the kind closest to it (two options, no words, the user's go-ahead), and its
    /// `InboxWords.confirm`, read from the same JSON, says what it really is. Every screen shows it
    /// by that (`shownKind`), and the brain's briefing leaves it out (`RunnerFeed.briefingInbox`).
    nonisolated static func runner(_ json: Data) -> InboxItem? {
        if let item = try? Runner.decoder.decode(InboxItem.self, from: json) { return item }
        guard var object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        // A teammate asking to run a job on this Mac (#808): Sangam's design shows it as a "Start
        // it?" card with its own answers (Allow, Allow … from now on, Decline), which obid takes.
        if object["kind"] as? String == "obiRequest", (object["obi"] as? [String: Any])?["type"] as? String == "run_request" {
            object["kind"] = Kind.start.rawValue
            return (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? Runner.decoder.decode(InboxItem.self, from: $0) }
        }
        // A teammate used the share of an API account you gave them (#809): Sangam's "Sangam used
        // the share of Deskree API", an Out of usage card with its own answers.
        if object["kind"] as? String == "obiRequest", (object["obi"] as? [String: Any])?["type"] as? String == "share_used" {
            object["kind"] = Kind.limit.rawValue
            return (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? Runner.decoder.decode(InboxItem.self, from: $0) }
        }
        guard object["kind"] as? String == RunnerConfirm.kind, object["confirm"] is [String: Any] else { return nil }
        object["kind"] = Kind.start.rawValue
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? Runner.decoder.decode(InboxItem.self, from: $0) }
    }

    /// `GET /v1/inbox`'s items, each as `runner(_:)` reads it: the ones Engine knows, and confirm items.
    nonisolated static func runnerList(_ data: Data) throws -> [InboxItem] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw RunnerError(message: "The runner's inbox couldn't be read.")
        }
        return list.compactMap { (try? JSONSerialization.data(withJSONObject: $0)).flatMap(runner) }
    }
}
#endif

extension InboxItem {
    /// Its kind as the runner names it. The Mac's `kind` is Engine's enum, the iPhone's a string:
    /// both read the same. Engine has no `confirm` kind (obid only, #546): on the Mac, `words`
    /// (`InboxWords.confirm`) says an item is one.
    nonisolated func shownKind(_ words: InboxWords? = nil) -> String {
        words?.confirm != nil ? RunnerConfirm.kind : "\(kind)"
    }

    /// "Failed · Mac runner notifications · waiting 3m": what kind of item, its job, how long it waited.
    nonisolated func line(now: Date = .now, words: InboxWords? = nil) -> String {
        let label = switch shownKind(words) {
        case "question": "Question"
        case "review": "Out of reviews"
        case "limit": "Out of usage"
        case "audit": "Issue audit"
        case "merge": "Not merged"
        case "failure": "Oby failure"
        case "start": "Start it?"
        case "permission": "Permission"
        case RunnerConfirm.kind: "Confirm it?"
        default: "Failed"
        }
        return "\(label) · \(title) · \(Elapsed.waiting(since: created, now: now))"
    }

    /// The inbox as the apps show it: what waits now, the longest-waiting first.
    nonisolated static func waiting(_ items: [InboxItem], now: Date = .now) -> [InboxItem] {
        items.filter { $0.waiting(at: now) }.sorted { $0.created < $1.created }
    }
}

/// What the brain made of the user's words (`POST /v1/plans`): the work it planned has started
/// (#269), and the reply carries those jobs. A `plan` from an older runner reads as a reply with
/// nothing started.
nonisolated enum PlanResult: Decodable, Equatable, Sendable {
    case question(said: String, Question)
    /// What Oby said, and the jobs it started for it, 0 to 10.
    case reply(String, started: [Job])
    case none

    private enum Keys: String, CodingKey { case kind, jobs, said, question, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "question": self = .question(said: try c.decode(String.self, forKey: .said), try c.decode(Question.self, forKey: .question))
        case "reply", "plan":
            self = .reply(try c.decodeIfPresent(String.self, forKey: .text) ?? "", started: try c.decodeIfPresent([Job].self, forKey: .jobs) ?? [])
        default: self = .none
        }
    }
}

/// What `POST /v1/plans` answers, with the conversation the words joined (obid only, #493).
nonisolated struct PlannedTurn: Decodable, Equatable, Sendable {
    var result: PlanResult
    var conversation: String?

    private enum Keys: String, CodingKey { case conversation }

    init(from decoder: any Decoder) throws {
        result = try PlanResult(from: decoder)
        conversation = try? decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .conversation)
    }
}

/// One of obid's conversations (docs/runner-api.md, "obid only: conversations"), as its list and
/// its event send it. Tolerant: a key missing or unreadable takes a plain default, so a newer
/// obid's still reads. `deleted`: the event saying it's gone.
nonisolated struct RunnerConversation: Decodable, Identifiable, Equatable, Sendable {
    /// What a search found in it: the latest turn that holds the words.
    struct Match: Decodable, Equatable, Sendable {
        var who: String?
        var text: String
    }

    var id: String
    var title: String
    var pinned: Bool
    var created: Date?
    var lastActivity: Date?
    var deleted: Bool
    var turn: Match?

    private enum Keys: String, CodingKey { case id, title, pinned, created, lastActivity, deleted, turn }

    init(id: String, title: String, pinned: Bool = false, created: Date? = nil, lastActivity: Date? = nil,
         deleted: Bool = false, turn: Match? = nil) {
        self.id = id
        self.title = title
        self.pinned = pinned
        self.created = created
        self.lastActivity = lastActivity
        self.deleted = deleted
        self.turn = turn
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        id = try keys.decode(String.self, forKey: .id)
        title = (try? keys.decodeIfPresent(String.self, forKey: .title)) ?? ""
        pinned = (try? keys.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        created = try? keys.decodeIfPresent(Date.self, forKey: .created)
        lastActivity = try? keys.decodeIfPresent(Date.self, forKey: .lastActivity)
        deleted = (try? keys.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
        turn = try? keys.decodeIfPresent(Match.self, forKey: .turn)
    }

    /// When it last moved: its latest turn, else when it started.
    var latest: Date { lastActivity ?? created ?? .distantPast }
}

nonisolated struct ModelChoice: Codable, Equatable, Sendable {
    var model: String
    var effort: String
    var complexEffort: String? = nil
}

extension ModelChoice {
    /// "Opus 5.5 · Extra high"
    nonisolated var label: String {
        "\(Self.name(model)) · \(Self.effortName(effort))"
    }

    /// "Extra high", "Medium".
    nonisolated static func effortName(_ effort: String) -> String { effort == "xhigh" ? "Extra high" : effort.capitalized }

    /// "Fable 5.1", "GPT-6-Astra", or the id as it is.
    nonisolated static func name(_ model: String) -> String {
        let names = ["claude-opus-5-5": "Opus 5.5", "claude-sonnet-5-5": "Sonnet 5.5", "claude-haiku-5-5": "Haiku 5.5",
                     "claude-fable-5-1": "Fable 5.1", "gpt-6-astra": "GPT-6-Astra", "auto": "Auto"]
        return names[model] ?? model
    }
}

nonisolated struct ModelSettings: Codable, Equatable, Sendable {
    var claude: ModelChoice
    var codex: ModelChoice
    /// Cursor has a model and no effort; an older runner doesn't send it.
    var cursor: CursorModelChoice? = nil
}

nonisolated struct CursorModelChoice: Codable, Equatable, Sendable {
    var model: String
}

nonisolated struct ModelOptions: Codable, Equatable, Sendable {
    struct Model: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var efforts: [String]?
    }
    struct Tool: Codable, Equatable, Sendable {
        var models: [Model]
        var efforts: [String]?
        var complexEfforts: [String]?
    }
    var claude: Tool
    var codex: Tool
    /// Cursor's models, with no efforts; an older runner doesn't send it.
    var cursor: Tool? = nil
}

#if os(iOS) || os(watchOS)
/// The runner's accounts as the API sends them: the iPhone's own wire type.
typealias RunnerAccount = Account
#else
/// On the Mac the runner's accounts are read into Engine's own AccountState (the runner keeps
/// their `home` to itself; obid sends `payer`), so the brain can tell their usage too (Engine/Conversation.swift).
typealias RunnerAccount = AccountState

extension AccountState: Decodable {
    private enum Keys: String, CodingKey {
        case id, agent, name, payer, label, signedIn, fiveHour, sevenDay, fiveHourResets, sevenDayResets, running, fullUntil, tetrix, tetrixJobs, tetrixUsed, reserveLiftedUntil
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        self.init(account: Account(id: try keys.decode(String.self, forKey: .id), agent: try keys.decode(String.self, forKey: .agent),
                                   name: try keys.decode(String.self, forKey: .name),
                                   payer: try keys.decodeIfPresent(String.self, forKey: .payer) ?? "", home: nil),
                  label: try keys.decodeIfPresent(String.self, forKey: .label),
                  fiveHour: try keys.decodeIfPresent(Double.self, forKey: .fiveHour),
                  sevenDay: try keys.decodeIfPresent(Double.self, forKey: .sevenDay),
                  fiveHourResets: try keys.decodeIfPresent(Date.self, forKey: .fiveHourResets),
                  sevenDayResets: try keys.decodeIfPresent(Date.self, forKey: .sevenDayResets),
                  running: try keys.decodeIfPresent(Int.self, forKey: .running) ?? 0,
                  fullUntil: try keys.decodeIfPresent(Date.self, forKey: .fullUntil),
                  tetrix: try keys.decodeIfPresent(Bool.self, forKey: .tetrix),
                  tetrixJobs: try keys.decodeIfPresent(Int.self, forKey: .tetrixJobs) ?? 0,
                  tetrixUsed: try keys.decodeIfPresent(Int.self, forKey: .tetrixUsed) ?? 0,
                  reserveLifted: try keys.decodeIfPresent(Date.self, forKey: .reserveLiftedUntil),
                  runnerSignedIn: try keys.decodeIfPresent(Bool.self, forKey: .signedIn))
    }
}
#endif

nonisolated struct RunnerStatus: Decodable, Equatable, Sendable {
    struct Runner: Codable, Equatable, Sendable {
        var version: String
        var host: String
    }
    var runner: Runner
    var accounts: [RunnerAccount]
    var models: ModelSettings
    /// When Clear done was last pressed, on any app, or nil (docs/runner-api.md). Older runners don't send it.
    var clearedAt: Date?
    /// The default mode new jobs get, or nil from older runners.
    var permissions: Permissions?
    var cleanup: Cleanup?
    /// Who the runner's own GitHub calls act as: `app` (Oby's GitHub app) or `owner` (the owner's
    /// `gh` login). Older runners don't send it.
    var github: String?
    /// Whether Oby's review and Mac check go on pull requests as check runs: `ok`, `missing
    /// permission` or `no app`. Older runners don't send it.
    var checks: String?

    struct Cleanup: Codable, Equatable, Sendable {
        var path: String
        var bytes: Int64
        var lastRun: Date?
    }

    struct Permissions: Codable, Equatable, Sendable {
        var mode: String?
    }
}

/// What `POST /v1/clear` answers, and what the `clear` event carries.
nonisolated struct ClearedAt: Codable, Equatable, Sendable {
    var clearedAt: Date
}

/// What `POST /v1/stop-all` answers: how many jobs stopped, and those jobs.
nonisolated struct StoppedJobs: Decodable, Sendable {
    var stopped: Int
    var jobs: [Job]
}

/// One thing the runner reports while the app is open.
nonisolated enum RunnerEvent: Equatable, Sendable {
    /// The runner is following this app now: fetch what's there. Whatever changes meanwhile
    /// arrives after this, so applying it over the fetched lists loses nothing.
    case connected
    #if os(macOS)
    /// With what Engine's Job doesn't read yet (RunnerJobExtras), when it could be read.
    case job(Job, RunnerJobExtras?)
    /// A job was deleted, here or on another app (obid only): it leaves every list.
    case jobDeleted(String)
    #else
    case job(Job)
    #endif
    case accounts([RunnerAccount])
    /// Clear done was pressed, here or on another app: jobs that finished by then are hidden.
    case cleared(Date)
    /// An inbox item came, was answered, done or put off, here or on another app.
    #if os(macOS)
    /// With Oby's plain words for it (InboxWords), which Engine's InboxItem doesn't read.
    case inbox(InboxItem, InboxWords?)
    #else
    case inbox(InboxItem)
    #endif
    #if os(macOS)
    /// A merge check was queued, taken or ended (Engine/Checks.swift): a Mac that runs them asks for one.
    case check(MacCheck)
    /// obid measured the job worktrees after it started answering (Settings › Runner).
    case cleanup(RunnerStatus.Cleanup)
    /// obid's Tetrix changed: connected, signed out, a sign-in started or ended (obid only).
    case tetrix(TetrixStatus)
    /// The watcher or the channel listener told the owner something (a `watch` or `listen` inbox
    /// item, obid only): its card and a notification.
    case watchNotice(WatchNotice)
    /// obid's Slack changed: connected, signed out (obid only).
    case slack(SlackStatus)
    /// obid's Sentry changed: connected, signed out, a read's problem (obid only; no `repos`).
    case sentry(SentryStatus)
    /// The watcher's rules or runs changed (obid only).
    case watch(WatchStatus)
    #endif
    /// A turn of the conversation was added, from any app, or changed (a job dispatched from it):
    /// the Mac window's and the iPhone's thread replace it by id, or add it by time (#11).
    /// With what the app's Turn doesn't keep (obid only): the artifacts it made, and whether it's
    /// the turn a job adds when it ends.
    case turn(Turn, TurnExtras = TurnExtras())
    /// One step of Oby's turn began, went on or ended (#304). Runners from before the step event never send it.
    case step(TurnStep)
    /// One of obid's conversations started, got a turn, was renamed, pinned or deleted (#493).
    case conversation(RunnerConversation)
    /// A piece of Oby's words as its agent writes them (obid only, the conversation harness).
    case delta(TurnDelta)
    /// An artifact was made, got a version, or was deleted (obid only).
    case artifact(ArtifactEvent)
    /// A routine was made, changed, paused, run or deleted (obid only, #395): Settings › Routines
    /// reads them again.
    case routine
    /// Your work on GitHub changed, or obid's gh signed in or out (obid only): the whole list.
    case github(GitHubWork)
    /// A job's session got an entry, one changed, or the agent wrote more words (obid only, #755, #784).
    case transcript(TranscriptEvent)
}

#if os(iOS) || os(watchOS)
/// One turn of the conversation with Oby, as Engine/Conversation.swift has it: the Mac compiles
/// that one; the iPhone reads the runner's turns into this copy (apps/shared/ConversationModel.swift).
nonisolated struct Turn: Codable, Identifiable, Equatable, Sendable {
    enum Who: String, Codable, Sendable { case user, oby }

    var id: String
    var date: Date
    var who: Who
    var text: String
    /// The jobs this turn started, for a card under Oby's words. Nil on the user's turns and on older ones.
    var jobs: [String]?
    /// The user said it out loud (the iPhone's mic), so the thread says "You, by voice". Nil when
    /// typed, and on turns the runner kept.
    var voice: Bool?
    /// Longer Markdown answer beneath Oby's short reply; nil on older turns.
    var details: String?
    /// The conversation it's in (obid only, #493), or nil from a runner with one thread.
    var conversation: String?

    init(id: String = UUID().uuidString.lowercased(), date: Date = .now, who: Who, text: String,
         jobs: [String]? = nil, voice: Bool? = nil, details: String? = nil, conversation: String? = nil) {
        self.id = id
        self.date = date
        self.who = who
        self.text = text
        self.jobs = jobs
        self.voice = voice
        self.details = details
        self.conversation = conversation
    }
}
#endif

/// One turn of the runner's conversation as `GET /v1/conversation` and the `turn` event send it
/// (docs/runner-api.md), read into the app's Turn.
nonisolated struct RunnerTurn: Decodable, Sendable {
    var id: String
    var who: String
    var text: String
    var at: Date
    var jobs: [String]?
    var details: String?
    /// obid only (#493): the conversation it's in.
    var conversation: String?
    /// obid only: what the turn made to be looked at.
    var artifacts: [ArtifactRef]?
    /// obid only (#351): the turn a job adds to its conversation when it ends, not an answer.
    var ended: Bool?
    /// obid only (#395): the routine whose run the turn tells of.
    var routine: RoutineMark?

    var extras: TurnExtras { TurnExtras(artifacts: artifacts ?? [], ended: ended == true, routine: routine != nil) }

    private enum CodingKeys: String, CodingKey { case id, who, text, at, jobs, details, conversation, artifacts, ended, routine }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        who = try c.decode(String.self, forKey: .who)
        text = try c.decode(String.self, forKey: .text)
        at = try c.decode(Date.self, forKey: .at)
        jobs = try c.decodeIfPresent([String].self, forKey: .jobs)
        details = try c.decodeIfPresent(String.self, forKey: .details)
        conversation = try c.decodeIfPresent(String.self, forKey: .conversation)
        // Tolerant: a list this app can't read leaves the turn without cards, not unread.
        artifacts = try? c.decodeIfPresent([ArtifactRef].self, forKey: .artifacts)
        ended = try? c.decodeIfPresent(Bool.self, forKey: .ended)
        routine = try? c.decodeIfPresent(RoutineMark.self, forKey: .routine)
    }

    var turn: Turn {
        Turn(id: id, date: at, who: Turn.Who(rawValue: who) ?? .oby, text: text,
             jobs: (jobs ?? []).isEmpty ? nil : jobs, details: details, conversation: conversation)
    }
}

/// One step of Oby's turn as the `step` event sends it (docs/runner-api.md, #304): "Moving Vault
/// secrets to Codex · Deskree", running, then done or failed. The apps list a turn's steps under
/// the user's message, then Oby's answer. A step comes again with each change of its `state`, by
/// the same `turn` and `index`.
nonisolated struct TurnStep: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case running, done, failed }

    /// The user's turn this step belongs to.
    var turn: String
    /// Where it stands in the turn, from 1.
    var index: Int
    /// What kind of step, like `move_job`; nil when the runner doesn't say.
    var action: String?
    var text: String
    var state: State
    var at: Date?
    /// The conversation its turn is in (obid only, #493), or nil.
    var conversation: String?
    /// On a tool call of a conversation's agent (`action` "tool", obid only): which tool (`read`,
    /// `web_search`, `bash`, `oby_dispatch`…) and what on (the file, query, URL or command).
    var tool: String?
    var detail: String?

    var id: String { "\(turn)#\(index)" }

    init(turn: String, index: Int, action: String? = nil, text: String, state: State, at: Date? = nil, conversation: String? = nil,
         tool: String? = nil, detail: String? = nil) {
        self.turn = turn
        self.index = index
        self.action = action
        self.text = text
        self.state = state
        self.at = at
        self.conversation = conversation
        self.tool = tool
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey { case turn, index, action, text, state, at, conversation, tool, detail }

    /// Tolerant of what a newer runner adds: a state this app doesn't know reads as done, and a
    /// time that doesn't parse is left out, so the step still shows.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turn = try c.decode(String.self, forKey: .turn)
        index = try c.decode(Int.self, forKey: .index)
        action = try? c.decodeIfPresent(String.self, forKey: .action)
        text = try c.decode(String.self, forKey: .text)
        state = (try? c.decode(String.self, forKey: .state)).flatMap(State.init(rawValue:)) ?? .done
        at = try? c.decodeIfPresent(Date.self, forKey: .at)
        conversation = try? c.decodeIfPresent(String.self, forKey: .conversation)
        tool = try? c.decodeIfPresent(String.self, forKey: .tool)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
    }
}

extension Job {
    #if os(iOS) || os(watchOS)
    nonisolated var pullRequestState: String? { pullRequest?.state }
    nonisolated var reviewDecision: String? { pullRequest?.reviewDecision }
    #else
    nonisolated var pullRequestState: String? { pullRequest?.state.rawValue }
    nonisolated var reviewDecision: String? { pullRequest?.reviewDecision?.rawValue }

    /// The one line a job's row says under its title, as the iPhone's `Job.line`: the step while it
    /// runs, else the summary's first line.
    nonisolated var line: String {
        if let waiting, status == .queued { return Self.waitingLine(waiting.text) }
        return switch status {
        case .queued, .running: step
        case .done: summary.split(separator: "\n").first.map(String.init) ?? "Done"
        case .interrupted: reason ?? summary.split(separator: "\n").first.map(String.init) ?? "Needs you"
        case .failed, .stopped: summary.split(separator: "\n").first.map(String.init) ?? status.rawValue.capitalized
        }
    }
    #endif

    /// What One more round and Try again send (docs/runner-api.md, `POST /v1/jobs/{id}/messages`):
    /// the agent's session picks up where it stopped, in the same worktree and branch.
    nonisolated static let tryAgainWords = "Try again, picking up where you left off. Finish with a short summary as asked."

    /// The one next step of a job that stopped part way and needs you (obid's `interrupted`), or nil.
    nonisolated var nextStepOffered: String? { status == .interrupted && dismissed == nil ? nextStep : nil }

    /// When obid tries it again by itself, as its decision card says it: "At 3:04 PM, or now with
    /// Try again.", or nil.
    nonisolated var resumesLine: String? {
        guard nextStepOffered != nil, let resumes else { return nil }
        return "At \(resumes.formatted(date: .omitted, time: .shortened)), or now with \(nextStep ?? "Try again")."
    }

    /// Its decision card's kind (Sangam's labels): Out of usage when its agent hit a usage limit.
    nonisolated var needsYouKind: String {
        (reason ?? "").range(of: #"(?i)\b(usage|rate)[ -]?limit|hit your limit|limit (reached|exceeded)\b"#, options: .regularExpression) == nil
            ? "Needs you" : "Out of usage"
    }

    /// A finished job can run again for the user's words: it has a session to pick up, or it was
    /// moved since its last round and starts a new one where it went (docs/runner-api.md).
    nonisolated var resumable: Bool { session != nil || (started != nil && !(moves ?? []).isEmpty) }

    /// "After #223 merges", "Runner update": a waiting job's row, under the Waiting heading (#238).
    nonisolated static func waitingLine(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    /// Where the list puts the job (apps/shared/JobList.swift): what needs you, the ones working, the
    /// ones waiting their turn (#238), published ones whose pull request is still open, then
    /// everything else.
    nonisolated var group: JobGroup {
        if needsYou { return .needsYou }
        if isWaiting { return .waiting }
        if isActive { return .working }
        if status == .done, published != nil, (pullRequestState ?? "OPEN") == "OPEN" { return .inReview }
        return .done
    }

    /// Nothing more is to happen for it, so Clear done may take it (`JobList.settled`, #280): it
    /// was dismissed or stopped, its pull request was merged or closed, or it ended with nothing
    /// to publish. `jobs` is the list it's in, where a review job finds the job it reviews.
    nonisolated func settled(among jobs: [Job]) -> Bool {
        let author = reviewOf.flatMap { id in jobs.first { $0.id == id } }
        return JobList.settled(active: isActive || waiting != nil, needsYou: needsYou, letGo: dismissed != nil || status == .stopped,
                               openPullRequest: published != nil && (pullRequestState ?? "OPEN") == "OPEN",
                               author: author.map { $0.settled(among: []) })
    }

    /// Whether the list shows the job after the last Clear done, on any app (apps/shared/JobList.swift).
    nonisolated func listed(after clearedAt: Date?, among jobs: [Job]) -> Bool {
        JobList.lists(settled: settled(among: jobs), finished: finished, clearedAt: clearedAt)
    }

    /// Clear done would take it from the list (apps/shared/JobList.swift).
    nonisolated func clearable(among jobs: [Job]) -> Bool { JobList.clears(settled: settled(among: jobs)) }

    /// The status pill, the same on the iPhone and the Mac: how it's going, how it ended, and
    /// where its pull request is. A job you let go says Dismissed, however it ended.
    nonisolated var badge: JobBadge {
        if dismissed != nil { return JobBadge(text: "Dismissed", tone: .gray) }
        if waitsForPermission { return JobBadge(text: "Awaiting approval", tone: .orange) }
        if waitsForAnswer { return JobBadge(text: "Needs input", tone: .orange) }
        if step == "Waiting for your OK", isActive { return JobBadge(text: "Awaiting approval", tone: .orange) }
        switch status {
        case .queued where waiting != nil: return .waiting
        case .queued: return JobBadge(text: "Starting", tone: .blue)
        case .running: return JobBadge(text: "Working", tone: .blue)
        case .done where canPublish: return JobBadge(text: "Ready to publish", tone: .orange)
        case .done where reviewNeedsYou || mergeNeedsYou || cloudNeedsYou: return JobBadge(text: "Needs input", tone: .orange)
        case .done where pullRequestState == "MERGED": return JobBadge(text: "Merged", tone: .green)
        case .done where pullRequestState == "CLOSED": return JobBadge(text: "PR closed", tone: .gray)
        case .done where reviewDecision == "CHANGES_REQUESTED": return JobBadge(text: "Needs input", tone: .orange)
        case .done where published != nil || pullRequestState == "OPEN": return JobBadge(text: "In review", tone: .blue)
        case .done: return JobBadge(text: "Ready", tone: .green)
        case .failed: return JobBadge(text: "Failed", tone: .red)
        case .stopped: return JobBadge(text: "Stopped", tone: .gray)
        case .interrupted: return JobBadge(text: "Needs you", tone: .orange)
        }
    }

    /// Oby's own verdict on the pull request, next to the pill: "Oby approved", "Oby requested
    /// changes" (with the review's round after the first), "Oby is reviewing", or nil.
    nonisolated var verdictLine: String? {
        guard let review else { return reviewing == nil ? nil : "Oby is reviewing" }
        let verdict = review.label == "Approved" ? "Oby approved" : "Oby requested changes"
        return review.round > 1 ? "\(verdict) (review \(review.round))" : verdict
    }
}

/// What needs the user among these jobs, in one line, like "2 jobs are ready to publish, 1 job
/// failed", or nil when nothing does. Home on the iPhone and the Mac's island both say it, through
/// `Summary.line` (apps/shared/JobList.swift). Dismissed jobs aren't counted.
nonisolated enum NeedsYou {
    static func line(_ jobs: [Job]) -> String? {
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : n == 1 ? "1 job \(one)" : "\(n) jobs \(many)" }
        let needing = jobs.filter(\.needsYou)
        let parts = [
            count(needing.count(where: \.canPublish), "is ready to publish", "are ready to publish"),
            count(needing.count { $0.status == .failed }, "failed", "failed"),
            count(needing.count { $0.status == .interrupted }, "needs you", "need you"),
            count(needing.count(where: \.reviewNeedsYou), "needs your review", "need your review"),
            count(needing.count(where: \.stranded), "wasn't published", "weren't published"),
            count(needing.count(where: \.mergeNeedsYou), "wasn't merged", "weren't merged"),
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// How an app's line to the runner is: Settings says it under the runner's address.
nonisolated enum RunnerConnection: Equatable, Sendable {
    case connecting
    case live
    case offline(String)

    var isOffline: Bool { if case .offline = self { true } else { false } }

    /// "Connected to tetrix-lab", "Connecting…", or why it's offline.
    func status(host: String) -> String {
        switch self {
        case .live: "Connected to \(host)"
        case .connecting: "Connecting…"
        case .offline(let why): why
        }
    }
}

nonisolated struct RunnerError: LocalizedError {
    let message: String
    /// The runner's HTTP status, when it answered with an error.
    var status: Int? = nil
    var errorDescription: String? { message }
}

/// The runner on the tailnet: `tailscale serve` vouches for who's asking, so there's no token. Or
/// the runner on this Mac (#283), on 127.0.0.1, with its own `token` (Engine/LocalRunner.swift)
/// sent as `Authorization: Bearer` on every request.
nonisolated struct Runner: Sendable {
    var base: URL
    var token: String?
    /// What a 401 means here: an iPhone paired with a Mac says its pairing ended (docs/oby-ux.md
    /// row 34); nil says the generic line.
    var refused: String?

    init(base: URL, token: String? = nil, refused: String? = nil) {
        self.base = base
        self.token = token
        self.refused = refused
    }

    /// Nowhere: what a request goes to with no Mac paired and no runner set (port 9, discard),
    /// so a fresh iPhone talks to nobody (docs/oby-ux.md row 33).
    static let nowhere = URL(string: "http://127.0.0.1:9")!

    /// `request` with the token, when there is one.
    private func signed(_ request: URLRequest) -> URLRequest {
        guard let token else { return request }
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func status() async throws -> RunnerStatus { try await call("GET", "v1/status") }
    func jobs() async throws -> [Job] { try await call("GET", "v1/jobs?limit=50") }
    func stop(_ id: String) async throws -> Job { try await call("POST", "v1/jobs/\(id)/stop") }
    /// Stop all: every queued and running job on the runner stops now.
    func stopAll() async throws -> StoppedJobs { try await call("POST", "v1/stop-all") }
    /// Lets go of a job that needs the user: it then needs nothing. No signature: nothing goes out.
    func dismiss(_ id: String) async throws -> Job { try await call("POST", "v1/jobs/\(id)/dismiss") }
    /// Renames a job (obid only, `PATCH /v1/jobs/{id}`): one line of 1 to 60 characters.
    func rename(_ id: String, to title: String) async throws -> Job {
        struct Body: Encodable { var title: String }
        return try await call("PATCH", "v1/jobs/\(id)", body: Body(title: title))
    }
    /// Archives a job that ended and needs nothing, or unarchives it (obid only).
    func archive(_ id: String, _ archived: Bool = true) async throws -> Job {
        struct Body: Encodable { var archived: Bool }
        return try await call("POST", "v1/jobs/\(id)/archive", body: Body(archived: archived))
    }
    /// Deletes a job that ended, for good (obid only): its record, worktree and local branch in
    /// obid's clone. Nothing pushed is touched: its branch and pull request stay on GitHub.
    func deleteJob(_ id: String) async throws { try await send("DELETE", "v1/jobs/\(id)") }
    /// Clear done: the runner records now, and every app hides the jobs that finished by then.
    func clear() async throws -> Date {
        let answer: ClearedAt = try await call("POST", "v1/clear")
        return answer.clearedAt
    }

    /// What waits in the inbox, put-off items too. A runner older than the inbox has none (it
    /// doesn't know the path); any other failure throws, so the app tries again.
    func inbox() async throws -> [InboxItem] {
        do {
            return try await call("GET", "v1/inbox")
        } catch let error as RunnerError where error.status == 404 {
            return []
        }
    }

    /// One job, however old: the list has only the latest 50.
    func job(_ id: String) async throws -> Job { try await call("GET", "v1/jobs/\(id)") }

    /// Your work on GitHub as obid's gh finds it (docs/runner-api.md, "obid only: GitHub work"),
    /// or nil from a runner that doesn't list it.
    func gitHubWork() async throws -> GitHubWork? {
        do {
            return try await call("GET", "v1/github/work")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// Has obid read GitHub now; answers the feed once the read ends (up to 2 minutes).
    func refreshGitHubWork() async throws -> GitHubWork { try await call("POST", "v1/github/work/refresh", timeout: 150) }

    /// Starts Oby's job on a GitHub item, a review or a fix: the new job, or the one already on it.
    @discardableResult
    func startGitHubWork(_ id: String) async throws -> Job {
        try await call("POST", "v1/github/work/\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)/start")
    }
    func report(_ id: String) async throws -> ResearchDocument { try await call("GET", "v1/jobs/\(id)/report") }

    /// One entry's detail (#784): what the call was given, what it printed and its diff.
    func transcriptDetail(_ id: String, _ n: Int) async throws -> TranscriptDetail {
        try TranscriptDetail.read(await send("GET", "v1/jobs/\(id)/transcript/\(n)"))
    }

    /// The job's raw session after line `after` (#381), oldest first: a list, or `{entries: […]}`.
    func transcript(_ id: String, after: Int? = nil) async throws -> TranscriptPage {
        try TranscriptPage.read(await send("GET", "v1/jobs/\(id)/transcript" + (after.map { "?after=\($0)" } ?? "")))
    }
    func fileProposal(_ id: String, index: Int, start: Bool) async throws -> FileProposalResult {
        try await call("POST", "v1/jobs/\(id)/proposals/\(index)/file", body: FileProposalBody(start: start))
    }

    /// Settles an inbox item: an answer (one of its options, or the user's words) goes to its job;
    /// `done` lets it go without one; `later` puts it off until then. Send one of them.
    func settle(_ id: String, answer: String? = nil, done: Bool? = nil, later: Date? = nil) async throws -> InboxItem {
        struct Body: Encodable { var answer: String?; var done: Bool?; var later: Date? }
        #if os(macOS)
        let data = try await send("POST", "v1/inbox/\(Self.inboxSegment(id))/answer", body: Body(answer: answer, done: done, later: later))
        guard let item = InboxItem.runner(data) else { throw RunnerError(message: "The runner's answer couldn't be read.") }
        return item
        #else
        return try await call("POST", "v1/inbox/\(Self.inboxSegment(id))/answer", body: Body(answer: answer, done: done, later: later))
        #endif
    }

    /// An inbox item's id as one path segment: an id from elsewhere (a push) can't reach another route.
    static func inboxSegment(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id }

    /// Moves a job to another tool, account or model (each nil to keep it or let the runner pick):
    /// the runner answers with the job, or why it couldn't.
    func move(_ id: String, agent: String?, account: String?, model: String?, why: String? = nil) async throws -> Job {
        try await call("POST", "v1/jobs/\(id)/move", body: MoveBody(agent: agent, account: account, model: model, why: why))
    }

    /// "Use anyway" (#278): the account takes automatic work past its weekly reserve until its
    /// week resets, or with `lift` false is reserved again. The runner answers with the account.
    func liftReserve(_ id: String, _ lift: Bool) async throws -> RunnerAccount {
        struct Body: Encodable { var lift: Bool }
        return try await call("POST", "v1/accounts/\(id)/reserve", body: Body(lift: lift))
    }

    /// Starts a job that waits for its `startWhen` now (#216): the runner answers with the job.
    func startNow(_ id: String) async throws -> Job { try await call("POST", "v1/jobs/\(id)/start") }

    /// Tells the job's agent something: the runner answers with the job, or with the follow-up a
    /// finished one gets (`followUpOf` set), except Try again's words, which pick its session up again.
    /// `conversation`: said on the task's page, the words and Oby's answer join the job's
    /// conversation (obid only); `attachments` go with the follow-up.
    func tell(_ id: String, _ text: String, conversation: Bool = false, attachments: [String] = []) async throws -> Job {
        struct Body: Encodable { var text: String; var conversation: Bool?; var attachments: [String]? }
        return try await call("POST", "v1/jobs/\(id)/messages",
                              body: Body(text: text, conversation: conversation ? true : nil, attachments: attachments.isEmpty ? nil : attachments))
    }
    func models() async throws -> ModelSettings { try await call("GET", "v1/settings/models") }
    func modelOptions() async throws -> ModelOptions { try await call("GET", "v1/settings/models/options") }

    func setModels(_ models: ModelSettings) async throws -> ModelSettings {
        try await call("PUT", "v1/settings/models", body: models)
    }

    /// How long a plan's request waits: a turn that moves jobs and answers takes longer than the brain alone (#304).
    static let planTimeout: TimeInterval = 120

    func plan(_ said: String, answer: (question: String, option: String)? = nil, attachments: [String] = []) async throws -> PlanResult {
        try await planned(said, answer: answer, attachments: attachments).result
    }

    /// The same, in one of obid's conversations (#493): `conversation` names the one the words
    /// join, `new` starts one; neither, the latest. The answer says which they joined (nil from a
    /// runner with one thread).
    /// `id`: the id the app gave the words (its echo's, a lower-case UUID), which obid's turn of them
    /// takes; sent again with it (Try again after a lost answer), obid adds nothing (obid only).
    /// `runsOn`: the teammate's Obi whose Mac the jobs these words start run on (obid only, #808).
    func planned(_ said: String, answer: (question: String, option: String)? = nil, attachments: [String] = [],
                 conversation: String? = nil, new: Bool = false, id: String? = nil, runsOn: String? = nil) async throws -> PlannedTurn {
        struct Answer: Encodable { var question: String; var option: String }
        struct Body: Encodable { var said: String; var answer: Answer?; var attachments: [String]; var conversation: String?; var new: Bool?; var id: String?; var runsOn: String? }
        let body = Body(said: said, answer: answer.map { Answer(question: $0.question, option: $0.option) }, attachments: attachments,
                        conversation: conversation, new: new ? true : nil, id: id, runsOn: runsOn)
        return try await call("POST", "v1/plans", body: body, timeout: Self.planTimeout)
    }

    // MARK: Sharing a Mac (obid only, #797, #808)

    /// This Mac's sharing, whether it can run guests, and the guests' jobs on it now; nil from a
    /// runner that doesn't share (the Swift runner).
    func sharingMac() async throws -> RunnerSharingMac? {
        do {
            return try await call("GET", "v1/obid/sharing/mac")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    func setSharingMac(_ settings: RunnerSharingMac.Settings) async throws -> RunnerSharingMac {
        try await call("PUT", "v1/obid/sharing/mac", body: settings)
    }

    /// Stop (one guest job) or Stop All (nil).
    func stopGuests(_ job: String? = nil) async throws {
        struct Body: Encodable { var job: String? }
        _ = try await send("POST", "v1/obid/sharing/mac/stop", body: Body(job: job))
    }

    /// The teammates' Macs this owner may send a job to: free or busy, never whether their owner is at them.
    func macs() async throws -> [RunnerMac] {
        do {
            return try await call("GET", "v1/obid/sharing/macs")
        } catch let error as RunnerError where error.status == 404 {
            return []
        }
    }

    /// Moves a job that isn't running to a teammate's Mac, or back to this one (nil): Run it here.
    /// With a `grant`, on the share of their API account they gave this owner (#809).
    func place(_ id: String, on obi: String?, grant: String? = nil) async throws -> Job {
        struct Share: Encodable { var obi: String; var grant: String }
        struct Body: Encodable {
            var runsOn: String?
            var share: Share?
            func encode(to encoder: any Encoder) throws {
                var keys = encoder.container(keyedBy: CodingKeys.self)
                if let share { try keys.encode(share, forKey: .runsOn) } else { try keys.encode(runsOn, forKey: .runsOn) }
            }
            enum CodingKeys: String, CodingKey { case runsOn }
        }
        let share = obi.flatMap { obi in grant.map { Share(obi: obi, grant: $0) } }
        return try await call("PATCH", "v1/jobs/\(id)", body: Body(runsOn: obi, share: share))
    }

    // MARK: Sharing your usage (obid only, #798, #809)

    /// The owner's shares of their company API accounts, their accounts as Sharing sorts them, and
    /// whether the key is in Oby's vault; nil from a runner that doesn't share.
    func sharingGrants() async throws -> RunnerGrants? {
        do {
            return try await call("GET", "v1/obid/sharing/grants")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// A share of `account`'s month for `who` (nobody, everyone, or one owner).
    func setGrant(account: String, who: String, share: Int, budgetCents: Int, resetsDay: Int = 1) async throws -> RunnerGrants.Grant {
        struct Body: Encodable { var account: String; var who: String; var share: Int; var budgetCents: Int; var resetsDay: Int }
        return try await call("PUT", "v1/obid/sharing/grants",
                              body: Body(account: account, who: who, share: share, budgetCents: budgetCents, resetsDay: resetsDay))
    }

    /// The shares teammates gave this owner; nil from a runner that doesn't share.
    func sharedWithMe() async throws -> RunnerShares? {
        do {
            return try await call("GET", "v1/obid/sharing/shared")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    // MARK: Routines (obid only, #395)

    /// obid's routines, by name, or nil from a runner that has none (the Swift runner).
    func routines() async throws -> [RunnerRoutine]? {
        do {
            return try await call("GET", "v1/routines")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// Pauses (false) or resumes (true) a routine; obid answers with it.
    func setRoutine(_ id: String, enabled: Bool) async throws -> RunnerRoutine {
        struct Body: Encodable { var enabled: Bool }
        return try await call("PATCH", "v1/routines/\(id)", body: Body(enabled: enabled))
    }

    /// Run now: its job starts, and its next time stays as it was.
    func runRoutine(_ id: String) async throws {
        try await send("POST", "v1/routines/\(id)/run")
    }

    /// Forgets a routine; the jobs its runs started stay.
    func deleteRoutine(_ id: String) async throws {
        try await send("DELETE", "v1/routines/\(id)")
    }

    // MARK: Memory (obid only, #378)

    /// obid's memories and the suggestions waiting for an answer, or nil from a runner with no
    /// memory (the Swift runner).
    func memory() async throws -> RunnerMemoryList? {
        do {
            return try await call("GET", "v1/memory")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// Find what I keep repeating: obid reads the owner's conversations and the reviews on merged
    /// pull requests, and answers with what it could suggest. It takes a while.
    func findMemories() async throws -> RunnerMemoryFound {
        try await call("POST", "v1/memory/find", timeout: 150)
    }

    /// Remember: the owner's yes to a suggestion; obid answers with the memory it saved.
    func remember(_ suggestion: String) async throws -> RunnerMemory {
        try await call("POST", "v1/memory/suggestions/\(suggestion)/remember")
    }

    /// Not this: the suggestion goes, and nothing is saved.
    func dismissSuggestion(_ suggestion: String) async throws {
        try await send("POST", "v1/memory/suggestions/\(suggestion)/dismiss")
    }

    func deleteMemory(_ id: String) async throws {
        try await send("DELETE", "v1/memory/\(id)")
    }

    // MARK: Conversations (obid only, #493)

    /// obid's conversations, pinned first, then newest; with `query`, the ones that hold its words.
    /// Nil from a runner that keeps one thread (it doesn't know the path).
    func conversations(query: String? = nil, limit: Int = 100) async throws -> [RunnerConversation]? {
        try await conversationsAnswer(query: query, limit: limit).map(Self.conversations)
    }

    /// `conversations`' answer as it came, or nil (404): what the Mac keeps for its next launch.
    func conversationsAnswer(query: String? = nil, limit: Int = 100) async throws -> Data? {
        var path = "v1/conversations?limit=\(limit)"
        if let query, let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { path += "&q=\(q)" }
        do {
            return try await send("GET", path)
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// The conversations in a conversations answer.
    static func conversations(_ data: Data) throws -> [RunnerConversation] {
        try decoder.decode([RunnerConversation].self, from: data)
    }

    /// Renames or pins a conversation (nil keeps either); obid answers with it.
    func updateConversation(_ id: String, title: String? = nil, pinned: Bool? = nil) async throws -> RunnerConversation {
        struct Body: Encodable { var title: String?; var pinned: Bool? }
        return try await call("PATCH", "v1/conversations/\(id)", body: Body(title: title, pinned: pinned))
    }

    /// Forgets a conversation and its turns; the jobs it started stay.
    func deleteConversation(_ id: String) async throws {
        try await send("DELETE", "v1/conversations/\(id)")
    }

    /// Stop: the turn Oby is working on ends where it is (`POST /v1/conversation/stop`, #304). A
    /// runner from before it answers 404. On obid, `conversation` names the one whose turn stops;
    /// without it obid stops the latest turn under way, in whichever conversation.
    func stopConversation(_ conversation: String? = nil) async throws {
        try await send("POST", "v1/conversation/stop", body: conversation.map(TurnTarget.init))
    }

    func cancelPlan(_ conversation: String? = nil) async {
        _ = try? await send("POST", "v1/plans/cancel", body: conversation.map(TurnTarget.init))
    }

    /// The body naming the conversation a stop or a cancel is for (obid only, #493).
    private struct TurnTarget: Encodable { var conversation: String }

    func dispatch(_ job: Job) async throws -> Job {
        struct Body: Encodable { var job: DispatchedJob; var mode: String? }
        return try await call("POST", "v1/jobs", body: Body(job: DispatchedJob(job: job), mode: Self.mode(of: job)))
    }

    static func mode(of job: Job) -> String? {
        #if os(macOS)
        return nil
        #else
        return job.mode
        #endif
    }

    // MARK: Permissions (#134)

    /// Changes a job's mode; a permission it waits on that the new mode allows is answered.
    func setMode(_ id: String, _ mode: RunnerMode) async throws -> Job {
        struct Body: Encodable { var mode: RunnerMode }
        return try await call("POST", "v1/jobs/\(id)/mode", body: Body(mode: mode))
    }

    /// Answers the permission a job waits on. Words go with a deny, for the agent.
    func answer(_ job: String, permission: String, _ decision: RunnerPermission.Decision, message: String? = nil) async throws -> Job {
        struct Body: Encodable { var id: String; var decision: RunnerPermission.Decision; var message: String? }
        return try await call("POST", "v1/jobs/\(job)/permission", body: Body(id: permission, decision: decision, message: message))
    }

    /// The mode new jobs get when a dispatch doesn't pick one.
    func setDefaultMode(_ mode: RunnerMode) async throws {
        struct Body: Encodable { var mode: RunnerMode }
        try await send("PUT", "v1/settings/permissions", body: Body(mode: mode))
    }

    /// The rules Always allow (or Deny) saved.
    func permissionRules() async throws -> [RunnerRule] { try await call("GET", "v1/permissions/rules") }

    func removeRule(_ id: String) async throws {
        try await send("DELETE", "v1/permissions/rules/\(id)")
    }

    /// The exact sentence publishing would carry out.
    func publishAction(_ id: String) async throws -> String {
        struct Answer: Decodable { var action: String }
        let answer: Answer = try await call("GET", "v1/jobs/\(id)/publish")
        return answer.action
    }

    // Approvals come from the iPhone's Face ID key or the Mac's Touch ID key (apps/shared/DeviceKey.swift).
    #if os(iOS) || os(macOS)
    /// The owner's Confirm of a confirm item, with the device's signature over its title (#776).
    func settle(_ id: String, answer: String, approval: Approval) async throws -> InboxItem {
        struct Body: Encodable { var answer: String; var approval: Approval }
        #if os(macOS)
        let data = try await send("POST", "v1/inbox/\(Self.inboxSegment(id))/answer", body: Body(answer: answer, approval: approval))
        guard let item = InboxItem.runner(data) else { throw RunnerError(message: "The runner's answer couldn't be read.") }
        return item
        #else
        return try await call("POST", "v1/inbox/\(Self.inboxSegment(id))/answer", body: Body(answer: answer, approval: approval))
        #endif
    }

    func publish(_ id: String, approval: Approval) async throws -> URL {
        struct Answer: Decodable { var url: URL }
        let answer: Answer = try await call("POST", "v1/jobs/\(id)/publish", body: approval)
        return answer.url
    }
    #endif

    /// The Apple Watches paired with the runner, for its Watch API. The Mac lists and removes them
    /// too; pairing one takes the iPhone, with the watch at hand.
    func watches() async throws -> [PairedWatch] { try await call("GET", "v1/watches") }

    func removeWatch(_ id: String) async throws {
        struct Answer: Decodable { var removed: String }
        let _: Answer = try await call("DELETE", "v1/watches/\(id)")
    }

    #if os(iOS)

    /// Pairs a watch's key, approved with Face ID, and hands the runner the Access service token
    /// for its vault. Answers the watch's id and the Watch API's address.
    func pairWatch(name: String, publicKey: Data, clientID: String, clientSecret: String, approval: PairingApproval) async throws -> (id: String, url: URL) {
        struct Body: Encodable { var name: String; var publicKey: String; var accessClientId: String; var accessClientSecret: String; var approval: PairingApproval }
        struct Answer: Decodable { var id: String; var url: URL }
        let answer: Answer = try await call("POST", "v1/watches", body: Body(name: name, publicKey: publicKey.base64EncodedString(),
                                                                          accessClientId: clientID, accessClientSecret: clientSecret, approval: approval))
        return (answer.id, answer.url)
    }
    #endif

    func register(name: String, publicKey: Data) async throws -> String {
        struct Body: Encodable { var name: String; var publicKey: String }
        struct Answer: Decodable { var id: String }
        let answer: Answer = try await call("POST", "v1/devices", body: Body(name: name, publicKey: publicKey.base64EncodedString()))
        return answer.id
    }

    #if os(macOS)
    /// The next check for this Mac to run, now this Mac's, or nil when none waits: merge checks,
    /// Apple checks agents asked for (Engine/AppleChecks.swift), or both.
    func nextCheck(mac: String, merge: Bool = true, apple: Bool = false) async throws -> MacCheck? {
        struct Answer: Decodable { var check: MacCheck? }
        let name = mac.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let kinds = [merge ? "merge" : nil, apple ? "apple" : nil].compactMap { $0 }.joined(separator: ",")
        let answer: Answer = try await call("GET", "v1/checks/next?mac=\(name)&kinds=\(kinds)")
        return answer.check
    }

    /// The commits of an Apple check this Mac took, as a git bundle (empty when they're on GitHub already).
    func bundle(_ id: String) async throws -> Data {
        var request = URLRequest(url: base.appending(path: "v1/checks/\(id)/bundle"))
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: signed(request))
        try Self.check(response, data, refused: refused)
        return data
    }

    /// What this Mac found running a check it took.
    func report(_ id: String, _ report: MacCheck.Report) async throws -> MacCheck {
        struct Answer: Decodable { var check: MacCheck }
        let answer: Answer = try await call("POST", "v1/checks/\(id)/result", body: report)
        return answer.check
    }

    /// The connections the runner's agents use through its broker (Settings › Connectors), or nil
    /// from a runner that has none to list: obid doesn't serve them yet (#444).
    func connections() async throws -> [ConnectedApp]? {
        do {
            return try await call("GET", "v1/connections")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// The runner's own sentence for removing connection `name`: asked without an approval, it
    /// answers 403 with what to approve.
    func disconnectAction(_ name: String) async throws -> String {
        var request = URLRequest(url: URL(string: "v1/connections/\(name)", relativeTo: base.appending(path: "/"))!)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 45
        let (data, response) = try await URLSession.shared.data(for: signed(request))
        struct Ask: Decodable { var action: String }
        if (response as? HTTPURLResponse)?.statusCode == 403, let ask = try? JSONDecoder().decode(Ask.self, from: data) { return ask.action }
        try Self.check(response, data, refused: refused)
        throw RunnerError(message: "The runner didn't say what to approve.")
    }

    /// Removes connection `name` with a device's approval of `disconnectAction`'s sentence. Its
    /// secret stays in the runner's vault.
    func disconnect(_ name: String, approval: Approval) async throws {
        struct Body: Encodable { var approval: Approval }
        struct Answer: Decodable { var removed: String }
        let _: Answer = try await call("DELETE", "v1/connections/\(name)", body: Body(approval: approval))
    }

    /// The plug-ins obid found, enabled or not (docs/runner-api.md, "obid only: plug-ins"), or nil
    /// from the Swift runner, which has none.
    func plugins() async throws -> [RunnerPlugin]? {
        do {
            return try await call("GET", "v1/obid/plugins")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// Turns plug-in `id` on, with its settings, or off. obid answers once it's ready (or its first
    /// start failed), or once it and everything it started have stopped.
    func setPlugin(_ id: String, enabled: Bool, config: [String: String]? = nil) async throws -> RunnerPlugin {
        struct Body: Encodable { var enabled: Bool; var config: [String: String]? }
        return try await call("PUT", "v1/obid/plugins/\(id)", body: Body(enabled: enabled, config: config))
    }

    /// Whether obid's gh is signed in to GitHub, as whom, and the sign-in under way (docs/runner-api.md,
    /// "obid only: GitHub's sign-in"), or nil from a runner without it.
    func gitHubLogin() async throws -> GitHubLogin? {
        do {
            return try await call("GET", "v1/github")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// gh's own sign-in on the runner, or the one under way: GitHub's device page and the code to type there.
    func startGitHubSignIn() async throws -> GitHubSignIn {
        try await call("POST", "v1/github/sign-in")
    }

    /// Ends the GitHub sign-in under way, if any.
    func endGitHubSignIn() async throws {
        _ = try await send("DELETE", "v1/github/sign-in")
    }

    // MARK: obid's accounts (docs/runner-api.md, "obid only: accounts"): loopback only, so only obid on this Mac

    /// Adds an account: obid makes its folder, and it's signed in with `startAccountSignIn`.
    func addAccount(agent: String, name: String, payer: String) async throws -> RunnerAccount {
        struct Body: Encodable { var agent: String; var name: String; var payer: String? }
        return try await call("POST", "v1/accounts", body: Body(agent: agent, name: name, payer: payer.isEmpty ? nil : payer))
    }

    /// Lists the tool's own login again (`default`, `codex`) after it was removed here.
    func restoreDefaultLogin(agent: String) async throws -> RunnerAccount {
        struct Body: Encodable { var agent: String; var `default` = true }
        return try await call("POST", "v1/accounts", body: Body(agent: agent))
    }

    /// Takes the account out of Oby. The tool's own login, and the account with its provider, stay.
    func removeAccount(_ id: String) async throws {
        _ = try await send("DELETE", "v1/accounts/\(Self.segment(id))")
    }

    /// Runs the tool's own login for the account on obid (or answers the one under way).
    func startAccountSignIn(_ id: String) async throws -> AccountSignIn {
        try await call("GET", "v1/accounts/\(Self.segment(id))/sign-in")
    }

    /// The code Claude Code's page showed, for its login on obid: once.
    func sendAccountCode(_ id: String, _ code: String) async throws -> RunnerAccount {
        struct Body: Encodable { var code: String }
        return try await call("POST", "v1/accounts/\(Self.segment(id))/sign-in", body: Body(code: code), timeout: 75)
    }

    /// Ends the account's sign-in under way, if any.
    func endAccountSignIn(_ id: String) async throws {
        _ = try await send("DELETE", "v1/accounts/\(Self.segment(id))/sign-in")
    }

    private static func segment(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id }
    #endif

    /// Server-Sent Events until the connection drops; the caller reconnects.
    func events() -> AsyncThrowingStream<RunnerEvent, Error> {
        AsyncThrowingStream { stream in
            let task = Task {
                do {
                    var request = URLRequest(url: base.appending(path: "v1/events"))
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 60
                    let (bytes, response) = try await URLSession.shared.bytes(for: signed(request))
                    try Self.check(response, nil, refused: refused)
                    // The runner answers once it follows this connection: from here, every change arrives.
                    stream.yield(.connected)
                    var parser = EventParser()
                    var line = Data()
                    // Split on newlines only: summaries may hold U+2028, which `lines` would break at.
                    for try await byte in bytes {
                        guard byte == 0x0A else { line.append(byte); continue }
                        if let event = parser.feed(String(decoding: line, as: UTF8.self)) { stream.yield(event) }
                        line.removeAll(keepingCapacity: true)
                    }
                    stream.finish()
                } catch {
                    stream.finish(throwing: error)
                }
            }
            stream.onTermination = { _ in task.cancel() }
        }
    }

    #if os(iOS)
    /// Hands the runner a Live Activity push token: "update" for one activity, "start" for
    /// push-to-start. Answers whether the runner pushes.
    func registerActivity(token: Data, kind: String) async throws -> Bool {
        struct Body: Encodable { var token: String; var kind: String; var topic: String; var environment: String }
        struct Answer: Decodable { var push: Bool }
        let body = Body(token: Self.hex(token), kind: kind, topic: Bundle.main.bundleIdentifier ?? "", environment: Self.environment)
        let answer: Answer = try await call("POST", "v1/activities", body: body)
        return answer.push
    }

    /// Hands the runner what it pushes alerts with, through Deskree's relay: the relay's `pushId` and
    /// `pushSecret`, and the public key it seals each alert to (apps/ios/push/SealedPush.swift).
    /// Never the device token, which only the relay has. Answers whether the runner pushes.
    func registerNotifications(_ apns: PushRelay.HandOver) async throws -> Bool {
        struct Body: Encodable { var apns: PushRelay.HandOver }
        struct Answer: Decodable { var push: Bool }
        let answer: Answer = try await call("POST", "v1/notifications", body: Body(apns: apns))
        return answer.push
    }

    /// Apple's push service this build uses: a build from Xcode the development one, TestFlight
    /// and the App Store the production one.
    #if DEBUG
    private static let environment = "development"
    #else
    private static let environment = "production"
    #endif

    private static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }
    #endif

    func call<Answer: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil, timeout: TimeInterval = 45) async throws -> Answer {
        try Self.decoder.decode(Answer.self, from: try await send(method, path, body: body, timeout: timeout))
    }

    /// The answer's body, unread: for a call whose answer says nothing the app needs.
    @discardableResult
    /// `json`, when given, is the body as it is (an Obi-to-Obi object keeps its snake_case keys).
    func send(_ method: String, _ path: String, body: (any Encodable)? = nil, json: Data? = nil, timeout: TimeInterval = 45) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: base.appending(path: "/"))!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body = try json ?? body.map({ try Self.encoder.encode($0) }) {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: signed(request))
        try Self.check(response, data, refused: refused)
        return data
    }

    #if os(macOS)
    /// What waits in the inbox, as `inbox()`, with Oby's plain words for each item, by item id.
    func inboxWithWords(state: String = "open") async throws -> ([InboxItem], [String: InboxWords]) {
        guard let data = try await inboxAnswer(state: state) else { return ([], [:]) }
        return try Self.inboxWithWords(data)
    }

    /// The inbox's answer as it came, or nil from a runner without an inbox (404): what the Mac
    /// keeps to show at its next launch (RunnerFeed.Kept).
    func inboxAnswer(state: String = "open") async throws -> Data? {
        do {
            return try await send("GET", state == "done" ? "v1/inbox?state=done&limit=1000" : "v1/inbox")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// The items and Oby's words for them in an inbox answer.
    static func inboxWithWords(_ data: Data) throws -> ([InboxItem], [String: InboxWords]) {
        (try InboxItem.runnerList(data), InboxWords.of(data))
    }

    /// The latest jobs, with what Engine's Job doesn't read yet, by job id.
    func jobsWithExtras() async throws -> ([Job], [String: RunnerJobExtras]) {
        try Self.jobsWithExtras(try await jobsAnswer())
    }

    /// The latest jobs' answer as it came (RunnerFeed.Kept).
    func jobsAnswer() async throws -> Data {
        try await send("GET", "v1/jobs?limit=50")
    }

    /// The jobs, and their extras by job id, in a jobs answer.
    static func jobsWithExtras(_ data: Data) throws -> ([Job], [String: RunnerJobExtras]) {
        (try decoder.decode([Job].self, from: data), RunnerJobExtras.of(data))
    }

    /// One job, with what Engine's Job doesn't read yet.
    func jobWithExtras(_ id: String) async throws -> (Job, RunnerJobExtras?) {
        let data = try await send("GET", "v1/jobs/\(id)")
        return (try Self.decoder.decode(Job.self, from: data), try? Self.decoder.decode(RunnerJobExtras.self, from: data))
    }

    #endif

    /// One page of the runner's conversation, oldest first (#11): the latest `limit` turns, or the
    /// ones before the turn `before` names. A runner older than the thread has none.
    /// On obid, `id` names the conversation; without it, the latest.
    func conversation(id: String? = nil, before: String? = nil, limit: Int = 50) async throws -> [Turn] {
        try await conversationTurns(id: id, before: before, limit: limit).map(\.turn)
    }

    /// The same page as the runner sends it, with what the app's Turn doesn't keep (the artifacts).
    func conversationTurns(id: String? = nil, before: String? = nil, limit: Int = 50) async throws -> [RunnerTurn] {
        var query = "limit=\(limit)"
        if let id, let id = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { query += "&id=\(id)" }
        if let before, let id = before.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { query += "&before=\(id)" }
        do {
            return try await call("GET", "v1/conversation?\(query)")
        } catch let error as RunnerError where error.status == 404 && before == nil {
            return []
        }
    }

    /// An artifact obid keeps (docs/runner-api.md, "obid only: artifacts"), or nil when there's no
    /// such one (or the runner keeps none).
    func artifact(_ id: String) async throws -> RunnerArtifact? {
        guard let id = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        do {
            return try await call("GET", "v1/artifacts/\(id)")
        } catch let error as RunnerError where error.status == 404 {
            return nil
        }
    }

    /// One file of an artifact's version, with obid's answer as it is (its status and headers,
    /// the Content-Security-Policy among them): the viewer passes it on to its web view.
    func artifactFile(_ ref: ArtifactRef, path: String) async throws -> (Data, HTTPURLResponse) {
        let segments = ([ref.id, String(ref.version)] + path.split(separator: "/").map(String.init))
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? $0 }
        var request = URLRequest(url: URL(string: "v1/artifacts/" + segments.joined(separator: "/"), relativeTo: base.appending(path: "/"))!)
        request.timeoutInterval = 45
        let (data, response) = try await URLSession.shared.data(for: signed(request))
        guard let http = response as? HTTPURLResponse else { throw RunnerError(message: "The runner's answer wasn't HTTP.") }
        return (data, http)
    }

    /// `refused`: what a 401 says (a paired iPhone's pairing ended), else the generic line.
    static func check(_ response: URLResponse, _ data: Data?, refused: String? = nil) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 401, let refused { throw RunnerError(message: refused, status: 401) }
        struct Problem: Decodable { var error: String }
        if let data, let problem = try? JSONDecoder().decode(Problem.self, from: data) { throw RunnerError(message: problem.error, status: http.statusCode) }
        throw RunnerError(message: http.statusCode == 401 ? "The runner didn't let this device in." : "The runner answered \(http.statusCode).",
                          status: http.statusCode)
    }
}

nonisolated struct ResearchDocument: Codable, Equatable, Sendable {
    var job: String
    var commit: String
    var markdown: String
    var proposals: [ResearchProposal]
}

nonisolated struct ResearchProposal: Codable, Equatable, Identifiable, Sendable {
    var index: Int
    var repo: String
    var title: String
    var body: String
    var labels: [String]
    var filed: String?
    var filedAt: Date?
    var id: Int { index }
}

nonisolated struct FileProposalBody: Encodable, Sendable { var start: Bool }
nonisolated struct FileProposalResult: Decodable, Sendable { var issue: String; var jobId: String? }

/// The job `POST /v1/jobs` sends back. Swift leaves nils out, but a missing check keeps the plan's,
/// so no check and the usual model go as null.
nonisolated struct DispatchedJob: Encodable {
    var job: Job

    private enum Nulls: String, CodingKey { case check, model }

    func encode(to encoder: any Encoder) throws {
        try job.encode(to: encoder)
        var nulls = encoder.container(keyedBy: Nulls.self)
        if job.check == nil { try nulls.encodeNil(forKey: .check) }
        if job.model == nil { try nulls.encodeNil(forKey: .model) }
    }
}

/// A watch paired with the runner, as `GET /v1/watches` lists it.
nonisolated struct PairedWatch: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var registered: Date
}

/// An app or API the runner's agents use through its broker, as `GET /v1/connections` lists it
/// (docs/runner-api.md, "Connection"): which vault secret it sends, by name, never its value.
nonisolated struct ConnectedApp: Decodable, Identifiable, Equatable, Sendable {
    var name: String
    /// A remote MCP server's URL, or nil for an API.
    var mcp: String?
    /// An API's base URL, or nil for an MCP server.
    var api: String?
    /// The vault secret's name.
    var secret: String
    /// Where the secret goes: `Authorization` sends it as a bearer token, any other header as it is.
    var header: String?
    /// Whether the runner's vault has the secret now.
    var secretSaved: Bool
    var lastUsed: Date?
    var id: String { name }
}

/// obid's GitHub login, as `GET /v1/github` says: whether it has a gh, whether gh is signed in and
/// as whom, and the sign-in under way. obid never passes on the token.
nonisolated struct GitHubLogin: Decodable, Equatable, Sendable {
    var gh: Bool
    var signedIn: Bool
    var user: String?
    var signIn: GitHubSignIn?
}

/// A tool's own login for one of obid's accounts, under way (`GET /v1/accounts/{id}/sign-in`): its
/// page, the one-time code to type there (Codex), or whether the page ends with a code to send back
/// (Claude Code).
nonisolated struct AccountSignIn: Decodable, Equatable, Sendable {
    var account: String
    var url: URL
    var userCode: String?
    var pasteCode: Bool
    var expiresAt: String?

    /// The tool's own sites, as obid takes the link from its login: the Mac opens nothing else.
    static let sites = ["claude": ["claude.com", "claude.ai", "anthropic.com"], "codex": ["openai.com", "chatgpt.com"],
                        "cursor": ["cursor.com", "cursor.sh"]]

    /// Whether it's a page the Mac opens for `agent`: https on the tool's own site, with no login or port.
    func opens(for agent: String) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host()?.lowercased() else { return false }
        return (Self.sites[agent] ?? []).contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// gh's own sign-in under way: GitHub's device page, the code to type there, when it runs out.
nonisolated struct GitHubSignIn: Decodable, Equatable, Sendable {
    var url: URL
    var userCode: String
    var expiresAt: String

    /// The only page the Mac opens for it.
    static let devicePage = URL(string: "https://github.com/login/device")!

    /// Whether it's what gh's sign-in gives: exactly GitHub's device page, and a code of two groups
    /// of four capitals or digits. The Mac opens and copies nothing else a runner answers.
    var isGitHubs: Bool {
        url == Self.devicePage && userCode.wholeMatch(of: /[A-Z0-9]{4}-[A-Z0-9]{4}/) != nil
    }
}

/// A plug-in obid found, as `GET /v1/obid/plugins` lists it.
nonisolated struct RunnerPlugin: Decodable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var version: String?
    var kinds: [String]
    var enabled: Bool
    /// `disabled`, `starting`, `ready` or `failed`.
    var state: String
    var lastError: String?
}

/// What `POST /v1/jobs/{id}/move` takes: nils are left out.
nonisolated struct MoveBody: Encodable, Sendable {
    var agent: String?
    var account: String?
    var model: String?
    var why: String?
}

/// What the job screens' "Move to…" offers, on the iPhone, the Mac and the Watch (docs/runner-api.md,
/// `POST /v1/jobs/{id}/move`).
nonisolated enum MoveChoice {
    static let tools = [("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor")]
    /// Claude Code's models. Codex's and Cursor's come from the runner's options; Codex's strongest when they don't.
    static let claudeModels = ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
    static let codexStrongest = "gpt-6-astra"
    /// The model that drops the job's own for the tool's from Settings › Models.
    static let toolDefault = "default"
    /// Past this share of either window, an account takes a moved job only when the user picks it.
    static let room = 0.8

    /// "5h 42% · week 61%", "No usage yet", or "Signed out".
    static func usage(signedIn: Bool, fiveHour: Double?, sevenDay: Double?) -> String {
        guard signedIn else { return "Signed out" }
        let parts = [fiveHour.map { "5h \(Int(($0 * 100).rounded()))%" }, sevenDay.map { "week \(Int(($0 * 100).rounded()))%" }].compactMap { $0 }
        return parts.isEmpty ? "No usage yet" : parts.joined(separator: " · ")
    }

    /// Past 80% of either window: Oby won't pick it by itself.
    static func busy(fiveHour: Double?, sevenDay: Double?) -> Bool { max(fiveHour ?? 0, sevenDay ?? 0) >= room }

    /// What a move does to a job in this state, said before it runs.
    static func effect(active: Bool, running: Bool) -> String {
        running ? "Its agent stops, and the round starts over there with the work so far."
            : active ? "It starts there." : "Its next round runs there: tell it something, or Try again."
    }
}

#if os(macOS)
/// obid's `job` event for a job that was deleted.
private nonisolated struct DeletedJob: Decodable { var id: String; var deleted: Bool }
#endif

/// Turns Server-Sent Events lines into events. Unknown events and pings are skipped.
nonisolated struct EventParser {
    private var name = ""
    private var data = ""

    mutating func feed(_ raw: String) -> RunnerEvent? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            defer { name = ""; data = "" }
            let json = Data(data.utf8)
            switch name {
            #if os(macOS)
            case "job":
                // obid's `{"id", "deleted": true}`: the job was deleted, on any app.
                if let gone = try? Runner.decoder.decode(DeletedJob.self, from: json), gone.deleted { return .jobDeleted(gone.id) }
                return (try? Runner.decoder.decode(Job.self, from: json)).map { RunnerEvent.job($0, try? Runner.decoder.decode(RunnerJobExtras.self, from: json)) }
            #else
            case "job": return (try? Runner.decoder.decode(Job.self, from: json)).map(RunnerEvent.job)
            #endif
            case "accounts": return (try? Runner.decoder.decode([RunnerAccount].self, from: json)).map(RunnerEvent.accounts)
            case "clear": return (try? Runner.decoder.decode(ClearedAt.self, from: json)).map { .cleared($0.clearedAt) }
            #if os(macOS)
            case "inbox":
                // Engine's inbox doesn't know the watcher's kind: its item only notifies.
                if let notice = try? Runner.decoder.decode(WatchNotice.self, from: json), WatchNotice.kinds.contains(notice.kind) { return .watchNotice(notice) }
                return InboxItem.runner(json).map { RunnerEvent.inbox($0, try? Runner.decoder.decode(InboxWords.self, from: json)) }
            #else
            case "inbox": return (try? Runner.decoder.decode(InboxItem.self, from: json)).map(RunnerEvent.inbox)
            #endif
            #if os(macOS)
            case "check": return (try? Runner.decoder.decode(MacCheck.self, from: json)).map(RunnerEvent.check)
            case "tetrix": return (try? Runner.decoder.decode(TetrixStatus.self, from: json)).map(RunnerEvent.tetrix)
            case "slack": return (try? Runner.decoder.decode(SlackStatus.self, from: json)).map(RunnerEvent.slack)
            case "sentry": return (try? Runner.decoder.decode(SentryStatus.self, from: json)).map(RunnerEvent.sentry)
            case "watch": return (try? Runner.decoder.decode(WatchStatus.self, from: json)).map(RunnerEvent.watch)
            case "cleanup": return (try? Runner.decoder.decode(RunnerStatus.Cleanup.self, from: json)).map(RunnerEvent.cleanup)
            #endif
            case "turn": return (try? Runner.decoder.decode(RunnerTurn.self, from: json)).map { RunnerEvent.turn($0.turn, $0.extras) }
            case "step": return (try? Runner.decoder.decode(TurnStep.self, from: json)).map(RunnerEvent.step)
            case "conversation": return (try? Runner.decoder.decode(RunnerConversation.self, from: json)).map(RunnerEvent.conversation)
            case "delta": return (try? Runner.decoder.decode(TurnDelta.self, from: json)).map(RunnerEvent.delta)
            case "artifact": return (try? Runner.decoder.decode(ArtifactEvent.self, from: json)).map(RunnerEvent.artifact)
            case "routine": return .routine
            case "github": return (try? Runner.decoder.decode(GitHubWork.self, from: json)).map(RunnerEvent.github)
            case "transcript": return (try? Runner.decoder.decode(TranscriptEvent.self, from: json)).map(RunnerEvent.transcript)
            default: return nil
            }
        }
        if line.hasPrefix("event:") { name = line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("data:") { data += (data.isEmpty ? "" : "\n") + line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        return nil
    }
}

/// Which routine's run a job is (docs/runner-api.md, "obid only: routines (#395)").
nonisolated struct RoutineMark: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var scheduled: Date?
    var catchUp: Bool?

    /// What a job's card and page say: "From routine: Review open PRs" (Sangam's design).
    var line: String { "From routine: \(name)" }
}

/// Teammates' open pull requests that change a job's files (obid only: docs/runner-api.md,
/// "obid only: teammates' pull requests"). Titles are what people wrote: never shown as obid's words.
nonisolated struct TeammatePRs: Codable, Equatable, Sendable {
    struct PR: Codable, Equatable, Sendable {
        var number: Int
        var author: String
        var files: [String]
        /// After the job's commits: the code both change, empty when only files are shared.
        var clash: [String]?
    }
    var prs: [PR]

    /// What a job's page says under its head: "Also changed in @alice's #812 (src/jobs.rs)", or
    /// "Same code changed in …" once the check after its commits found some; nil when none.
    var line: String? {
        guard !prs.isEmpty else { return nil }
        let same = prs.contains { !($0.clash ?? []).isEmpty }
        let who = prs.map { "@\($0.author)'s #\($0.number)" }
        var files: [String] = []
        for file in prs.flatMap(\.files) where !files.contains(file) { files.append(file) }
        let named = who.count < 3 ? who.joined(separator: " and ") : who.dropLast().joined(separator: ", ") + " and " + who.last!
        let shown = files.prefix(3).joined(separator: ", ") + (files.count > 3 ? " and \(files.count - 3) more" : "")
        return "\(same ? "Same code changed in" : "Also changed in") \(named) (\(shown))"
    }
}

/// A routine as obid lists it: a saved request it runs on a schedule, a job each time.
/// One memory obid keeps (docs/runner-api.md, "obid only: memory").
nonisolated struct RunnerMemory: Codable, Identifiable, Equatable, Sendable {
    var id: String
    /// `user` or `project`.
    var scope: String
    var repo: String?
    var kind: String
    var title: String
    var text: String
    /// Where it came from, in obid's words: "You said it in 3 conversations".
    var from: String
    var created: Date
}

/// A memory obid could keep, waiting for Remember or Not this.
nonisolated struct RunnerMemorySuggestion: Codable, Identifiable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        var quote: String
        /// `You, in “Release planning”` or `A review on obi-ai-bot/obi#12`.
        var place: String
        var link: URL?
    }

    var id: String
    var scope: String
    var repo: String?
    var title: String
    var text: String
    var from: String
    var sources: [Source]
}

/// `GET /v1/obid/sharing/mac` (docs/runner-api.md, "obid only: sharing this Mac").
nonisolated struct RunnerSharingMac: Codable, Equatable, Sendable {
    struct Settings: Codable, Equatable, Sendable {
        var on: Bool
        var when: [String]
        var who: String
        var people: [String]
        var allowed: [String]
        var jobsAtOnce: Int
        var size: String
        var work: String
        var maxMinutes: Int
    }
    /// A teammate's job on this Mac now.
    struct Guest: Codable, Equatable, Sendable, Identifiable {
        var correlationId: String
        var fromOwner: String
        var title: String
        var repo: String
        var agent: String
        var started: Date
        var state: String
        var id: String { correlationId }
    }
    /// This Mac's last 7 days of teammates' jobs (#810); nil from an obid before it.
    struct Week: Codable, Equatable, Sendable {
        var jobs: Int
        var wallSeconds: Int
        var costCents: Int
    }
    /// The guest image obid fetches when sharing is turned on (`none`, `fetching`, `ready`,
    /// `failed`); nil from an obid before it.
    struct Image: Codable, Equatable, Sendable {
        var state: String
        var done: Int64?
        var total: Int64?
        var error: String?
    }
    var settings: Settings
    var ready: Bool
    var image: Image? = nil
    var jobs: [Guest]
    var week: Week? = nil
    /// The people chosen ("Only people I choose") who haven't joined the Obysphere yet: the Mac
    /// isn't offered to them until they do. Nil from an obid before it.
    var waiting: [String]? = nil
}

/// A teammate's Mac a job can run on (`GET /v1/obid/sharing/macs`).
nonisolated struct RunnerMac: Codable, Equatable, Sendable, Identifiable {
    var obi: String
    var owner: String
    var free: Bool
    /// Whether you compared its owner's key with them and accepted it (false: trusted on first
    /// sight only; nil from an older obid).
    var verified: Bool?
    var id: String { obi }
    /// "Wellington’s Mac".
    var name: String { "\(RunnerMac.person(owner))’s Mac" }
    /// An owner id as a name: `wellington` is Wellington.
    static func person(_ owner: String) -> String { owner.prefix(1).uppercased() + owner.dropFirst() }
}

/// `GET /v1/obid/sharing/grants` (docs/runner-api.md, "obid only: sharing your usage").
nonisolated struct RunnerGrants: Codable, Equatable, Sendable {
    /// A share of one of the owner's company API accounts.
    struct Grant: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var label: String
        var account: String?
        var who: String
        var share: Int
        var extra: Int
        var budgetCents: Int
        var resetsDay: Int
        var resets: Date
        var limitCents: Int
        /// This month's use by owner, the owner's own jobs on the account included.
        var usedCents: [String: Int]
        /// The vault secret its key is kept under, and whether it's there (nil from an older obid).
        var keyName: String?
        var keyInVault: Bool?
    }
    /// One of the owner's accounts: `why` is nil for one that can be shared, else why it's kept.
    struct Account: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var agent: String
        var name: String
        var plan: String
        var why: String?
    }
    var grants: [Grant]
    var accounts: [Account]
    /// Whether the key the shares run on is in Oby's vault.
    var key: Bool
}

/// `GET /v1/obid/sharing/shared`: the shares teammates gave this owner.
nonisolated struct RunnerShares: Codable, Equatable, Sendable {
    struct Share: Codable, Equatable, Sendable, Identifiable {
        var grant: String
        /// Their Obi, whose Mac jobs on it run on.
        var from: String
        var owner: String
        var agent: String
        var account: String
        var share: Int
        var limitCents: Int
        var usedCents: Int
        var resets: Date
        var id: String { grant }
        /// "Wellington’s Deskree API".
        var name: String { "\(RunnerMac.person(owner))’s \(account)" }
        /// Of its month, in percent: the share, and what's left of it.
        var left: Int { limitCents == 0 ? 0 : max(0, share * (limitCents - usedCents) / limitCents) }
    }
    var shares: [Share]
    var takesShares: Bool
}

nonisolated struct RunnerMemoryList: Codable, Equatable, Sendable {
    var memories: [RunnerMemory]
    var suggestions: [RunnerMemorySuggestion]
}

nonisolated struct RunnerMemoryFound: Codable, Equatable, Sendable {
    struct Read: Codable, Equatable, Sendable {
        var conversations: Int
        var pullRequests: Int
    }

    var suggestions: [RunnerMemorySuggestion]
    var read: Read
    var problems: [String]
}

nonisolated struct RunnerRoutine: Codable, Identifiable, Equatable, Sendable {
    struct Run: Codable, Equatable, Sendable {
        var scheduled: Date
        var at: Date
        /// `started`, `skipped`, `missed` or `failed`.
        var outcome: String
        var reason: String?
        var job: String?
        var catchUp: Bool?
        /// Its job's end once it ended: `done`, `failed`, `stopped`, `interrupted`.
        var ended: String?
    }

    var id: String
    var name: String
    var repo: String
    var kind: String
    var task: String
    /// obid's words for its schedule: "Weekdays at 9:00".
    var when: String
    var zone: String
    var enabled: Bool
    var nextRun: Date?
    var failuresInARow: Int?
    var lastRun: Run?
    var conversation: String?

    var repoName: String { String(repo.split(separator: "/").last ?? Substring(repo)) }

    /// Under its name: the schedule and repository, then when it runs next (Sangam's "Starts
    /// Monday at 9") or that it's paused, then how the last run went.
    func about(now: Date = .now) -> String {
        var parts = ["\(when) · \(repoName)"]
        if let next = nextRun, enabled {
            parts.append("Next " + Self.day(next, now: now))
        } else {
            parts.append("Paused")
        }
        if let last = lastRun {
            switch (last.outcome, last.ended) {
            case ("started", nil): parts.append("Running now")
            case ("started", "done"): parts.append("Last run done")
            case ("started", "failed"): parts.append("Last run failed")
            case ("started", let end?): parts.append("Last run \(end)")
            case ("skipped", _): parts.append("Last run skipped")
            case ("missed", _): parts.append("Missed a run")
            default: parts.append("Last run couldn't start")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Its next run as Home's Routines page says it (Sangam's "Starts Monday at 9"), or nil while
    /// paused.
    func starts(now: Date = .now) -> String? {
        guard enabled, let next = nextRun else { return nil }
        let day = Self.day(next, now: now)
        return "Starts " + day
    }

    /// The routines waiting for their next run, soonest first.
    static func upcoming(_ routines: [RunnerRoutine]) -> [RunnerRoutine] {
        routines.filter { $0.enabled && $0.nextRun != nil }.sorted { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) }
    }

    /// "today at 9:00", "tomorrow at 9:00", "Monday at 9:00", or "Oct 30 at 9:00", in this device's zone.
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        if date.timeIntervalSince(now) < 6 * 24 * 3600 { return "\(date.formatted(.dateTime.weekday(.wide))) at \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }
}
