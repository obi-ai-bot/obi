import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Something only the user can answer (docs/pipeline-cases.md, "Your inbox"): a job's question
/// (I.1), a job out of Oby's review rounds, a failure, a job whose accounts all hit their
/// limits, or a merge that stopped. Like email, it waits for the user, with no timeout: they answer it, mark it done, or
/// put it off until later. Its job waits; the others keep going.
nonisolated struct InboxItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The job's agent asked something (`Job.question`) and waits for the answer.
        case question
        /// Oby's review requested changes for the last time it may (`Job.reviewNeedsYou`).
        case review
        /// The job failed or was interrupted.
        case failed
        /// The job's account hit its usage limit, and no other account had room.
        case limit
        /// Oby's merge stopped: it couldn't merge, or the Mac check failed with no round left (`Job.mergeNeedsYou`).
        case merge
    }

    /// The job, what it needs and when it came: the same need never comes twice, even once it's done.
    var id: String
    var kind: Kind
    var job: String
    /// The job's title, as rows show it.
    var title: String
    /// The short line: the question, or what happened.
    var text: String
    /// The answers it offers, as buttons and number keys. Words of the user's own are taken too.
    var options: [String]
    var created: Date
    /// When it was answered or let go, or nil while it waits.
    var done: Date?
    /// Put off until then, or nil.
    var later: Date?
    /// What the user answered, or nil (done without an answer, or settled by itself).
    var answer: String?

    var isOpen: Bool { done == nil }

    /// Waiting for the user now: open, and not put off past `now`.
    func waiting(at now: Date = .now) -> Bool { done == nil && (later.map { $0 <= now } ?? true) }
}

nonisolated enum Inbox {
    /// What a failed job's item offers: run it again from where it was, or let it go.
    static let tryAgain = "Try again"
    static let dismiss = "Dismiss"
    /// What an item out of review rounds offers besides Dismiss.
    static let oneMoreRound = "One more round"
    /// What the agent hears for Try again.
    static let tryAgainMessage = "Try again, picking up where you left off. Finish with a short summary as asked."

    /// The item `job` calls for now, or nil when it needs nothing from the user. `limited`: it
    /// failed because no account had room.
    static func need(of job: Job, limited: Bool = false) -> InboxItem? {
        guard job.dismissed == nil else { return nil }
        func item(_ kind: InboxItem.Kind, _ id: String, _ text: String, _ options: [String]) -> InboxItem {
            InboxItem(id: "\(job.id)-\(id)", kind: kind, job: job.id, title: job.shortTitle, text: text, options: options, created: .now)
        }
        if let question = job.question, job.status != .stopped {
            // One per question: what the user said so far tells them apart.
            return item(.question, "question-\(job.notes?.count ?? 0)", question.text, question.options)
        }
        guard !job.isActive else { return nil }
        if job.reviewNeedsYou, let review = job.review {
            return item(.review, "review-\(review.job)", Review.stopLine, [oneMoreRound, dismiss])
        }
        if job.mergeNeedsYou, let check = job.macCheck {
            // A merge that failed can be tried again; each try that fails is its own item.
            if let error = job.mergeError { return item(.merge, "merge-\(check.id)-\(check.tries ?? 0)", error, [tryAgain, dismiss]) }
            return item(.merge, "merge-\(check.id)-stopped", check.failureLine + (job.checkStop.map { " " + $0 } ?? ""), [dismiss])
        }
        guard job.status == .failed || job.status == .interrupted else { return nil }
        let line = job.summary.split(separator: "\n").first.map(String.init) ?? job.status.rawValue.capitalized
        // Each failure its own: a retry that fails within the same second is another round.
        let ended = Int((job.finished ?? job.created).timeIntervalSince1970 * 1000)
        // Try again picks the job's session up: one that never started has none.
        let options = job.session == nil ? [dismiss] : [tryAgain, dismiss]
        // The same id either way: after a restart Oby no longer knows it was the limits, and the item stays.
        return item(limited ? .limit : .failed, "failed-\(job.currentRound)-\(ended)", line, options)
    }

    // MARK: Questions from agents

    /// What agents are told about asking (Prompts.agent).
    static let howToAsk = "If you need a decision only the user can make, don't guess and don't bury it in your summary: end your summary with a line `QUESTION: <one question>` and, when it has set answers, a last line `OPTIONS: <first> | <second>`. Oby puts it in the user's inbox and your job waits; their answer comes back to you as your next message."

    /// The question at the end of an agent's summary (`QUESTION: …`, then optionally `OPTIONS: a | b`),
    /// or nil. Only the summary's last lines count: a question quoted mid-report isn't one.
    static func question(in summary: String) -> Plan.Question? {
        let lines = summary.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Only the Markdown around the label goes (`**QUESTION:** …`, `` `QUESTION: …` ``): the
        // question and its options keep every character, like `*.swift`.
        func value(_ line: String, _ label: String) -> String? {
            let opening = line.prefix { "*_`".contains($0) }
            let rest = line.dropFirst(opening.count)
            guard rest.uppercased().hasPrefix(label + ":") else { return nil }
            var text = rest.dropFirst(label.count + 1).drop { "*_".contains($0) }.trimmingCharacters(in: .whitespaces)
            if !opening.isEmpty, text.hasSuffix(opening) { text = text.dropLast(opening.count).trimmingCharacters(in: .whitespaces) }
            return text
        }
        var options: [String] = []
        var last = lines.count - 1
        if last >= 0, let listed = value(lines[last], "OPTIONS") {
            options = listed.split(separator: "|").map { String($0.trimmingCharacters(in: .whitespaces).prefix(80)) }.filter { !$0.isEmpty }
            last -= 1
        }
        guard last >= 0, let text = value(lines[last], "QUESTION"), !text.isEmpty else { return nil }
        return Plan.Question(text: String(text.prefix(500)), options: Array(options.prefix(6)))
    }
}

/// The inbox, kept in `oby.sqlite` next to the jobs.
extension JobStore {
    func save(_ item: InboxItem) {
        guard let body = try? JSONEncoder().encode(item) else { return }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO inbox (id, created, body) VALUES (?, ?, ?)", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, item.id, -1, transient)
        sqlite3_bind_double(statement, 2, item.created.timeIntervalSince1970)
        sqlite3_bind_text(statement, 3, String(decoding: body, as: UTF8.self), -1, transient)
        if sqlite3_step(statement) != SQLITE_DONE { Logger.jobs.error("saving inbox item \(item.id, privacy: .public) failed") }
    }

    /// Every item, oldest first.
    // ponytail: done items are kept for good, as jobs are; prune them if the inbox ever grows large.
    func inbox() -> [InboxItem] {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT body FROM inbox ORDER BY created, rowid", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var items: [InboxItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0),
               let item = try? JSONDecoder().decode(InboxItem.self, from: Data(String(cString: text).utf8)) {
                items.append(item)
            }
        }
        return items
    }
}
