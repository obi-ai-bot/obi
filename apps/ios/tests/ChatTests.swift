import Foundation
import Testing
@testable import Oby

/// The Chat tab's thread (#11, apps/ios/app/Chat.swift and apps/shared/ConversationModel.swift): the runner's
/// conversation read in pages, grouped by day, the jobs its cards resolve to, new turns from the
/// runner's events, and the composer's send flow: what's sent, and the words shown until the
/// runner lists them.
@MainActor
struct ChatTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    func turn(_ n: Int, who: Turn.Who = .user, jobs: [String]? = nil, at: Date? = nil) -> Turn {
        Turn(id: "t\(n)", date: at ?? now.addingTimeInterval(Double(n - 1000) * 60), who: who, text: "turn \(n)", jobs: jobs)
    }

    /// A runner with `count` turns, a minute apart, paged as `GET /v1/conversation` pages them.
    final class FakeRunner: @unchecked Sendable {
        var turns: [Turn]
        var asked: [(before: String?, limit: Int)] = []
        var failing = false
        init(_ turns: [Turn]) { self.turns = turns }
        func page(_ before: String?, _ limit: Int) async throws -> [Turn] {
            asked.append((before, limit))
            if failing { throw RunnerError(message: "The runner answered 503.") }
            var end = turns.count
            if let before { end = turns.firstIndex { $0.id == before } ?? 0 }
            return Array(turns[max(0, end - limit)..<end])
        }
    }

    @Test func theThreadIsReadInPagesFromTheNewest() async throws {
        let runner = FakeRunner((0..<120).map { turn($0) })
        let model = ConversationModel(page: runner.page)
        await model.reload()
        #expect(model.runnerTurns.count == ConversationModel.pageSize && model.runnerTurns.first?.id == "t70" && model.runnerTurns.last?.id == "t119")
        #expect(model.hasOlder && model.problem == nil && !model.loading)
        #expect(runner.asked.first?.before == nil && runner.asked.first?.limit == 50)
        // Earlier: the page before the oldest shown, until the runner has no more.
        await model.loadOlder()
        #expect(model.runnerTurns.count == 100 && model.runnerTurns.first?.id == "t20" && model.hasOlder)
        #expect(runner.asked.last?.before == "t70")
        await model.loadOlder()
        #expect(model.runnerTurns.count == 120 && model.runnerTurns.first?.id == "t0" && !model.hasOlder)
        await model.loadOlder()
        #expect(runner.asked.count == 3)
        // A page that couldn't be read says why, and keeps what's loaded.
        runner.failing = true
        await model.reload()
        #expect(model.problem == "The runner answered 503." && model.runnerTurns.count == 120)
        // Another runner, or none: nothing holds.
        model.forget()
        #expect(model.runnerTurns.isEmpty && !model.hasOlder && model.problem == nil)
    }

    @Test func theThreadIsGroupedByDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: now).addingTimeInterval(9 * 3600)
        let yesterday = today.addingTimeInterval(-86_400)
        let earlier = today.addingTimeInterval(-3 * 86_400)
        let turns = [turn(1, at: earlier), turn(2, who: .oby, at: earlier + 60), turn(3, at: yesterday), turn(4, at: today), turn(5, who: .oby, at: today + 5)]
        let days = ConversationModel.days(turns.shuffled(), now: now, calendar: calendar)
        #expect(days.map(\.title).suffix(2) == ["Yesterday", "Today"])
        #expect(days.count == 3 && days[0].title != "Yesterday" && days[0].title != "Today")
        #expect(days.map { $0.turns.map(\.id) } == [["t1", "t2"], ["t3"], ["t4", "t5"]])
        #expect(days.map(\.start) == [earlier, yesterday, today].map { calendar.startOfDay(for: $0) })
        #expect(ConversationModel.days([], now: now, calendar: calendar).isEmpty)
    }

    @Test func aTurnsJobsResolveToCards() throws {
        func job(_ id: String, _ status: String, step: String = "") -> String {
            #"{"id": "\#(id)", "request": "Review oby PR #33", "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/review-33", "base": "dev", "pr": 33, "kind": "review", "task": "Review pull request #33", "status": "\#(status)", "step": "\#(step)", "summary": "", "session": null, "created": "2026-10-09T21:42:53Z", "started": null, "finished": null, "commits": null, "published": null}"#
        }
        let running = try Runner.decoder.decode(Job.self, from: Data(job("9f08fd10", "running", step: "Running pnpm test").utf8))
        let other = try Runner.decoder.decode(Job.self, from: Data(job("ab12cd34", "queued").utf8))
        let oby = turn(2, who: .oby, jobs: ["ab12cd34", "9f08fd10", "unknown1"])
        // In the turn's order; what the list doesn't have is left to fetch.
        #expect(ConversationModel.jobs(of: oby, among: [running, other]).map(\.id) == ["ab12cd34", "9f08fd10"])
        #expect(ConversationModel.missing(of: oby, among: [running, other]) == ["unknown1"])
        #expect(ConversationModel.jobs(of: turn(1), among: [running]).isEmpty)
        // The card's second line: tool, account and step, with nothing for what's empty.
        #expect(ChatThread.cardLine(running, account: "Deskree") == "Claude Code · Deskree · Running pnpm test")
        #expect(ChatThread.cardLine(other, account: "default") == "Claude Code · default")
    }

    /// The runner's turn as the API sends it, in a page and in the `turn` event the phone follows.
    @Test func newTurnsComeFromEvents() async throws {
        let wire = #"{"id":"7c1e2f30","who":"oby","text":"On it.","at":"2026-10-11T09:12:04Z","jobs":["9f08fd10"]}"#
        let read = try Runner.decoder.decode(RunnerTurn.self, from: Data(wire.utf8)).turn
        #expect(read.id == "7c1e2f30" && read.who == .oby && read.text == "On it." && read.jobs == ["9f08fd10"] && read.voice == nil)
        #expect(read.date == ISO8601DateFormatter().date(from: "2026-10-11T09:12:04Z"))
        let none = try Runner.decoder.decode(RunnerTurn.self, from: Data(#"{"id":"x","who":"user","text":"hi","at":"2026-10-11T09:12:04Z","jobs":[]}"#.utf8)).turn
        #expect(none.jobs == nil && none.who == .user)
        var parser = EventParser()
        for line in ["event: turn", "data: \(wire)"] { #expect(parser.feed(line) == nil) }
        #expect(parser.feed("") == .turn(read))

        // Applied: a new turn goes at the end, one said earlier takes its place by time, and the
        // same turn again (a job dispatched from it) replaces its own.
        let model = ConversationModel(page: FakeRunner((0..<4).map { turn($0) }).page)
        await model.reload()
        model.apply(turn(9, who: .oby))
        #expect(model.runnerTurns.map(\.id) == ["t0", "t1", "t2", "t3", "t9"])
        var between = turn(2, who: .oby, at: now.addingTimeInterval(-997.5 * 60))
        between.id = "t2b"
        model.apply(between)
        #expect(model.runnerTurns.map(\.id) == ["t0", "t1", "t2", "t2b", "t3", "t9"])
        model.apply(turn(9, who: .oby, jobs: ["9f08fd10"]))
        #expect(model.runnerTurns.count == 6 && model.runnerTurns.last?.jobs == ["9f08fd10"])
    }

    /// Send: the words go trimmed, nothing goes for a blank field, and what was said shows in the
    /// thread from the send until the runner lists it with Oby's answer.
    @Test func theComposerSendsAndEchoes() async throws {
        #expect(ChatThread.words("  Review PR 12 \n") == "Review PR 12")
        #expect(ChatThread.words(" \n ") == nil && ChatThread.words("") == nil)

        let model = ConversationModel(page: FakeRunner((0..<2).map { turn($0) }).page)
        await model.reload()
        let echo = Turn(date: now, who: .user, text: "Review PR 12", voice: true)
        // On its way: the thread shows it after the runner's turns, as "You, by voice".
        #expect(ChatThread.pending([echo], runner: model.runnerTurns) == [echo])
        #expect(model.thread(with: [echo]).map(\.id) == ["t0", "t1", echo.id])
        // The runner answered: its version of the words settles the echo, and the thread has one.
        let listed = Turn(id: "r1", date: now.addingTimeInterval(4), who: .user, text: "Review PR 12")
        model.apply(listed)
        model.apply(Turn(id: "r2", date: now.addingTimeInterval(5), who: .oby, text: "On it."))
        #expect(ChatThread.pending([echo], runner: model.runnerTurns).isEmpty)
        #expect(model.thread(with: ChatThread.pending([echo], runner: model.runnerTurns)).map(\.id) == ["t0", "t1", "r1", "r2"])
        // The same words said long before are another message: they don't settle a new echo.
        let again = Turn(date: now.addingTimeInterval(600), who: .user, text: "Review PR 12")
        #expect(ChatThread.pending([again], runner: model.runnerTurns) == [again])
        // Oby's words don't settle it either, and the clocks may differ by a little.
        let obys = Turn(date: now.addingTimeInterval(20), who: .user, text: "Fix the flake")
        model.apply(Turn(id: "r3", date: now.addingTimeInterval(30), who: .oby, text: "Fix the flake"))
        #expect(ChatThread.pending([obys], runner: model.runnerTurns) == [obys])
        model.apply(Turn(id: "r4", date: now.addingTimeInterval(20 - ChatThread.tolerance + 1), who: .user, text: "Fix the flake"))
        #expect(ChatThread.pending([obys], runner: model.runnerTurns).isEmpty)
        // Words whose request failed stay pending, with their place in the thread, until the
        // runner lists them after all (a timeout on words it did get).
        let failed = Turn(date: now.addingTimeInterval(900), who: .user, text: "Merge it")
        #expect(ChatThread.pending([failed], runner: model.runnerTurns) == [failed])
        #expect(model.thread(with: [failed]).last?.id == failed.id)
        model.apply(Turn(id: "r5", date: now.addingTimeInterval(930), who: .user, text: "Merge it"))
        #expect(ChatThread.pending([failed], runner: model.runnerTurns).isEmpty)
        // An answer to Oby's question shows as its option; obid lists it after the words and the
        // question, and that settles it too.
        let option = Turn(date: now.addingTimeInterval(1000), who: .user, text: "Staging")
        model.apply(Turn(id: "r6", date: now.addingTimeInterval(1001), who: .user,
                         text: "deploy it\n\n(Oby asked: Where? The user answered: Staging)"))
        #expect(ChatThread.pending([option], runner: model.runnerTurns).isEmpty)
        // obid's turns name their conversation and take the echo's id: only that one settles it,
        // so a second "yes" sent a moment after the first shows.
        let yes = Turn(date: now.addingTimeInterval(2000), who: .user, text: "yes")
        model.apply(Turn(id: "r7", date: now.addingTimeInterval(1999), who: .user, text: "yes", conversation: "c"))
        #expect(ChatThread.pending([yes], runner: model.runnerTurns) == [yes])
        model.apply(Turn(id: yes.id, date: now.addingTimeInterval(2001), who: .user, text: "yes", conversation: "c"))
        #expect(ChatThread.pending([yes], runner: model.runnerTurns).isEmpty)
    }

    /// The thread follows a new turn at its end, not a page of older ones above: what decides a
    /// scroll to the bottom is the newest turn's id, which a prepended page leaves alone.
    @Test func olderPagesDontMoveTheNewestTurn() async throws {
        let runner = FakeRunner((0..<80).map { turn($0) })
        let model = ConversationModel(page: runner.page)
        await model.reload()
        let newest = model.runnerTurns.last?.id
        let top = model.runnerTurns.first?.id
        await model.loadOlder()
        #expect(model.runnerTurns.last?.id == newest && model.runnerTurns.count == 80)
        // The turn that was at the top is still there to scroll back to.
        #expect(model.runnerTurns.contains { $0.id == top } && model.runnerTurns.first?.id == "t0")
        // A turn that changed (a job joined it) keeps its id too: no scroll either.
        model.apply(turn(79, who: .oby, jobs: ["9f08fd10"]))
        #expect(model.runnerTurns.last?.id == newest)
        // A new one at the end changes it.
        model.apply(turn(80, who: .oby))
        #expect(model.runnerTurns.last?.id == "t80")
    }
    /// Oby's words come in a word at a time (Sangam's stream.ts): one every 35 ms, each fading in
    /// over 240 ms, as it is now; the whole answer once the last word is in.
    @Test func obysWordsComeInAWordAtATime() {
        let text = "Done. Three files changed."
        #expect(WordReveal.shown(text, after: 0).text.isEmpty)
        let first = WordReveal.shown(text, after: 0.06)
        #expect(first.text == "Done. " && first.fading.count == 1 && abs(first.fading[0] - 0.025 / 0.24) < 0.001)
        let three = WordReveal.shown(text, after: 0.105)
        #expect(three.text == "Done. Three files " && three.fading.count == 3)
        // Each word fades in on its own: the newest is the faintest.
        #expect(three.fading == three.fading.sorted(by: >))
        let all = WordReveal.shown(text, after: WordReveal.duration(text))
        #expect(all.text == text && all.fading.isEmpty)
        #expect(abs(WordReveal.duration(text) - (4 * 0.035 + 0.24)) < 0.0001)
        // Streaming in: a word that came late starts in when it came, the next 35 ms after it.
        let came: [TimeInterval] = [0, 0, 1, 1]
        #expect(WordReveal.shown(text, came: came, after: 0.5).text == "Done. Three ")
        let late = WordReveal.shown(text, came: came, after: 1.12)
        #expect(late.text == text && late.fading.count == 2 && abs(late.fading[0] - 0.5) < 0.01)
        #expect(abs(WordReveal.duration(text, came: came) - (1.035 + 0.24)) < 0.0001)
    }

    /// Only an answer that comes while the thread is open comes in word by word: a turn event, or
    /// the page read right after it (a new conversation's first answer); never history read later.
    @Test func onlyAnswersThatJustCameAreRevealed() async throws {
        let clock = now.addingTimeInterval(2000)
        let old = (0..<3).map { turn($0, who: .oby) }
        let runner = FakeRunner(old)
        let model = ConversationModel(page: runner.page)
        model.time = { clock }
        await model.reload()
        #expect(model.arrived.isEmpty)
        // Its answer as a turn event: from now.
        let answer = Turn(id: "a1", date: clock.addingTimeInterval(-1), who: .oby, text: "On it.")
        model.apply(answer)
        #expect(model.arrived["a1"] == clock)
        // The same turn again (a job joined it) keeps when it came; yours never come word by word.
        model.time = { clock.addingTimeInterval(5) }
        model.apply(Turn(id: "a1", date: answer.date, who: .oby, text: "On it.", jobs: ["j1"]))
        model.apply(Turn(id: "u1", date: clock, who: .user, text: "Thanks"))
        #expect(model.arrived == ["a1": clock])
        // Opening a conversation whose answer is seconds old reads it whole: no replay.
        runner.turns = old + [Turn(id: "a2", date: clock, who: .oby, text: "Started it.")]
        model.forget()
        await model.reload()
        #expect(model.arrived.isEmpty)
        // A new conversation's first answer, read with its page just after it was said, comes in.
        runner.turns.append(Turn(id: "a3", date: clock, who: .oby, text: "And this one."))
        await model.reload(arriving: true)
        #expect(model.arrived == ["a3": clock.addingTimeInterval(5)])
        // History: older pages, and a reload of answers long said, don't.
        let history = FakeRunner((0..<120).map { turn($0, who: .oby) })
        let later = ConversationModel(page: history.page)
        later.time = { clock }
        await later.reload()
        await later.loadOlder()
        #expect(later.arrived.isEmpty)
    }
}
