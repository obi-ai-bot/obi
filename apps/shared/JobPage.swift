import Foundation

// The job page's facts (obi-ai-bot/obi#739, Alternative B), as obid serves them on the job object
// (docs/runner-api.md; the field contract in #739). Every one is optional: absent means this obid
// doesn't serve it yet, and its part of the page hides; nothing shows 0 or an invented value.
// Foundation only: the Watch compiles it with the iPhone's Job.

/// A value the runner sends that this app may not be able to read: decoding it never throws, and
/// one that can't be read is nil, so a newer or malformed part never fails what it's in.
nonisolated struct Lenient<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var value: Value?

    init(_ value: Value?) { self.value = value }

    init(from decoder: any Decoder) throws {
        // Through the container, so the decoder's date strategy applies to a `Date`.
        value = try? decoder.singleValueContainer().decode(Value.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value { try container.encode(value) } else { try container.encodeNil() }
    }
}

/// A job's published address, only when it's a GitHub page over https: what the apps open.
nonisolated enum PublishedLink {
    static func url(_ published: String?) -> URL? {
        guard let published, let url = URL(string: published), url.scheme == "https", url.host == "github.com" else { return nil }
        return url
    }
}

/// What each kind of tool ran, by kind; a kind the tool doesn't report is absent, never 0.
nonisolated struct ToolCounts: Codable, Equatable, Sendable {
    var read: Int?
    var search: Int?
    var edit: Int?
    var command: Int?
    var test: Int?
    var tetrix: Int?
    var web: Int?
    var mcp: Int?

    /// Each kind above zero, in the page's order: (23, "read"), (9, "searches")…
    var chips: [(count: Int, label: String)] {
        let kinds: [(Int?, String, String)] = [
            (read, "read", "read"), (search, "search", "searches"), (edit, "edit", "edits"),
            (command, "command", "commands"), (test, "test run", "test runs"), (tetrix, "Tetrix", "Tetrix"),
            (web, "web", "web"), (mcp, "MCP", "MCP"),
        ]
        return kinds.compactMap { count, one, many in count.flatMap { $0 > 0 ? ($0, $0 == 1 ? one : many) : nil } }
    }

    /// "23 read · 9 searches · 3 edits", or nil when nothing ran.
    var line: String? {
        let chips = chips
        return chips.isEmpty ? nil : chips.map { "\($0.count) \($0.label)" }.joined(separator: " · ")
    }
}

/// Lines added and removed.
nonisolated struct LineDiff: Codable, Equatable, Sendable {
    var added: Int?
    var removed: Int?
}

/// One tool call: what it is, in the agent's words shortened, and how long it ran.
nonisolated struct JobTool: Codable, Equatable, Sendable {
    var tool: String?
    var kind: String?
    var summary: String
    /// "running", "done" or "failed"; a newer obid's other words read as done.
    var state: String?
    var started: Date?
    var seconds: Double?

    var running: Bool { state == "running" }
    var failed: Bool { state == "failed" }
}

/// A few tool calls that did one thing ("Testing the change"), as obid groups them.
nonisolated struct ActivityGroup: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var state: String?
    var started: Date?
    var finished: Date?
    var counts: ToolCounts?
    var files: [String]?
    var diff: LineDiff?
    /// Only on the running group, plus the last 3 of a finished one.
    var tools: [JobTool]?

    var running: Bool { state == "running" }
    var failed: Bool { state == "failed" }
}

nonisolated struct JobActivity: Codable, Equatable, Sendable {
    var counts: ToolCounts?
    var groups: [ActivityGroup]?
}

/// This job's tokens and what they'd cost at API prices (`priced`: "api" or "plan").
nonisolated struct JobUsage: Codable, Equatable, Sendable {
    var input: Int?
    var output: Int?
    var cacheRead: Int?
    var cacheWrite: Int?
    var costUsd: Double?
    var priced: String?

    /// All the tokens it reports, or nil when it reports none.
    var tokens: Int? {
        let parts = [input, output, cacheRead, cacheWrite].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

/// The percentage points of each limit window this job used, estimated.
nonisolated struct WindowShare: Codable, Equatable, Sendable {
    var fiveHour: Double?
    var sevenDay: Double?
    var estimate: Bool?
}

/// A range of seconds.
nonisolated struct Span: Codable, Equatable, Sendable {
    var low: Double
    var high: Double
}

/// How long the whole job should take, in seconds, and where that comes from in a plain sentence.
nonisolated struct JobEstimate: Codable, Equatable, Sendable {
    var low: Double
    var high: Double
    var basis: String?
    var samples: Int?
    /// The range it gave first, for "estimated 12–20m" once it's done.
    var firstGiven: Span?
}

/// A stage's own times: when it started and ended, how long it waited on you (not in its
/// duration), and what it should take while it's to come or under way.
nonisolated struct StageTiming: Codable, Equatable, Sendable {
    var started: Date?
    var finished: Date?
    var waited: Double?
    var estimate: Span?
}

nonisolated struct TestCount: Codable, Equatable, Sendable {
    var passed: Int?
    var failed: Int?
    var total: Int?
}

/// One command of the job's check.
nonisolated struct CheckStep: Codable, Equatable, Sendable {
    var command: String
    var passed: Bool?
    var seconds: Double?
    var running: Bool?
    var tests: TestCount?
}

nonisolated struct FailingTest: Codable, Equatable, Sendable {
    var test: String
    var message: String?
}

/// One round of the check: its commands, and the tests that failed.
nonisolated struct CheckRound: Codable, Equatable, Sendable {
    var round: Int?
    var steps: [CheckStep]
    var failing: [FailingTest]?
}

/// The secret scan before the push. Never the matched text.
nonisolated struct JobScan: Codable, Equatable, Sendable {
    struct Finding: Codable, Equatable, Sendable {
        var file: String
        var line: Int?
        var rule: String?
    }

    var ran: Bool?
    var clean: Bool?
    var commits: Int?
    var files: Int?
    var seconds: Double?
    var reason: String?
    var findings: [Finding]?
}

nonisolated struct JobDiff: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        var path: String
        var added: Int?
        var removed: Int?
    }

    var files: Int?
    var added: Int?
    var removed: Int?
    var byFile: [File]?
}

/// Everything the page reads beyond today's job: each part on its own, any of them missing.
nonisolated struct JobFacts: Decodable, Equatable, Sendable {
    var activity: JobActivity?
    var usage: JobUsage?
    var windowShare: WindowShare?
    var estimate: JobEstimate?
    var checks: [CheckRound]?
    var scan: JobScan?
    var diff: JobDiff?
    /// What the current stage is doing and why, in a plain sentence.
    var context: String?
    /// Each stage's times, by stage id.
    var stages: [String: StageTiming] = [:]

    init(activity: JobActivity? = nil, usage: JobUsage? = nil, windowShare: WindowShare? = nil, estimate: JobEstimate? = nil,
         checks: [CheckRound]? = nil, scan: JobScan? = nil, diff: JobDiff? = nil, context: String? = nil,
         stages: [String: StageTiming] = [:]) {
        self.activity = activity
        self.usage = usage
        self.windowShare = windowShare
        self.estimate = estimate
        self.checks = checks
        self.scan = scan
        self.diff = diff
        self.context = context
        self.stages = stages
    }

    private enum Keys: String, CodingKey { case activity, usage, windowShare, estimate, checks, scan, diff, context, pipeline }

    private struct Pipeline: Decodable {
        struct Stage: Decodable {
            var id: String
            var started: Date?
            var finished: Date?
            var waited: Double?
            var estimate: Span?
        }
        var stages: [Stage]
    }

    /// From the job's own JSON; a part that can't be read is left out, never failing the rest.
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        activity = try? keys.decodeIfPresent(JobActivity.self, forKey: .activity)
        usage = try? keys.decodeIfPresent(JobUsage.self, forKey: .usage)
        windowShare = try? keys.decodeIfPresent(WindowShare.self, forKey: .windowShare)
        estimate = try? keys.decodeIfPresent(JobEstimate.self, forKey: .estimate)
        checks = try? keys.decodeIfPresent([CheckRound].self, forKey: .checks)
        scan = try? keys.decodeIfPresent(JobScan.self, forKey: .scan)
        diff = try? keys.decodeIfPresent(JobDiff.self, forKey: .diff)
        context = try? keys.decodeIfPresent(String.self, forKey: .context)
        let pipeline = try? keys.decodeIfPresent(Pipeline.self, forKey: .pipeline)
        for stage in pipeline?.stages ?? [] {
            let timing = StageTiming(started: stage.started, finished: stage.finished, waited: stage.waited, estimate: stage.estimate)
            if timing != StageTiming() { stages[stage.id] = timing }
        }
    }

    /// The seconds the job waited on you, which its clock doesn't count.
    var waited: Double { stages.values.compactMap(\.waited).reduce(0, +) }
}

/// One entry of a job's session (`GET /v1/jobs/{id}/transcript`, #755, #784): a round's start, the
/// agent's words (in full once obid serves them, growing as `append` events come), its thinking,
/// what you said, its to-do list, or a tool call, as the agent sent them. Values from the vault
/// arrive masked as `[vault: NAME]`.
nonisolated struct TranscriptEntry: Codable, Equatable, Identifiable, Sendable {
    /// One item of its to-do list.
    struct Todo: Codable, Equatable, Sendable {
        var text: String
        /// "pending", "running" or "done".
        var state: String?

        init(text: String, state: String? = nil) {
            self.text = text
            self.state = state
        }

        /// `state` read on its own: one that can't be read is nil, never the item.
        init(from decoder: any Decoder) throws {
            let keys = try decoder.container(keyedBy: CodingKeys.self)
            text = try keys.decode(String.self, forKey: .text)
            state = try? keys.decodeIfPresent(String.self, forKey: .state)
        }
    }

    var n: Int
    var at: Date?
    /// "start", "said", "thought", "you", "plan" or "tool"; a newer obid's other kinds show as their summary.
    var kind: String
    var tool: String?
    var summary: String?
    /// The whole text of what the agent said or thought (#784); `summary` is at most 300 characters.
    var text: String?
    /// "running", then "done", "failed" or "declined".
    var state: String?
    var seconds: Double?
    var exit: Int?
    var added: Int?
    var removed: Int?
    var todos: [Todo]?
    /// What its call counts as: read, search, edit, command, test, tetrix, web, mcp or other.
    var activity: String?
    var file: String?
    /// How a permission it asked for was answered ("asked" entries).
    var answer: String?

    var id: Int { n }

    /// Its words: the whole text when obid serves it, else its summary.
    var words: String { text ?? summary ?? "" }
    var running: Bool { state == "running" }
    var failed: Bool { state == "failed" || state == "declined" }

    /// A tool row's words as Sangam's row sets them: the verb, then what it's on in code ("Reading"
    /// `Engine/Inbox.swift`, "Running" `cargo test`): the file when obid names one, a command's
    /// words after its verb; else all of its words, plain.
    var verbAndTarget: (verb: String, target: String?) {
        let words = summary ?? ""
        if let file, !file.isEmpty {
            for target in [file, (file as NSString).lastPathComponent] where words.count > target.count && words.hasSuffix(target) {
                return (String(words.dropLast(target.count)).trimmingCharacters(in: .whitespaces), file)
            }
        }
        if Filter.of(self) == .commands, let space = words.firstIndex(of: " ") {
            return (String(words[..<space]), String(words[words.index(after: space)...]))
        }
        return (words, nil)
    }

    /// What the tool row says at its right: how a command ended, what an edit changed.
    var meta: String? {
        if let exit, exit != 0 { return "exit \(exit)" }
        if state == "declined" { return "declined" }
        if added != nil || removed != nil { return "+\(added ?? 0) −\(removed ?? 0)" }
        return nil
    }

    /// The filters over the session (Sangam's #786), each with what it takes. A round's start shows
    /// under every one, and isn't counted.
    enum Filter: String, CaseIterable, Sendable {
        case all = "All", said = "Said", commands = "Commands", edits = "Edits", reads = "Reads", tetrix = "Tetrix", web = "Web"

        func takes(_ entry: TranscriptEntry) -> Bool {
            switch self {
            case .all: return entry.kind != "start"
            case .said: return ["said", "thought", "you"].contains(entry.kind)
            default: return entry.kind == "tool" && Self.of(entry) == self
            }
        }

        /// A call's filter, by obid's `activity` when it sends one, else by the tool's name.
        static func of(_ entry: TranscriptEntry) -> Filter? {
            switch entry.activity {
            case "command", "test": return .commands
            case "edit": return .edits
            case "read", "search": return .reads
            case "tetrix": return .tetrix
            case "web": return .web
            case .some: return nil
            case nil: break
            }
            let tool = (entry.tool ?? "").lowercased()
            if tool.contains("tetrix") { return .tetrix }
            if ["bash", "shell", "command"].contains(tool) { return .commands }
            if ["edit", "write", "multiedit", "notebookedit", "apply_patch"].contains(tool) { return .edits }
            if ["read", "grep", "glob", "search", "ls"].contains(tool) { return .reads }
            if tool.hasPrefix("web") { return .web }
            return nil
        }
    }
}

extension TranscriptEntry {
    /// `n` and `kind` must read; every other field is read on its own, and one that can't be read
    /// (a newer obid's shape, a wrong type) is nil, never the entry. A to-do item that can't be read
    /// is left out of the list.
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys) -> T? { (try? keys.decodeIfPresent(T.self, forKey: key)) ?? nil }
        self.init(n: try keys.decode(Int.self, forKey: .n), at: field(.at), kind: try keys.decode(String.self, forKey: .kind),
                  tool: field(.tool), summary: field(.summary), text: field(.text), state: field(.state), seconds: field(.seconds),
                  exit: field(.exit), added: field(.added), removed: field(.removed),
                  todos: (field(.todos) as [Lenient<Todo>]?)?.compactMap(\.value), activity: field(.activity), file: field(.file),
                  answer: field(.answer))
    }
}

/// What the event stream says about a job's session (#755, #784): an entry that came or changed,
/// or more words for the one the agent is writing (`append`).
nonisolated struct TranscriptEvent: Decodable, Equatable, Sendable {
    var job: String
    var entry: TranscriptEntry?
    var n: Int?
    var append: String?

    private enum Keys: String, CodingKey { case job, entry, n, append }

    init(job: String, entry: TranscriptEntry? = nil, n: Int? = nil, append: String? = nil) {
        self.job = job
        self.entry = entry
        self.n = n
        self.append = append
    }

    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        job = try keys.decode(String.self, forKey: .job)
        entry = (try? keys.decodeIfPresent(Lenient<TranscriptEntry>.self, forKey: .entry))?.value
        n = try? keys.decodeIfPresent(Int.self, forKey: .n)
        append = try? keys.decodeIfPresent(String.self, forKey: .append)
    }
}

/// A JSON value as it came: a tool call's input is whatever the tool takes.
nonisolated enum JSONValue: Decodable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    /// As one line: a string as it is, a whole number without its decimals, the rest as JSON.
    var text: String {
        switch self {
        case .string(let string): return string
        case .number(let number): return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .bool(let bool): return bool ? "true" : "false"
        case .null: return "null"
        case .array(let items): return "[" + items.map(\.text).joined(separator: ", ") + "]"
        case .object(let fields): return "{" + fields.keys.sorted().map { "\($0): \(fields[$0]!.text)" }.joined(separator: ", ") + "}"
        }
    }
}

/// An entry's detail (`GET /v1/jobs/{id}/transcript/{n}`, #784), read only when its row opens:
/// what the call was given, the end of what it printed (the last 200 lines or 64 KB, masked line
/// by line), and an edit's diff.
nonisolated struct TranscriptDetail: Decodable, Equatable, Sendable {
    struct Output: Decodable, Equatable, Sendable {
        var text: String?
        /// How many lines it printed in all.
        var lines: Int?
        var truncated: Bool?
        var exit: Int?
    }

    struct FileDiff: Codable, Equatable, Sendable {
        var path: String?
        var patch: String
    }

    var input: [String: JSONValue]?
    var output: Output?
    var diff: [FileDiff]?

    private enum Keys: String, CodingKey { case input, output, diff }

    init(input: [String: JSONValue]? = nil, output: Output? = nil, diff: [FileDiff]? = nil) {
        self.input = input
        self.output = output
        self.diff = diff
    }

    /// A part that can't be read is left out, never the rest.
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: Keys.self)
        input = try? keys.decodeIfPresent([String: JSONValue].self, forKey: .input)
        output = try? keys.decodeIfPresent(Output.self, forKey: .output)
        // A file that can't be read is left out, never the rest of the diff.
        diff = (try? keys.decodeIfPresent([Lenient<FileDiff>].self, forKey: .diff))?.compactMap(\.value)
    }

    /// From the answer: the entry, with its `detail`.
    static func read(_ data: Data) throws -> TranscriptDetail {
        struct Answer: Decodable {
            var detail: TranscriptDetail?
            private enum Keys: String, CodingKey { case detail }
            init(from decoder: any Decoder) throws {
                detail = try? decoder.container(keyedBy: Keys.self).decodeIfPresent(TranscriptDetail.self, forKey: .detail)
            }
        }
        return try Runner.decoder.decode(Answer.self, from: data).detail ?? TranscriptDetail()
    }

    /// The command a call ran, or nil.
    var command: String? {
        if case .string(let command) = input?["command"] ?? input?["cmd"] { return command }
        return nil
    }

    /// What the call was given, as lines, the command and the edit's own text left out (they show
    /// as the command and the diff).
    var given: [String] {
        let skipped: Set<String> = ["command", "cmd", "content", "old_string", "new_string", "new_source", "edits", "patch"]
        return (input ?? [:]).keys.sorted().filter { !skipped.contains($0) }.map { "\($0): \(input![$0]!.text)" }
    }
}

/// One answer of `GET /v1/jobs/{id}/transcript` (#755): its lines, and `next`, the `n` to ask
/// `after` for the rest, or nil when there's no more.
nonisolated struct TranscriptPage: Equatable, Sendable {
    var entries: [TranscriptEntry]
    var next: Int? = nil

    /// From `{next, entries: […]}`, or a bare list (no more pages); a line that can't be read is skipped.
    static func read(_ data: Data) throws -> TranscriptPage {
        struct Wrapped: Decodable { var next: Int?; var entries: [Lenient<TranscriptEntry>] }
        if let lines = try? Runner.decoder.decode([Lenient<TranscriptEntry>].self, from: data) {
            return TranscriptPage(entries: lines.compactMap(\.value))
        }
        let page = try Runner.decoder.decode(Wrapped.self, from: data)
        return TranscriptPage(entries: page.entries.compactMap(\.value), next: page.next)
    }
}

/// How the page says times, counts and money.
nonisolated enum JobPageText {
    /// A call's time as the session says it (Sangam's #786): "0.2s", "41s", "3m 12s".
    static func took(_ seconds: Double) -> String {
        let seconds = max(0, seconds)
        if seconds < 10 { return "\((seconds * 10).rounded() / 10)s".replacingOccurrences(of: ".0s", with: "s") }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m \(whole % 60)s"
    }

    /// "18s", "3m 19s" under 5 minutes, "11m", "1h 5m": a stage's or a command's time.
    static func seconds(_ value: Double) -> String {
        let total = max(0, Int(value.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 300 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
        return minutes(value)
    }

    /// "40s", then to the nearest minute: "4m", "1h 5m": how long the whole job has gone.
    static func minutes(_ value: Double) -> String {
        let total = max(0, Int(value.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = (total + 30) / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// A range, never one number: "12–20m", "30–50s", "1–2h"; one end when both round alike.
    static func range(_ low: Double, _ high: Double) -> String {
        let low = max(0, low), high = max(low, high)
        if high < 60 { return pair(Int(low.rounded()), Int(high.rounded()), "s") }
        if high < 5400 { return pair(max(1, Int((low / 60).rounded())), max(1, Int((high / 60).rounded(.up))), "m") }
        return pair(max(1, Int((low / 3600).rounded(.down))), Int((high / 3600).rounded(.up)), "h")
    }

    private static func pair(_ low: Int, _ high: Int, _ unit: String) -> String {
        low >= high ? "\(high)\(unit)" : "\(low)–\(high)\(unit)"
    }

    /// "1.9M", "214k", "950".
    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return "\(Int((Double(count) / 1000).rounded()))k"
        default:
            let millions = Double(count) / 1_000_000
            return millions < 10 ? String(format: "%.1fM", millions) : "\(Int(millions.rounded()))M"
        }
    }

    /// "$2.70".
    static func dollars(_ amount: Double) -> String { String(format: "$%.2f", amount) }

    /// "11%", "<1%" for a share under one point.
    static func percent(_ points: Double) -> String {
        points > 0 && points < 1 ? "<1%" : "\(Int(points.rounded()))%"
    }
}

/// The job's clock on the page: how long it has worked (time waiting on you left out), and what the
/// time track and the Timeline's side note say about the finish.
nonisolated struct JobClock: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case working, planning, paused, ended, done }

    var phase: Phase
    /// Seconds worked so far, or in all once it ended.
    var elapsed: Double
    var estimate: JobEstimate?

    /// What's left of the estimate, or nil when there's none or it's run past it.
    var remaining: Span? {
        guard let estimate, estimate.high > elapsed else { return nil }
        return Span(low: max(0, estimate.low - elapsed), high: estimate.high - elapsed)
    }

    /// Where the track's marks sit, 0...1: what's gone, and the finish as a range.
    struct Track: Equatable, Sendable {
        var done: Double
        var rangeStart: Double
        var rangeEnd: Double
        var paused: Bool
        /// Too early to place the finish: the range spans the whole track, faint.
        var unknown: Bool
    }

    /// Nil once it ended, or with no estimate: then no track at all.
    var track: Track? {
        guard let estimate, phase != .ended, phase != .done else { return nil }
        let scale = max(estimate.high / 0.8, elapsed / 0.9, 1)
        return Track(done: min(1, elapsed / scale), rangeStart: min(1, estimate.low / scale), rangeEnd: min(1, estimate.high / scale),
                     paused: phase == .paused, unknown: phase == .planning)
    }

    /// The Timeline's side note: "9m in · done in about 3–7m"; shorter on the iPhone.
    func aside(compact: Bool) -> String? {
        let worked = JobPageText.minutes(elapsed)
        let usual = estimate.map { JobPageText.range($0.low, $0.high) }
        switch phase {
        case .done:
            return nil
        case .ended:
            if compact { return "Ran \(worked)" }
            return usual.map { "Ran \(worked) · jobs like this: \($0)" } ?? "Ran \(worked)"
        case .planning:
            guard let usual else { return compact ? nil : "\(worked) in" }
            return compact ? "Jobs like this: \(usual)" : "\(worked) in · jobs like this take \(usual)"
        case .paused:
            let then = remaining.map { JobPageText.range($0.low, $0.high) }
            if compact { return then.map { "Paused · then \($0)" } ?? "Paused" }
            return "\(worked) in · paused" + (then.map { " · then about \($0)" } ?? "")
        case .working:
            if let left = remaining {
                let range = JobPageText.range(left.low, left.high)
                return compact ? "Done in about \(range)" : "\(worked) in · done in about \(range)"
            }
            if let usual { return compact ? "Past the usual \(usual)" : "\(worked) in · past the usual \(usual)" }
            return compact ? nil : "\(worked) in"
        }
    }

    /// "Took 19m · estimated 12–20m" once done; "Took 19m" with no estimate.
    var took: String {
        let given = estimate.map { $0.firstGiven ?? Span(low: $0.low, high: $0.high) }
        return "Took \(JobPageText.minutes(elapsed))" + (given.map { " · estimated \(JobPageText.range($0.low, $0.high))" } ?? "")
    }
}

extension CheckStep {
    /// What it came to: "passed", "791 passed, 2 failed", "412 of 793" while it runs; nil before it ran.
    var result: String? {
        if let tests, let passed = tests.passed {
            if running == true { return tests.total.map { "\(passed) of \($0)" } ?? "\(passed) passed" }
            if let failed = tests.failed, failed > 0 { return "\(passed) passed, \(failed) failed" }
            return "\(passed) passed"
        }
        if running == true { return nil }
        return passed.map { $0 ? "passed" : "failed" }
    }

    /// How far its tests have got while it runs, 0...1, or nil.
    var progress: Double? {
        guard running == true, let passed = tests?.passed, let total = tests?.total, total > 0 else { return nil }
        return min(1, Double(passed) / Double(total))
    }
}
