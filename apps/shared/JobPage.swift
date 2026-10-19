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

/// One line of the raw session (`GET /v1/jobs/{id}/transcript`): a tool call, what the agent
/// said, what you said, its plan, or its start, as the agent sent them.
nonisolated struct TranscriptEntry: Codable, Equatable, Identifiable, Sendable {
    var n: Int
    var at: Date?
    /// "tool", "said", "you", "plan" or "start".
    var kind: String
    var tool: String?
    var summary: String?
    var state: String?
    var seconds: Double?
    var exit: Int?
    var added: Int?
    var removed: Int?

    var id: Int { n }

    /// The lines in an answer, a list or `{entries: […]}`; a line that can't be read is skipped.
    static func list(_ data: Data) throws -> [TranscriptEntry] {
        struct Wrapped: Decodable { var entries: [Lenient<TranscriptEntry>] }
        if let lines = try? Runner.decoder.decode([Lenient<TranscriptEntry>].self, from: data) { return lines.compactMap(\.value) }
        return try Runner.decoder.decode(Wrapped.self, from: data).entries.compactMap(\.value)
    }

    /// Words rather than a tool: set in the reading font.
    var spoken: Bool { kind == "said" || kind == "you" }
    /// Its tag in the log's second column: the tool's name, or the kind.
    var tag: String { kind == "tool" ? (tool ?? "tool") : kind }

    /// The line itself, with what it changed or how it ended.
    var text: String {
        var parts = [summary ?? ""]
        if added != nil || removed != nil { parts.append("+\(added ?? 0) −\(removed ?? 0)") }
        if let exit { parts.append("exit \(exit)") }
        if let seconds { parts.append(JobPageText.seconds(seconds)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The tabs over the log: kinds a filter takes.
    enum Filter: String, CaseIterable, Sendable {
        case all = "All", said = "Said", reads = "Reads", edits = "Edits", commands = "Commands", tetrix = "Tetrix", web = "Web"

        func takes(_ entry: TranscriptEntry) -> Bool {
            let tool = (entry.tool ?? "").lowercased()
            switch self {
            case .all: return true
            case .said: return entry.spoken
            case .reads: return entry.kind == "tool" && ["read", "grep", "glob", "search", "ls"].contains(tool)
            case .edits: return entry.kind == "tool" && ["edit", "write", "multiedit", "notebookedit", "apply_patch"].contains(tool)
            case .commands: return entry.kind == "tool" && ["bash", "shell", "command"].contains(tool)
            case .tetrix: return tool.contains("tetrix")
            case .web: return entry.kind == "tool" && tool.hasPrefix("web")
            }
        }
    }
}

/// How the page says times, counts and money.
nonisolated enum JobPageText {
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
