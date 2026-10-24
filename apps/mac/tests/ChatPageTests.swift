import Foundation
import Testing
@testable import Oby

/// The conversation in Sangam's design (#270, apps/mac/app/App/ConversationPage.swift): runs and
/// their times, what Oby's words set apart, which card a job gets under the answer that started it,
/// what a decision's kind says, where typed words go, and the usage gauge's dot.
struct ChatPageTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    func turn(_ id: String, _ who: Turn.Who, at minutes: Double) -> Turn {
        Turn(id: id, date: now + minutes * 60, who: who, text: id)
    }

    /// One side after another is a run; the other side, or an hour's quiet, starts a new one. The
    /// time goes under the last of each run.
    @Test func messagesRunTogetherWithTheTimeUnderTheLast() {
        let rows = ChatRuns.rows([turn("a", .user, at: 0), turn("b", .user, at: 1), turn("c", .oby, at: 2),
                                  turn("d", .oby, at: 3), turn("e", .oby, at: 70)])
        #expect(rows.map(\.continues) == [false, true, false, true, false])
        #expect(rows.map(\.endsRun) == [false, true, false, true, true])
        #expect(ChatRuns.rows([]).isEmpty)
    }

    /// Today, the clock; this week, the day and the clock; before that, the date too.
    @Test func aMessagesTimeSaysTheDayOnlyWhenItIsntToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let today = ChatRuns.clock(now - 60, now: now, calendar: calendar, locale: locale)
        let week = ChatRuns.clock(now - 3 * 86_400, now: now, calendar: calendar, locale: locale)
        let older = ChatRuns.clock(now - 40 * 86_400, now: now, calendar: calendar, locale: locale)
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        #expect(!days.contains { today.contains($0) }, "today's time names a day: \(today)")
        #expect(days.contains { week.hasPrefix($0) }, "this week's time names no day: \(week)")
        #expect(["Sep", "Aug", "Oct"].contains { older.hasPrefix($0) } && older.contains(","), "an older time has no date: \(older)")
    }

    /// Links and references in blue, paths and `code` in coral monospace, the rest plain.
    @Test func oBysWordsSetApartLinksReferencesPathsAndCode() {
        let runs = SaidTokens.runs("See #412 and `swift test` in apps/mac/app, on https://github.com/obi-ai-bot/obi.")
        #expect(runs.compactMap { $0.kind == nil ? nil : $0 } == [
            SaidTokens.Run(text: "#412", kind: .ref), SaidTokens.Run(text: "`swift test`", kind: .code),
            SaidTokens.Run(text: "apps/mac/app", kind: .path), SaidTokens.Run(text: "https://github.com/obi-ai-bot/obi", kind: .url),
        ])
        #expect(runs.map(\.text).joined() == "See #412 and `swift test` in apps/mac/app, on https://github.com/obi-ai-bot/obi.")
        #expect(SaidTokens.runs("Nothing special here.") == [SaidTokens.Run(text: "Nothing special here.", kind: nil)])
        #expect(SaidTokens.runs("tetrix-ee#490").first == SaidTokens.Run(text: "tetrix-ee#490", kind: .ref))
        // What comes before a match still counts: "#13" glued to "#12" is no reference of its own.
        #expect(SaidTokens.runs("PR #12#13").filter { $0.kind == .ref }.map(\.text) == ["#12"])
        // A path doesn't take the sentence's full stop.
        #expect(SaidTokens.runs("See Engine/Desk.swift.").contains(SaidTokens.Run(text: "Engine/Desk.swift", kind: .path)))
        // A long reply is read in one pass per pattern, not one per match.
        let long = String(repeating: "M apps/mac/app/App/ChatWindow.swift and #412 in `code` ", count: 600)
        let start = Date.now
        #expect(SaidTokens.runs(long).count > 1800)
        #expect(Date.now.timeIntervalSince(start) < 1, "tokenizing 30 KB took \(Date.now.timeIntervalSince(start)) s")
    }

    func job(_ status: Job.Status, question: Bool = false) -> Job {
        var job = Job(id: "j", request: "r", agent: "claude", account: "a", repo: "deskree-inc/oby", branch: "b", base: "dev",
                      pr: nil, kind: .build, task: "t", created: now)
        job.status = status
        if question { job.question = Plan.Question(text: "Which?", options: []) }
        return job
    }

    /// Told something after it ended, a task gets a follow-up (Sangam's design, the owner's decision
    /// of 2026-10-18): its thread lists them oldest first, each with Oby's line as the design says it.
    @Test func aFinishedTaskShowsItsFollowUps() {
        var first = job(.running), second = job(.queued), other = job(.done)
        first.id = "f1"; first.followUpOf = "j"; first.created = now.addingTimeInterval(60)
        second.id = "f0"; second.followUpOf = "j"; second.created = now.addingTimeInterval(30)
        other.id = "x"
        #expect(ThreadTaskLine.followUps(of: "j", in: [first, other, second]).map(\.id) == ["f0", "f1"])
        #expect(ThreadTaskLine.followUp(first, account: "Deskree")
                == "This one’s finished, so I started a follow-up. Claude Code has it in oby on Deskree.")
        first.repo = "local"
        #expect(ThreadTaskLine.followUp(first, account: "") == "This one’s finished, so I started a follow-up. Claude Code has it on a.")
    }

    /// A job shows the moment its words start it, as Claude Code's tasks do: under those words
    /// (obid's `turn`) until Oby's answer lists it, then under the answer, never twice. A follow-up
    /// told from the task's page goes with its parent's card, Sangam's line over it; one the
    /// thread shows where it started doesn't, nor anything under a turn a job added as it ended.
    @Test func jobsShowAsTheyStartAndFollowUpsGoWithTheirParent() {
        let asked = Turn(id: "u", date: now, who: .user, text: "fix it")
        var fix = job(.running), told = job(.queued), started = job(.running), other = job(.running)
        fix.id = "fix"; told.id = "told"; told.followUpOf = "fix"
        started.id = "started"; started.followUpOf = "fix"
        other.id = "other"
        let turns: [String: String] = ["fix": "u", "started": "u2", "other": "elsewhere"]
        let startedBy = { (job: Job) in turns[job.id] }
        let all = [fix, told, started, other]
        // Under way: the card is under the words, and only theirs.
        #expect(ThreadTaskLine.cards(under: asked, in: [asked], jobs: all, startedBy: startedBy).map(\.id) == ["fix"])
        // Answered: it's on the answer, not under the words any more.
        let answer = Turn(id: "o", date: now + 5, who: .oby, text: "On it.", jobs: ["fix"])
        #expect(ThreadTaskLine.cards(under: asked, in: [asked, answer], jobs: all, startedBy: startedBy).isEmpty)
        #expect(ThreadTaskLine.cards(under: answer, in: [asked, answer], jobs: all, startedBy: startedBy).map(\.id) == ["fix"])
        // The follow-up told from the page goes with fix; the one words here started shows under them.
        let more = Turn(id: "u2", date: now + 60, who: .user, text: "and the docs")
        let thread = [asked, answer, more]
        let shown = ThreadTaskLine.shown(in: thread, jobs: all, startedBy: startedBy, ended: { _ in false })
        #expect(shown == ["fix", "started"])
        #expect(ThreadTaskLine.attached(to: fix, in: all, shown: shown).map(\.id) == ["told"])
        // Its own follow-ups come after it; a turn a job added as it ended doesn't count as shown.
        var again = job(.queued)
        again.id = "again"; again.followUpOf = "told"; again.created = now + 120
        let ended = Turn(id: "e", date: now + 90, who: .oby, text: "Fix is done.", jobs: ["told"])
        let later = all + [again]
        let shownLater = ThreadTaskLine.shown(in: thread + [ended], jobs: later, startedBy: startedBy, ended: { $0.id == "e" })
        #expect(ThreadTaskLine.attached(to: fix, in: later, shown: shownLater).map(\.id) == ["told", "again"])
        // A followUpOf loop ends: no job goes under itself.
        var loop = fix
        loop.followUpOf = "again"
        #expect(ThreadTaskLine.attached(to: loop, in: [loop, told, again], shown: []).map(\.id) == ["told", "again"])
    }

    /// A job's turn counts only in its own conversation: another conversation's job, whatever its
    /// turn, never shows under these words.
    @Test func aJobShowsOnlyInItsOwnConversation() {
        let started = job(.running)
        #expect(ThreadTaskLine.startedBy(turn: "u", in: "c1", showing: "c1") == "u")
        #expect(ThreadTaskLine.startedBy(turn: "u", in: "c2", showing: "c1") == nil)
        // A runner with one thread names none.
        #expect(ThreadTaskLine.startedBy(turn: "u", in: nil, showing: nil) == "u")
        let words = Turn(id: "u", date: now, who: .user, text: "fix it")
        let elsewhere = { (_: Job) in ThreadTaskLine.startedBy(turn: "u", in: "c2", showing: "c1") }
        #expect(ThreadTaskLine.cards(under: words, in: [words], jobs: [started], startedBy: elsewhere).isEmpty)
        #expect(ThreadTaskLine.shown(in: [words], jobs: [started], startedBy: elsewhere, ended: { _ in false }).isEmpty)
    }

    /// The card under an answer says where its task stands, then who has it where; never "new"
    /// in the thread, where you're already looking at it.
    @Test func eachJobStateGetsItsCard() {
        #expect(ThreadTaskLine.mark(job(.queued)) == .queued)
        #expect(ThreadTaskLine.mark(job(.running)) == .working)
        #expect(ThreadTaskLine.mark(job(.running, question: true)) == .needs)
        #expect(ThreadTaskLine.mark(job(.done)) == .done)
        #expect(ThreadTaskLine.meta(job: job(.running), mark: .working, account: "Deskree") == "Running · Claude Code · Deskree · oby")
        #expect(ThreadTaskLine.meta(job: job(.queued), mark: .queued, account: "") == "Queued · Claude Code · oby")
        #expect(ThreadTaskLine.status(.needs) == "Needs you" && ThreadTaskLine.status(.done) == "Done")
    }

    /// A decision's kind over its headline: orange for what waits on you, red for a failure.
    @Test func aDecisionSaysWhatKindItIs() {
        #expect(AskKind.label("question") == "Question" && AskKind.label("question", plan: true) == "Plan")
        #expect(AskKind.label("permission") == "Permission" && AskKind.label("limit") == "Out of usage")
        #expect(AskKind.label("failed") == "Failed" && AskKind.failed("failed") && AskKind.failed("merge"))
        #expect(!AskKind.failed("question") && !AskKind.failed("permission") && !AskKind.failed("review"))
        #expect(AskKind.label("agentQuestion") == "Question" && !AskKind.failed("agentQuestion"))
        // GitHub work obid offers to start is an offer, never a failure.
        #expect(AskKind.label("github") == "Start it?" && !AskKind.failed("github"))
    }

    /// Typed words answer the card that asked for them in words; else Oby's own question while it
    /// waits ("Or answer in your own words below"); else they go to Oby.
    @Test func typedWordsGoWhereTheyAnswer() {
        #expect(ChatSend.route(replying: true, questionWaits: true) == .reply)
        #expect(ChatSend.route(replying: false, questionWaits: true) == .answer)
        #expect(ChatSend.route(replying: false, questionWaits: false) == .oby)
    }

    /// The gauge's dot: yellow past 80% of a week, red past 90%, none below or without numbers.
    @Test func theUsageGaugeWarnsPast80And90() {
        #expect(UsageDot.of(weeks: [0.5, nil]) == UsageDot.none)
        #expect(UsageDot.of(weeks: [0.8]) == UsageDot.none)
        #expect(UsageDot.of(weeks: [0.81, 0.2]) == .high)
        #expect(UsageDot.of(weeks: [0.3, 0.91]) == .over)
        #expect(UsageDot.of(weeks: []) == UsageDot.none)
    }
}
