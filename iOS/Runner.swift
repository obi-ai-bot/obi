import Foundation

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

    var isActive: Bool { status == .queued || status == .running }
    var repoName: String { String(repo.split(separator: "/").last ?? Substring(repo)) }
    var agentName: String { agent == "codex" ? "Codex" : "Claude Code" }

    /// "Review oby #33", or the first line of what the user asked.
    var title: String {
        if let pr { return "\(kind.capitalized) \(repoName) #\(pr)" }
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

/// The plan card, before anything runs.
nonisolated struct Draft: Codable, Equatable, Sendable {
    var said: String
    var reply: String
    var guessed: Bool
    var job: Job
}

nonisolated struct Question: Codable, Equatable, Sendable {
    var text: String
    var options: [String]
}

/// What the brain made of the user's words.
nonisolated enum PlanResult: Decodable, Equatable, Sendable {
    case plan(Draft)
    case question(said: String, Question)
    case reply(String)
    case none

    private enum Keys: String, CodingKey { case kind, draft, said, question, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "plan": self = .plan(try c.decode(Draft.self, forKey: .draft))
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
        let names = ["claude-opus-5-5": "Opus 5.5", "claude-sonnet-5-5": "Sonnet 5.5",
                     "claude-haiku-5-5": "Haiku 5.5", "claude-fable-5-1": "Fable 5.1"]
        return "\(names[model] ?? model) · \(effort == "xhigh" ? "Extra high" : effort.capitalized)"
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
    var accounts: [Account]
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
        struct Body: Encodable { var job: Job }
        return try await call("POST", "v1/jobs", body: Body(job: job))
    }

    /// The exact sentence publishing would carry out.
    func publishAction(_ id: String) async throws -> String {
        struct Answer: Decodable { var action: String }
        let answer: Answer = try await call("GET", "v1/jobs/\(id)/publish")
        return answer.action
    }

    func publish(_ id: String, approval: Approval) async throws -> URL {
        struct Answer: Decodable { var url: URL }
        let answer: Answer = try await call("POST", "v1/jobs/\(id)/publish", body: approval)
        return answer.url
    }

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
