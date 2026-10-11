import Foundation
import Observation

/// The window's thread (#11): the runner's conversation, read in pages (`GET /v1/conversation`)
/// and followed over its `turn` events, with this Mac's own turns (its desk's) in the same list
/// by time. One thread for every device: what was said from the iPhone is here too. The thread
/// is grouped by day, and each turn's jobs resolve to cards.
@Observable
final class ConversationModel {
    /// How many turns a page holds, as the runner serves them.
    static let pageSize = 50

    /// The runner's turns loaded so far, oldest first.
    private(set) var runnerTurns: [Turn] = []
    /// Whether the runner has turns older than the oldest loaded.
    private(set) var hasOlder = false
    private(set) var loading = false
    /// Why the last page couldn't be read, or nil.
    private(set) var problem: String?
    /// One page before the turn `before` names (nil for the latest), at most `limit` turns, oldest
    /// first: the runner's `GET /v1/conversation`. The feed sets it; tests put in their own.
    @ObservationIgnored var page: @MainActor (_ before: String?, _ limit: Int) async throws -> [Turn]
    /// Counts reloads and forgets: a page from before the last one is dropped.
    private var generation = 0

    init(page: @escaping @MainActor (_ before: String?, _ limit: Int) async throws -> [Turn] = { _, _ in [] }) {
        self.page = page
    }

    /// The latest page, in place of what was loaded: on every connection to the runner, so what
    /// was said elsewhere while the connection was down is here.
    func reload() async {
        generation += 1
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false } }
        do {
            let latest = try await page(nil, Self.pageSize)
            guard mine == generation else { return }
            runnerTurns = Self.ordered(latest)
            hasOlder = latest.count >= Self.pageSize
            problem = nil
        } catch {
            guard mine == generation else { return }
            problem = error.localizedDescription
        }
    }

    /// The page before the oldest turn loaded, when the runner has one.
    func loadOlder() async {
        guard hasOlder, !loading, let oldest = runnerTurns.first else { return }
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false } }
        do {
            let older = try await page(oldest.id, Self.pageSize)
            guard mine == generation else { return }
            runnerTurns = Self.merged(older, runnerTurns)
            hasOlder = older.count >= Self.pageSize
            problem = nil
        } catch {
            guard mine == generation else { return }
            problem = error.localizedDescription
        }
    }

    /// A `turn` event: the turn with that id is replaced (a job joined it), or the new one takes
    /// its place by time.
    func apply(_ turn: Turn) {
        runnerTurns = Self.placed(turn, in: runnerTurns)
    }

    /// Another runner, or none: nothing the last one said holds.
    func forget() {
        generation += 1
        runnerTurns = []
        hasOlder = false
        loading = false
        problem = nil
    }

    /// The thread: the runner's turns and this Mac's own, oldest first, one per id.
    func thread(with local: [Turn]) -> [Turn] { Self.merged(runnerTurns, local) }

    // MARK: Order

    /// Oldest first; turns said at the same moment keep the order they came in.
    nonisolated static func ordered(_ turns: [Turn]) -> [Turn] {
        turns.enumerated().sorted { a, b in a.element.date == b.element.date ? a.offset < b.offset : a.element.date < b.element.date }.map(\.element)
    }

    /// Both lists in one, oldest first, one turn per id: the first list's version of a turn both have.
    nonisolated static func merged(_ first: [Turn], _ second: [Turn]) -> [Turn] {
        var seen: Set<String> = []
        var all: [Turn] = []
        for turn in first + second where seen.insert(turn.id).inserted { all.append(turn) }
        return ordered(all)
    }

    /// `turn` in the list: in place of the one with its id, else where its time puts it.
    nonisolated static func placed(_ turn: Turn, in list: [Turn]) -> [Turn] {
        var list = list
        if let index = list.firstIndex(where: { $0.id == turn.id }) {
            list[index] = turn
            return ordered(list)
        }
        list.insert(turn, at: list.firstIndex { $0.date > turn.date } ?? list.count)
        return list
    }

    // MARK: Days

    /// One day of the thread, with its separator's title.
    struct Day: Identifiable, Equatable {
        var start: Date
        var title: String
        var turns: [Turn]
        var id: Date { start }
    }

    /// The thread by day, oldest first: "Today", "Yesterday", else the weekday and date.
    nonisolated static func days(_ turns: [Turn], now: Date = .now, calendar: Calendar = .current) -> [Day] {
        var days: [Day] = []
        for turn in ordered(turns) {
            let start = calendar.startOfDay(for: turn.date)
            if days.last?.start == start {
                days[days.count - 1].turns.append(turn)
            } else {
                days.append(Day(start: start, title: dayTitle(start, now: now, calendar: calendar), turns: [turn]))
            }
        }
        return days
    }

    nonisolated static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        var style = Date.FormatStyle()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        let dated = style.weekday(.wide).month(.wide).day()
        return day.formatted(calendar.isDate(day, equalTo: now, toGranularity: .year) ? dated : dated.year())
    }

    /// "9:12 AM", as the thread labels a turn.
    nonisolated static func clock(_ date: Date) -> String { date.formatted(Date.FormatStyle().hour().minute()) }

    // MARK: Jobs

    /// The jobs a turn started, among `jobs`, in the turn's order; ids not among them are left out
    /// (the window fetches a runner's job that's older than its list).
    nonisolated static func jobs(of turn: Turn, among jobs: [Job]) -> [Job] {
        (turn.jobs ?? []).compactMap { id in jobs.first { $0.id == id } }
    }

    /// The ids a turn names that `jobs` doesn't have: to fetch from the runner.
    nonisolated static func missing(of turn: Turn, among jobs: [Job]) -> [String] {
        (turn.jobs ?? []).filter { id in !jobs.contains { $0.id == id } }
    }
}
