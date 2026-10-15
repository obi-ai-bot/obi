import Foundation
import Testing
@testable import Oby

/// The window's thread (#11, apps/shared/ConversationModel.swift): the runner's conversation read in
/// pages and followed over its `turn` events, this Mac's own turns in the same list, the days it's
/// grouped by, and the jobs a turn's cards resolve to.
@MainActor
struct ConversationModelTests {
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
        #expect(model.runnerTurns.map(\.id) == (0..<120).map { "t\($0)" })
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

    @Test func aTurnEventJoinsTheThreadOrReplacesItsTurn() async throws {
        let model = ConversationModel(page: FakeRunner((0..<4).map { turn($0) }).page)
        await model.reload()
        // A new turn goes at the end; one said earlier (the runner's clock) takes its place by time.
        model.apply(turn(9, who: .oby))
        #expect(model.runnerTurns.map(\.id) == ["t0", "t1", "t2", "t3", "t9"])
        model.apply(turn(2, who: .oby, at: now.addingTimeInterval(-997.5 * 60)).withID("t2b"))
        #expect(model.runnerTurns.map(\.id) == ["t0", "t1", "t2", "t2b", "t3", "t9"])
        // The same turn again, with the job dispatched from it: replaced, not added.
        model.apply(turn(9, who: .oby, jobs: ["9f08fd10"]))
        #expect(model.runnerTurns.count == 6 && model.runnerTurns.last?.jobs == ["9f08fd10"])
        // This Mac's own turns join by time, and one the runner has too isn't shown twice.
        let local = [turn(1), turn(5, who: .user), turn(6, who: .oby)]
        #expect(model.thread(with: local).map(\.id) == ["t0", "t1", "t2", "t2b", "t3", "t5", "t6", "t9"])
        #expect(ConversationModel.merged([], local).map(\.id) == ["t1", "t5", "t6"])
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
        var dayStyle = Date.FormatStyle().day()
        dayStyle.calendar = calendar
        dayStyle.timeZone = calendar.timeZone
        #expect(days[0].title.contains(earlier.formatted(dayStyle)))
        #expect(days.map { $0.turns.map(\.id) } == [["t1", "t2"], ["t3"], ["t4", "t5"]])
        #expect(days.map(\.start) == [earlier, yesterday, today].map { calendar.startOfDay(for: $0) })
        // Another year names it.
        let old = calendar.date(byAdding: .year, value: -1, to: today)!
        #expect(ConversationModel.dayTitle(old, now: now, calendar: calendar).contains(old.formatted(Date.FormatStyle().year())))
        #expect(ConversationModel.days([], now: now, calendar: calendar).isEmpty)
    }

    @Test func consecutiveBubblesGroupOnlyWithinTheSameDayAndSpeaker() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: now)
        let first = turn(1, who: .oby, at: midnight + 60)
        #expect(ConversationModel.grouped(turn(2, who: .oby, at: midnight + 120), after: first, calendar: calendar))
        #expect(!ConversationModel.grouped(turn(2, at: midnight + 120), after: first, calendar: calendar))
        #expect(!ConversationModel.grouped(turn(2, who: .oby, at: midnight + 360), after: first, calendar: calendar))
        #expect(!ConversationModel.grouped(first, after: turn(0, who: .oby, at: midnight - 1), calendar: calendar))
        #expect(!ConversationModel.grouped(first, after: nil, calendar: calendar))
    }

    @Test func detailsRenderUnderTheReplyAndAreNotSpoken() throws {
        let turn = Turn(who: .oby, text: "The route is in Runner/API.swift.",
                        details: "Read [Runner/API.swift](https://github.com/deskree-inc/oby/blob/abc1234/Runner/API.swift#L1).")
        let rendered = try #require(ConversationModel.markdownDetails(for: turn))
        #expect(String(rendered.characters).contains("Runner/API.swift"))
        #expect(rendered.runs.contains { $0.link == URL(string: "https://github.com/deskree-inc/oby/blob/abc1234/Runner/API.swift#L1") })
        // Speech uses Turn.text; the longer citation block stays in its own field.
        #expect(turn.text == "The route is in Runner/API.swift.")
        #expect(turn.details?.contains("https://github.com") == true)
        #expect(ConversationModel.markdownDetails(for: Turn(who: .user, text: "Question", details: "hidden")) == nil)
    }

    @Test func aTurnsJobsResolveToCards() throws {
        var running = Job(id: "9f08fd10", request: "Review oby PR #33", agent: "claude", account: "default", repo: "deskree-inc/oby",
                          branch: "oby/review-33", pr: 33, kind: .review, task: "Review PR #33")
        running.status = .running
        let other = Job(id: "ab12cd34", request: "fix #7", agent: "codex", account: "work", repo: "deskree-inc/oby",
                        branch: "oby/fix-7", kind: .fix, task: "Fix #7")
        let oby = turn(2, who: .oby, jobs: ["ab12cd34", "9f08fd10", "unknown1"])
        // In the turn's order, this Mac's and the runner's alike; what neither has is left to fetch.
        #expect(ConversationModel.jobs(of: oby, among: [running, other]).map(\.id) == ["ab12cd34", "9f08fd10"])
        #expect(ConversationModel.missing(of: oby, among: [running, other]) == ["unknown1"])
        #expect(ConversationModel.jobs(of: turn(1), among: [running]).isEmpty && ConversationModel.missing(of: turn(1), among: []).isEmpty)
        // The runner's turn as the API sends it reads into the same Turn.
        let wire = #"{"id":"7c1e2f30","who":"oby","text":"On it.","at":"2026-10-11T09:12:04Z","jobs":["9f08fd10"],"details":"See [the route](https://example.com)."}"#
        let read = try Runner.decoder.decode(RunnerTurn.self, from: Data(wire.utf8)).turn
        #expect(read.id == "7c1e2f30" && read.who == .oby && read.text == "On it." && read.jobs == ["9f08fd10"] && read.voice == nil)
        #expect(read.details == "See [the route](https://example.com).")
        #expect(read.date == ISO8601DateFormatter().date(from: "2026-10-11T09:12:04Z"))
        let none = try Runner.decoder.decode(RunnerTurn.self, from: Data(#"{"id":"x","who":"user","text":"hi","at":"2026-10-11T09:12:04Z","jobs":[]}"#.utf8)).turn
        #expect(none.jobs == nil && none.who == .user)
        // The event the feed follows.
        var parser = EventParser()
        for line in ["event: turn", "data: \(wire)"] { #expect(parser.feed(line) == nil) }
        #expect(parser.feed("") == .turn(read))
    }
}

private extension Turn {
    func withID(_ id: String) -> Turn {
        var turn = self
        turn.id = id
        return turn
    }
}
