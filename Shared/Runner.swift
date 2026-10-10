import Foundation

// The Mac compiles Engine/, whose Job is what the runner sends: it reads jobs into that one, and
// has its own Account. Only the iPhone needs these copies.
#if os(iOS)
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
    var status: Status
    var step: String
    var summary: String
    var session: String?
    var created: Date
    var started: Date?
    var finished: Date?
    var commits: Int?
    var published: String?
    /// Newer runners only, so all optional: the issue the work is about, how many rounds the agent
    /// may take and the one it's on, the command that must pass, the stronger model it runs on,
    /// and what the user told the agent along the way, oldest first.
    var issue: Int?
    var rounds: Int?
    var round: Int?
    var check: String?
    var model: String?
    var notes: [String]?

    var isActive: Bool { status == .queued || status == .running }
    var repoName: String { String(repo.split(separator: "/").last ?? Substring(repo)) }
    var agentName: String { agent == "codex" ? "Codex" : "Claude Code" }

    /// "Review oby #33", or the first line of what the user asked.
    var title: String {
        if let number = pr ?? issue { return "\(kind.capitalized) \(repoName) #\(number)" }
        return request.split(separator: "\n").first.map(String.init) ?? request
    }

    /// The one line a finished job is known by.
    var line: String {
        switch status {
        case .queued, .running: step
        case .done: summary.split(separator: "\n").first.map(String.init) ?? "Done"
        case .failed, .stopped, .interrupted: summary.split(separator: "\n").first.map(String.init) ?? status.rawValue.capitalized
        }
    }

    var canPublish: Bool { status == .done && (commits ?? 0) > 0 && published == nil }

    /// Waiting for Publish, failed or interrupted: what the runner sends an alert for.
    var needsYou: Bool { canPublish || status == .failed || status == .interrupted }

    /// "Round 2 of 5 · Fable 5.1", or empty for a one-round job on the usual model.
    var extras: String {
        var parts: [String] = []
        if let rounds, rounds > 1 { parts.append("Round \(round ?? 1) of \(rounds)") }
        if let model { parts.append(ModelChoice.name(model)) }
        return parts.joined(separator: " · ")
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
    var running: Int

    /// "Personal · Claude Code"
    var title: String { "\(name) · \(agent == "codex" ? "Codex" : "Claude Code")" }
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
    #if os(iOS)
    var accounts: [Account]
    #endif
    var models: ModelSettings
}

/// One thing the runner reports while the app is open.
nonisolated enum RunnerEvent: Equatable, Sendable {
    case job(Job)
    case accounts([Account])
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
            default: return nil
            }
        }
        if line.hasPrefix("event:") { name = line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("data:") { data += (data.isEmpty ? "" : "\n") + line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        return nil
    }
}
