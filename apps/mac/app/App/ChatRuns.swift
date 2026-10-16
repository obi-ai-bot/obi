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

    /// A message's time: the clock today, else the day and the clock.
    static func clock(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).weekday(.abbreviated)) + " " + time
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

    /// The text cut into runs, plain or recognised, in order.
    static func runs(_ text: String) -> [Run] {
        var out: [Run] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let string = String(rest)
            let range = NSRange(string.startIndex..., in: string)
            var best: (Kind, NSRange)?
            for (kind, regex) in compiled {
                if let match = regex.firstMatch(in: string, range: range), best.map({ match.range.location < $0.1.location }) ?? true {
                    best = (kind, match.range)
                }
            }
            guard let (kind, found) = best, let at = Range(found, in: string) else {
                out.append(Run(text: string, kind: nil))
                break
            }
            if at.lowerBound > string.startIndex { out.append(Run(text: String(string[..<at.lowerBound]), kind: nil)) }
            out.append(Run(text: String(string[at]), kind: kind))
            rest = Substring(string[at.upperBound...])
        }
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
        case "start": "Start it?"
        case "merge": "Not merged"
        case "audit": "Issue audit"
        case "failure": "Oby failure"
        default: "Failed"
        }
    }

    static func failed(_ kind: String) -> Bool { !["question", "permission", "review", "limit", "start", "audit"].contains(kind) }
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

    static func meta(job: Job, mark: WorkMark, account: String) -> String {
        let repo = job.repo.split(separator: "/").last.map(String.init)
        return ([status(mark), job.agentName, account] + [repo].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: " · ")
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
}
