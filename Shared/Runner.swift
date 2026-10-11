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

    var isActive: Bool { status == .queued || status == .running }
    /// Its agent asked the user something and waits for the answer: its alert stays until then.
    var waitsForAnswer: Bool { question != nil && dismissed == nil && status != .stopped }

    /// The report's list of what Oby sent out for the job, or nil when nothing went out.
    var sentLines: String? {
        guard let outgoing, !outgoing.isEmpty else { return nil }
        return "Sent by Oby:\n" + outgoing.map { "- \($0.line)" }.joined(separator: "\n")
    }
    var repoName: String { String(repo.split(separator: "/").last ?? Substring(repo)) }
    var agentName: String { agent == "codex" ? "Codex" : "Claude Code" }

    /// The runner's title, like "Mac runner notifications", else "Review oby #33" or the first line
    /// of what the user asked.
    var heading: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let number = pr ?? issue { return "\(kind.capitalized) \(repoName) #\(number)" }
        return (task.isEmpty ? request : task).split(separator: "\n").first.map(String.init) ?? request
    }

    /// The one line a finished job is known by.
    var line: String {
        switch status {
        case .queued, .running: step
        case .done: summary.split(separator: "\n").first.map(String.init) ?? "Done"
        case .failed, .stopped, .interrupted: summary.split(separator: "\n").first.map(String.init) ?? status.rawValue.capitalized
        }
    }

    /// Commits not on its pull request yet: all of them before it's published, then later rounds' ones.
    var unpublished: Int { max(0, (commits ?? 0) - (published == nil ? 0 : pushed ?? commits ?? 0)) }
    /// Not once the user dismissed it, never on Oby's own review jobs, and never once its pull
    /// request was merged or closed (as Engine's `Job.canPublish`).
    var canPublish: Bool {
        status == .done && base != nil && unpublished > 0 && dismissed == nil && reviewOf == nil
            && (pullRequest?.state ?? "OPEN") == "OPEN"
    }

    /// Oby's review requested changes for the last time it may (4 rounds) and the pull request is still open.
    var reviewNeedsYou: Bool {
        status == .done && published != nil && review?.verdict == "changesRequested" && (review?.round ?? 0) >= 4
            && (pullRequest?.state ?? "OPEN") == "OPEN"
    }

    /// Done with commits its pull request won't take: merged or closed before they went out (as Engine's `Job.stranded`).
    var stranded: Bool {
        status == .done && published != nil && unpublished > 0 && reviewOf == nil
            && (pullRequest.map { $0.state != "OPEN" } ?? false)
    }

    /// Waiting for Publish (the runner's own publish failed), failed, interrupted, out of review
    /// rounds or stranded, and not dismissed: what the runner sends an alert for, and what Dismiss takes.
    var needsYou: Bool { dismissed == nil && (canPublish || stranded || status == .failed || status == .interrupted || reviewNeedsYou) }

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
    var comment: String?
    var postError: String?

    var label: String { verdict == "approved" ? "Approved" : "Changes requested" }
}

/// Something the runner sent out for a job (docs/runner-api.md): ids only, never what was sent.
nonisolated struct Outgoing: Codable, Equatable, Sendable {
    /// "push", "pullRequest", "pullRequestEdit" or "comment"; a newer runner may send others.
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

    /// "Personal · Claude Code"
    var title: String { "\(name) · \(Usage.tool(agent))" }

    /// What Settings' usage card shows.
    var usage: Usage.Snapshot {
        Usage.Snapshot(agent: agent, name: name, label: label, fiveHour: fiveHour, sevenDay: sevenDay,
                       fiveHourResets: fiveHourResets, sevenDayResets: sevenDayResets, running: running)
    }
}
#endif

/// The plan card, before anything runs.
nonisolated struct Draft: Codable, Equatable, Sendable {
    var said: String
    var reply: String
    var guessed: Bool
    var job: Job
    /// A stronger model the brain offers for complex work, or nil.
    var suggestedModel: String?

    /// The stronger model on `agent`'s tool, or nil when none was offered. The runner runs the
    /// stronger model of the tool the job ends up with, so picking another account changes it.
    func strongerModel(for agent: String) -> String? {
        guard let suggestedModel else { return nil }
        return agent == job.agent ? suggestedModel : ["claude": "claude-fable-5-1", "codex": "gpt-6-astra"][agent]
    }
}

nonisolated struct Question: Codable, Equatable, Sendable {
    var text: String
    var options: [String]
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
    var created: Date
    var done: Date?
    var later: Date?
    var answer: String?

    var isOpen: Bool { done == nil }
    func waiting(at now: Date = .now) -> Bool { done == nil && (later.map { $0 <= now } ?? true) }
}
#endif

extension InboxItem {
    /// "Failed · Mac runner notifications · waiting 3m": what kind of item, its job, how long it waited.
    nonisolated func line(now: Date = .now) -> String {
        // The Mac's `kind` is Engine's enum, the iPhone's a string: both read the same.
        let label = switch "\(kind)" {
        case "question": "Question"
        case "review": "Out of reviews"
        case "limit": "Out of usage"
        default: "Failed"
        }
        return "\(label) · \(title) · \(Elapsed.waiting(since: created, now: now))"
    }

    /// The inbox as the apps show it: what waits now, the longest-waiting first.
    nonisolated static func waiting(_ items: [InboxItem], now: Date = .now) -> [InboxItem] {
        items.filter { $0.waiting(at: now) }.sorted { $0.created < $1.created }
    }
}

/// What the brain made of the user's words.
nonisolated enum PlanResult: Decodable, Equatable, Sendable {
    /// One draft per job, 1 to 10.
    case plan([Draft])
    case question(said: String, Question)
    case reply(String)
    case none

    private enum Keys: String, CodingKey { case kind, drafts, draft, said, question, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "plan":
            // Older runners send only `draft`.
            let drafts = try c.decodeIfPresent([Draft].self, forKey: .drafts) ?? []
            self = .plan(drafts.isEmpty ? [try c.decode(Draft.self, forKey: .draft)] : drafts)
        case "question": self = .question(said: try c.decode(String.self, forKey: .said), try c.decode(Question.self, forKey: .question))
        case "reply": self = .reply(try c.decode(String.self, forKey: .text))
        default: self = .none
        }
    }
}

nonisolated struct ModelChoice: Codable, Equatable, Sendable {
    var model: String
    var effort: String
}

extension ModelChoice {
    /// "Opus 5.5 · Extra high"
    nonisolated var label: String {
        "\(Self.name(model)) · \(effort == "xhigh" ? "Extra high" : effort.capitalized)"
    }

    /// "Fable 5.1", "GPT-6-Astra", or the id as it is.
    nonisolated static func name(_ model: String) -> String {
        let names = ["claude-opus-5-5": "Opus 5.5", "claude-sonnet-5-5": "Sonnet 5.5", "claude-haiku-5-5": "Haiku 5.5",
                     "claude-fable-5-1": "Fable 5.1", "gpt-6-astra": "GPT-6-Astra"]
        return names[model] ?? model
    }
}

nonisolated struct ModelSettings: Codable, Equatable, Sendable {
    var claude: ModelChoice
    var codex: ModelChoice
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
    }
    var claude: Tool
    var codex: Tool
}

nonisolated struct RunnerStatus: Codable, Equatable, Sendable {
    struct Runner: Codable, Equatable, Sendable {
        var version: String
        var host: String
    }
    var runner: Runner
    #if os(iOS) || os(watchOS)
    var accounts: [Account]
    #endif
    var models: ModelSettings
    /// When Clear done was last pressed, on any app, or nil (docs/runner-api.md). Older runners don't send it.
    var clearedAt: Date?
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
    case job(Job)
    case accounts([Account])
    /// Clear done was pressed, here or on another app: jobs that finished by then are hidden.
    case cleared(Date)
    /// An inbox item came, was answered, done or put off, here or on another app.
    case inbox(InboxItem)
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
        switch status {
        case .queued, .running: step
        case .done: summary.split(separator: "\n").first.map(String.init) ?? "Done"
        case .failed, .stopped, .interrupted: summary.split(separator: "\n").first.map(String.init) ?? status.rawValue.capitalized
        }
    }
    #endif

    /// Where the list puts the job (Shared/JobList.swift): what needs you first, then the ones
    /// working, then published ones whose pull request is still open, then everything else.
    nonisolated var group: JobGroup {
        if needsYou { return .needsYou }
        if isActive { return .working }
        if status == .done, published != nil, (pullRequestState ?? "OPEN") == "OPEN" { return .inReview }
        return .done
    }

    /// Whether the list shows the job after the last Clear done, on any app (Shared/JobList.swift).
    nonisolated func listed(after clearedAt: Date?) -> Bool {
        JobList.lists(active: isActive, needsYou: needsYou, finished: finished, clearedAt: clearedAt)
    }

    /// Clear done would take it from the list (Shared/JobList.swift).
    nonisolated var clearable: Bool { JobList.clears(active: isActive, needsYou: needsYou) }

    /// The status pill, the same on the iPhone and the Mac: how it's going, how it ended, and
    /// where its pull request is. A job you let go says Dismissed, however it ended.
    nonisolated var badge: JobBadge {
        if dismissed != nil { return JobBadge(text: "Dismissed", tone: .gray) }
        switch status {
        case .queued: return JobBadge(text: "Starting", tone: .blue)
        case .running: return JobBadge(text: "Working", tone: .blue)
        case .done where canPublish: return JobBadge(text: "Ready to publish", tone: .orange)
        case .done where pullRequestState == "MERGED": return JobBadge(text: "Merged", tone: .green)
        case .done where pullRequestState == "CLOSED": return JobBadge(text: "PR closed", tone: .gray)
        case .done where reviewDecision == "CHANGES_REQUESTED": return JobBadge(text: "Changes requested", tone: .orange)
        case .done where reviewDecision == "APPROVED": return JobBadge(text: "Approved", tone: .green)
        case .done where published != nil: return JobBadge(text: "In review", tone: .blue)
        case .done: return JobBadge(text: "Done", tone: .green)
        case .failed: return JobBadge(text: "Failed", tone: .red)
        case .stopped: return JobBadge(text: "Stopped", tone: .gray)
        case .interrupted: return JobBadge(text: "Interrupted", tone: .gray)
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
/// `Summary.line` (Shared/JobList.swift). Dismissed jobs aren't counted.
nonisolated enum NeedsYou {
    static func line(_ jobs: [Job]) -> String? {
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : n == 1 ? "1 job \(one)" : "\(n) jobs \(many)" }
        let needing = jobs.filter(\.needsYou)
        let parts = [
            count(needing.count(where: \.canPublish), "is ready to publish", "are ready to publish"),
            count(needing.count { $0.status == .failed }, "failed", "failed"),
            count(needing.count { $0.status == .interrupted }, "was interrupted", "were interrupted"),
            count(needing.count(where: \.reviewNeedsYou), "needs your review", "need your review"),
            count(needing.count(where: \.stranded), "wasn't published", "weren't published"),
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

nonisolated struct RunnerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The runner on the tailnet. `tailscale serve` vouches for who's asking, so there's no token.
nonisolated struct Runner: Sendable {
    var base: URL

    static let defaultURL = URL(string: "https://tetrix-lab.tail8de49b.ts.net:8443")!

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
    /// Clear done: the runner records now, and every app hides the jobs that finished by then.
    func clear() async throws -> Date {
        let answer: ClearedAt = try await call("POST", "v1/clear")
        return answer.clearedAt
    }

    /// What waits in the inbox, put-off items too.
    func inbox() async throws -> [InboxItem] { try await call("GET", "v1/inbox") }

    /// Settles an inbox item: an answer (one of its options, or the user's words) goes to its job;
    /// `done` lets it go without one; `later` puts it off until then. Send one of them.
    func settle(_ id: String, answer: String? = nil, done: Bool? = nil, later: Date? = nil) async throws -> InboxItem {
        struct Body: Encodable { var answer: String?; var done: Bool?; var later: Date? }
        return try await call("POST", "v1/inbox/\(id)/answer", body: Body(answer: answer, done: done, later: later))
    }

    /// Tells the job's agent something. A finished job picks its session up again.
    func tell(_ id: String, _ text: String) async throws -> Job {
        struct Body: Encodable { var text: String }
        return try await call("POST", "v1/jobs/\(id)/messages", body: Body(text: text))
    }
    func models() async throws -> ModelSettings { try await call("GET", "v1/settings/models") }
    func modelOptions() async throws -> ModelOptions { try await call("GET", "v1/settings/models/options") }

    func setModels(_ models: ModelSettings) async throws -> ModelSettings {
        try await call("PUT", "v1/settings/models", body: models)
    }

    func plan(_ said: String, answer: (question: String, option: String)? = nil) async throws -> PlanResult {
        struct Answer: Encodable { var question: String; var option: String }
        struct Body: Encodable { var said: String; var answer: Answer? }
        return try await call("POST", "v1/plans", body: Body(said: said, answer: answer.map { Answer(question: $0.question, option: $0.option) }))
    }

    func dispatch(_ job: Job) async throws -> Job {
        struct Body: Encodable { var job: DispatchedJob }
        return try await call("POST", "v1/jobs", body: Body(job: DispatchedJob(job: job)))
    }

    /// The exact sentence publishing would carry out.
    func publishAction(_ id: String) async throws -> String {
        struct Answer: Decodable { var action: String }
        let answer: Answer = try await call("GET", "v1/jobs/\(id)/publish")
        return answer.action
    }

    // Approvals come from the iPhone's Face ID key (iOS/DeviceKey.swift).
    #if os(iOS)
    func publish(_ id: String, approval: Approval) async throws -> URL {
        struct Answer: Decodable { var url: URL }
        let answer: Answer = try await call("POST", "v1/jobs/\(id)/publish", body: approval)
        return answer.url
    }
    #endif

    func register(name: String, publicKey: Data) async throws -> String {
        struct Body: Encodable { var name: String; var publicKey: String }
        struct Answer: Decodable { var id: String }
        let answer: Answer = try await call("POST", "v1/devices", body: Body(name: name, publicKey: publicKey.base64EncodedString()))
        return answer.id
    }

    /// Server-Sent Events until the connection drops; the caller reconnects.
    func events() -> AsyncThrowingStream<RunnerEvent, Error> {
        AsyncThrowingStream { stream in
            let task = Task {
                do {
                    var request = URLRequest(url: base.appending(path: "v1/events"))
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 60
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try Self.check(response, nil)
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

    /// Hands the runner the app's device token, for alerts when a job needs the user. Answers
    /// whether the runner pushes.
    func registerNotifications(token: Data) async throws -> Bool {
        struct Body: Encodable { var token: String; var topic: String; var environment: String }
        struct Answer: Decodable { var push: Bool }
        let body = Body(token: Self.hex(token), topic: Bundle.main.bundleIdentifier ?? "", environment: Self.environment)
        let answer: Answer = try await call("POST", "v1/notifications", body: body)
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

    private func call<Answer: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> Answer {
        var request = URLRequest(url: URL(string: path, relativeTo: base.appending(path: "/"))!)
        request.httpMethod = method
        // Planning waits for the brain, which can take up to about 20 seconds.
        request.timeoutInterval = 45
        if let body {
            request.httpBody = try Self.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try Self.decoder.decode(Answer.self, from: data)
    }

    static func check(_ response: URLResponse, _ data: Data?) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        struct Problem: Decodable { var error: String }
        if let data, let problem = try? JSONDecoder().decode(Problem.self, from: data) { throw RunnerError(message: problem.error) }
        throw RunnerError(message: http.statusCode == 401 ? "The runner only answers its owner's Tailscale login." : "The runner answered \(http.statusCode).")
    }
}

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
            case "job": return (try? Runner.decoder.decode(Job.self, from: json)).map(RunnerEvent.job)
            case "accounts": return (try? Runner.decoder.decode([Account].self, from: json)).map(RunnerEvent.accounts)
            case "clear": return (try? Runner.decoder.decode(ClearedAt.self, from: json)).map { .cleared($0.clearedAt) }
            case "inbox": return (try? Runner.decoder.decode(InboxItem.self, from: json)).map(RunnerEvent.inbox)
            default: return nil
            }
        }
        if line.hasPrefix("event:") { name = line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("data:") { data += (data.isEmpty ? "" : "\n") + line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        return nil
    }
}
