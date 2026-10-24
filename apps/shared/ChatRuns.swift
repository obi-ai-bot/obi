import Foundation

/// How Sangam's conversation (ChatView.tsx) lays out a thread: one side after another in runs,
/// a long quiet starting a new run with its own time, Oby's face over the first of its run and
/// the time under the last.
nonisolated enum ChatRuns {
    /// A quiet this long between two messages starts a new run.
    static let gap: TimeInterval = 60 * 60

    struct Row: Equatable {
        var turn: Turn
        /// It carries on the run before it: the same side, soon after.
        var continues: Bool
        /// It ends its run: the time goes under it.
        var endsRun: Bool
    }

    static func rows(_ turns: [Turn]) -> [Row] {
        turns.indices.map { index in
            let turn = turns[index]
            let before = index > 0 ? turns[index - 1] : nil
            let after = index + 1 < turns.count ? turns[index + 1] : nil
            return Row(turn: turn, continues: before.map { same($0, turn) } ?? false, endsRun: after.map { !same(turn, $0) } ?? true)
        }
    }

    private static func same(_ first: Turn, _ next: Turn) -> Bool {
        first.who == next.who && next.date.timeIntervalSince(first.date) < gap
    }

    /// A message's time: the clock today, the day and the clock this week, else the date too.
    static func clock(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if abs(now.timeIntervalSince(date)) < 6 * 86_400 {
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).weekday(.abbreviated)) + " " + time
        }
        return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day()) + ", " + time
    }
}

/// What Oby's words set apart as you read them (Sangam's textTokens.ts): links and references
/// (#412, tetrix-ee#490) in blue, paths, repos and `code` in coral monospace.
nonisolated enum SaidTokens {
    enum Kind: Equatable { case url, code, ref, path }

    struct Run: Equatable {
        var text: String
        var kind: Kind?
    }

    // In order: where two start at the same place, the first wins.
    private static let patterns: [(Kind, String)] = [
        (.url, #"\bhttps?://[^\s<>"'`]*[^\s<>"'`.,;:!?)\]}]"#),
        (.code, #"`[^`\n]+`"#),
        (.ref, #"(?<![\w#])(?:[\w.-]+/)?(?:[\w.-]+)?#\d+(?!\w)"#),
        (.path, #"(?<![\w.:/@-])(?:~/|\.{1,2}/|/)?(?:[\w@.-]+/)+[\w@.-]+"#),
    ]
    private static let compiled = patterns.compactMap { kind, pattern in (try? NSRegularExpression(pattern: pattern)).map { (kind, $0) } }


    /// What's recognised in `text`, in order: each pattern runs once over the whole text, and where
    /// two overlap the one starting first wins (the earlier pattern, at the same place).
    static func matches(_ text: String) -> [(range: Range<String.Index>, kind: Kind)] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [(range: NSRange, order: Int, kind: Kind)] = []
        for (order, (kind, regex)) in compiled.enumerated() {
            for match in regex.matches(in: text, range: whole) {
                var range = match.range
                // A path doesn't take the sentence's full stop with it.
                if kind == .path, let end = Range(range, in: text), text[end].hasSuffix(".") { range.length -= 1 }
                found.append((range, order, kind))
            }
        }
        found.sort { ($0.range.location, $0.order) < ($1.range.location, $1.order) }
        var out: [(range: Range<String.Index>, kind: Kind)] = []
        var end = 0
        for match in found where match.range.location >= end && match.range.length > 0 {
            guard let range = Range(match.range, in: text) else { continue }
            out.append((range, match.kind))
            end = match.range.location + match.range.length
        }
        return out
    }

    /// The text cut into runs, plain or recognised, in order.
    static func runs(_ text: String) -> [Run] {
        var out: [Run] = []
        var at = text.startIndex
        for match in matches(text) {
            if at < match.range.lowerBound { out.append(Run(text: String(text[at..<match.range.lowerBound]), kind: nil)) }
            out.append(Run(text: String(text[match.range]), kind: match.kind))
            at = match.range.upperBound
        }
        if at < text.endIndex { out.append(Run(text: String(text[at...]), kind: nil)) }
        return out
    }
}

/// A decision's kind, over its headline (Sangam's ASK_LABEL), and whether it's a failure (red).
nonisolated enum AskKind {
    static func label(_ kind: String, plan: Bool = false) -> String {
        switch kind {
        case "question": plan ? "Plan" : "Question"
        case "permission": "Permission"
        case "review": "Out of reviews"
        case "limit": "Out of usage"
        // obid's offer to start on GitHub work (a review requested, an issue assigned): Sangam's
        // label for a task waiting to start.
        case "start", "github": "Start it?"
        case "merge": "Not merged"
        case "audit": "Issue audit"
        case "failure": "Oby failure"
        case RunnerConfirm.kind: "Confirm it?"
        default: "Failed"
        }
    }

    static func failed(_ kind: String) -> Bool { !["question", "permission", "review", "limit", "start", "github", "audit", RunnerConfirm.kind].contains(kind) }
}

/// A task's card under the answer that started it (Sangam's ThreadTask): where it stands, then
/// its agent, account and repository.
nonisolated enum ThreadTaskLine {
    static func status(_ mark: WorkMark) -> String {
        switch mark {
        case .queued: "Queued"
        case .working: "Running"
        case .needs: "Needs you"
        case .done: "Done"
        case .new: "New"
        }
    }

    /// `on`: whose Mac it runs on, when not this one ("Wellington", #808).
    static func meta(job: Job, mark: WorkMark, account: String, on: String? = nil) -> String {
        let repo = job.repo.split(separator: "/").last.map(String.init)
        let place = on.map { "on \($0)’s Mac" }
        return ([status(mark), job.agentName, account] + [place, repo].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What Oby says under the words that started a follow-up of a finished task (Sangam's relay):
    /// "This one’s finished, so I started a follow-up. Claude Code has it in oby on Deskree."
    static func followUp(_ next: Job, account: String) -> String {
        let repo = next.repo.split(separator: "/").last.map { next.repo.contains("/") ? " in \($0)" : "" } ?? ""
        return "This one’s finished, so I started a follow-up. \(next.agentName) has it\(repo) on \(account.isEmpty ? next.account : account)."
    }

    /// The follow-ups of the task `id`, oldest first: its thread shows each after the words that
    /// started it.
    static func followUps(of id: String, in jobs: [Job]) -> [Job] {
        jobs.filter { $0.followUpOf == id }.sorted { $0.created < $1.created }
    }

    /// The user's turn that started a job (obid's `turn`), when the job is in the conversation on
    /// screen (`conversation` is the job's, `showing` the screen's); another conversation's job
    /// never counts, whatever its turn.
    static func startedBy(turn: String?, in conversation: String?, showing: String?) -> String? {
        conversation == showing ? turn : nil
    }

    /// The jobs whose cards go under `turn`: those it lists, then, under the user's words, the
    /// jobs those words started (`startedBy`) that no turn of the thread lists yet,
    /// oldest first: a card shows the moment its job starts, not when Oby's answer is in.
    static func cards(under turn: Turn, in thread: [Turn], jobs: [Job], startedBy: (Job) -> String?) -> [Job] {
        let listed = ConversationModel.jobs(of: turn, among: jobs)
        guard turn.who == .user else { return listed }
        let answered = Set(thread.flatMap { $0.jobs ?? [] })
        return listed + jobs.filter { startedBy($0) == turn.id && !answered.contains($0.id) }.sorted { $0.created < $1.created }
    }

    /// The jobs the thread shows where they started: on Oby's answers (not the turns a job adds
    /// when it ends, `ended`), and under the words that started them.
    static func shown(in thread: [Turn], jobs: [Job], startedBy: (Job) -> String?, ended: (Turn) -> Bool) -> Set<String> {
        let words = Set(thread.filter { $0.who == .user }.map(\.id))
        return Set(thread.filter { !ended($0) }.flatMap { $0.jobs ?? [] })
            .union(jobs.filter { startedBy($0).map(words.contains) ?? false }.map(\.id))
    }

    /// The follow-ups that go with `job`'s card, oldest first, each followed by its own: those the
    /// thread doesn't show where they started (`shown`), like one told from the task's page. Each
    /// goes under Sangam's line (`followUp`), as on the task's page. A job is never under itself
    /// (`seen`), so a `followUpOf` loop ends.
    static func attached(to job: Job, in jobs: [Job], shown: Set<String>, seen: Set<String> = []) -> [Job] {
        let seen = seen.union([job.id])
        return followUps(of: job.id, in: jobs).filter { !shown.contains($0.id) && !seen.contains($0.id) }
            .flatMap { [$0] + attached(to: $0, in: jobs, shown: shown, seen: seen) }
    }

    /// A job's mark in the thread, as in the side panel but never "new": you're looking at it.
    static func mark(_ job: Job) -> WorkMark {
        if job.needsYou || job.waitsForAnswer || job.waitsForPermission { return .needs }
        if job.isActive { return job.status == .queued ? .queued : .working }
        return .done
    }
}

/// The message box's usage gauge (Sangam's UsageGauge): a dot while an account is past 80% of
/// its week (yellow) or past 90% (red).
nonisolated enum UsageDot: Equatable {
    case none, high, over

    static func of(weeks: [Double?]) -> UsageDot {
        let most = weeks.compactMap { $0 }.max() ?? 0
        return most > 0.9 ? .over : most > 0.8 ? .high : .none
    }
}

/// Where words typed in the conversation go: the answer a card asked for in words, the answer to
/// Oby's own question while one waits, else a message for Oby.
nonisolated enum ChatSend: Equatable {
    case reply, answer, oby

    static func route(replying: Bool, questionWaits: Bool) -> ChatSend {
        replying ? .reply : questionWaits ? .answer : .oby
    }

    /// What an answer or a message to an agent may hold: one message, at most 2,000 characters.
    static let most = 2000
    /// The words the iPhone's task page says too.
    static let tooLong = "Keep your message under 2,000 characters."

    /// What sending typed words to an agent does: nothing while they're empty, says `tooLong`
    /// past `most` (the words stay in the box), else sends them trimmed.
    enum Typed: Equatable { case empty, tooLong, send(String) }

    static func typed(_ value: String) -> Typed {
        let words = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty { return .empty }
        return words.count > most ? .tooLong : .send(words)
    }
}

/// Oby's words coming in a word at a time (Sangam's stream.ts): one every 35 ms, each fading in
/// over 240 ms. For a whole answer, and for one still streaming in: `came` says when each word
/// came, in seconds from the start (a word missing from it came at the start).
nonisolated enum WordReveal {
    static let word: TimeInterval = 0.035
    static let fade: TimeInterval = 0.24

    /// Each word with the space after it, as stream.ts cuts them.
    static func words(_ text: String) -> [Substring] {
        text.matches(of: /\S+\s*/).map { text[$0.range] }
    }

    /// When each of `count` words starts in: 35 ms after the one before, or when it came if later.
    static func starts(_ count: Int, came: [TimeInterval] = []) -> [TimeInterval] {
        var last: TimeInterval = 0
        return (0..<count).map { index in
            last = max(index < came.count ? came[index] : 0, last + word)
            return last
        }
    }

    /// How long until the last word is in.
    static func duration(_ text: String, came: [TimeInterval] = []) -> TimeInterval {
        (starts(words(text).count, came: came).last ?? 0) + fade
    }

    /// What's in `after` seconds: the words so far, and how far in (0 to 1) the last of them are
    /// that are still fading, oldest first.
    static func shown(_ text: String, came: [TimeInterval] = [], after elapsed: TimeInterval) -> (text: String, fading: [Double]) {
        let words = words(text)
        let starts = starts(words.count, came: came)
        let count = starts.firstIndex { $0 > elapsed + 1e-9 } ?? words.count
        let fading = starts[..<count].map { min(1, (elapsed - $0) / fade) }.filter { $0 < 1 }
        return (words[..<count].joined(), fading)
    }
}
