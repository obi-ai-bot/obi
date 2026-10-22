import Foundation
import Observation

/// The thread the Mac's window and the iPhone's Chat show (#11): the runner's conversation, read
/// in pages (`GET /v1/conversation`) and followed over its `turn` events, with the app's own
/// turns (the Mac's desk's, the iPhone's words still on their way) in the same list by time. One
/// thread for every device: what was said elsewhere is here too. The thread is grouped by day,
/// and each turn's jobs resolve to cards.
@Observable
final class ConversationModel {
    /// How many turns a page holds, as the runner serves them.
    static let pageSize = 50

    /// The runner's turns loaded so far, oldest first.
    private(set) var runnerTurns: [Turn] = []
    /// Whether the runner has turns older than the oldest loaded.
    private(set) var hasOlder = false
    private(set) var loading = false
    /// The latest page has been read once since the last [`forget`]. A new conversation forgets on purpose and stays empty.
    private(set) var loaded = false
    /// Why the last page couldn't be read, or nil.
    private(set) var problem: String?
    /// One page before the turn `before` names (nil for the latest), at most `limit` turns, oldest
    /// first: the runner's `GET /v1/conversation`. The feed sets it; tests put in their own.
    @ObservationIgnored var page: @MainActor (_ before: String?, _ limit: Int) async throws -> [Turn]
    /// The steps of Oby's turns, by the user's turn id (#304), in order. Live only: the runner
    /// sends them as a turn goes, and a reload keeps just the ones that ended.
    private(set) var steps: [String: [TurnStep]] = [:]
    /// The turn the latest step belongs to.
    private(set) var latestStepTurn: String?
    /// Counts reloads and forgets: a page from before the last one is dropped.
    private var generation = 0
    /// When each of Oby's answers came while the thread was open, by turn id: its words come in a
    /// word at a time from then (`WordReveal`). History read later isn't here.
    private(set) var arrived: [String: Date] = [:]
    /// Now, for `arrived`; tests put in their own.
    @ObservationIgnored var time: () -> Date = { .now }

    /// Oby's words under way (obid's `delta` events), by the user's turn id, with when the first
    /// came: shown coming in until Oby's turn replaces them.
    struct Streamed: Equatable {
        var text: String
        var since: Date
    }
    private(set) var streamed: [String: Streamed] = [:]
    /// The artifacts a turn made, by the turn's id (the app's Turn doesn't keep them).
    private(set) var refs: [String: [ArtifactRef]] = [:]
    /// The turns a job added when it ended (#351), by id: not answers.
    private var ended: Set<String> = []
    /// What's known of each artifact, by id: from `artifact` events and `lookUp`.
    private(set) var artifacts: [String: RunnerArtifact] = [:]
    /// Artifacts obid deleted or doesn't have.
    private(set) var gone: Set<String> = []
    /// `GET /v1/artifacts/{id}`, or nil when there's no such one; the feed sets it.
    @ObservationIgnored var lookUp: @MainActor (_ id: String) async throws -> RunnerArtifact? = { _ in nil }

    init(page: @escaping @MainActor (_ before: String?, _ limit: Int) async throws -> [Turn] = { _, _ in [] }) {
        self.page = page
    }

    /// The latest page, in place of what was loaded: on every connection to the runner, so what
    /// was said elsewhere while the connection was down is here. `arriving`: the page of a new
    /// conversation just started here, whose first answer comes in word by word; any other reload
    /// (opening a conversation, reconnecting) shows its turns whole.
    func reload(arriving: Bool = false) async {
        generation += 1
        let mine = generation
        loading = true
        defer { if mine == generation { loading = false; loaded = true } }
        do {
            let latest = try await page(nil, Self.pageSize)
            guard mine == generation else { return }
            if arriving { for turn in latest where !runnerTurns.contains(where: { $0.id == turn.id }) { arrive(turn) } }
            runnerTurns = Self.ordered(latest)
            hasOlder = latest.count >= Self.pageSize
            problem = nil
            // A connection that dropped may have missed the end of a step: none stays running.
            steps = Self.settled(steps)
            // Nor Oby's answer: words under way that the page answered are done.
            streamed = streamed.filter { id, _ in
                guard let at = runnerTurns.firstIndex(where: { $0.id == id }) else { return true }
                return !runnerTurns[(at + 1)...].contains { answers($0) }
            }
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
    func apply(_ turn: Turn, _ extras: TurnExtras = TurnExtras()) {
        if !extras.artifacts.isEmpty { refs[turn.id] = extras.artifacts }
        if extras.ended { ended.insert(turn.id) }
        let new = !runnerTurns.contains(where: { $0.id == turn.id })
        // Oby's answer, new to the thread, replaces the words that came in, which carry on from when
        // they started, not again. A turn sent again (a job joined it) or a job's ended turn isn't
        // an answer: words under way stay.
        if new, answers(turn), let since = streamed.values.map(\.since).min() {
            streamed = [:]
            arrived[turn.id] = arrived[turn.id] ?? since
        }
        if new { arrive(turn) }
        runnerTurns = Self.placed(turn, in: runnerTurns)
    }

    /// Whether `turn` is Oby's answer to words: not the turn a job adds when it ends.
    private func answers(_ turn: Turn) -> Bool { turn.who == .oby && !ended.contains(turn.id) }

    /// Whether `turn` is one a job added when it ended (#351): its card there isn't where it started.
    func endedTurn(_ turn: Turn) -> Bool { ended.contains(turn.id) }

    /// A page of the runner's turns: the artifacts they made, for their cards, and which are a job's
    /// ended turn.
    func note(_ turns: [RunnerTurn]) {
        for turn in turns {
            if let list = turn.artifacts, !list.isEmpty { refs[turn.id] = list }
            if turn.ended == true { ended.insert(turn.id) }
        }
    }

    /// A `delta` event: the words join the answer under way for its turn.
    func apply(_ delta: TurnDelta) {
        streamed[delta.turn, default: Streamed(text: "", since: time())].text += delta.text
    }

    /// The words under way for `turn`, as `steps(under:in:)` finds its steps.
    func streamed(under turn: Turn, in thread: [Turn]) -> Streamed? {
        if let own = streamed[turn.id] { return own }
        guard turn.who == .user, !thread.contains(where: { streamed[$0.id] != nil }),
              thread.last(where: { $0.who == .user })?.id == turn.id else { return nil }
        // The phone's echo: the words of the turn the thread doesn't have.
        return streamed.values.max { $0.since < $1.since }
    }

    /// The artifacts to show under `turn`.
    func artifactRefs(of turn: Turn) -> [ArtifactRef] { refs[turn.id] ?? [] }

    /// An `artifact` event: a new one, a new version or title, or one deleted.
    func apply(_ event: ArtifactEvent) {
        if event.deleted == true {
            artifacts[event.id] = nil
            gone.insert(event.id)
            return
        }
        var artifact = artifacts[event.id] ?? RunnerArtifact(id: event.id, title: event.title ?? "", kind: event.kind ?? "",
                                                             conversation: event.conversation, job: event.job)
        if let title = event.title { artifact.title = title }
        if let kind = event.kind { artifact.kind = kind }
        if let version = event.version, !artifact.versions.contains(where: { $0.version == version }) {
            artifact.versions.append(.init(version: version, files: []))
        }
        artifacts[event.id] = artifact
        gone.remove(event.id)
    }

    /// What's known of artifact `id`, read from obid when it isn't yet.
    func resolve(_ id: String) async {
        guard artifacts[id] == nil, !gone.contains(id) else { return }
        do {
            if let found = try await lookUp(id) { artifacts[id] = found } else { gone.insert(id) }
        } catch {
            // Not now: the card says so, and the next look tries again.
        }
    }


    /// Oby's turn, new to the thread, said in the last few seconds: it comes in word by word.
    private func arrive(_ turn: Turn) {
        let now = time()
        guard turn.who == .oby, arrived[turn.id] == nil, abs(now.timeIntervalSince(turn.date)) < 10 else { return }
        arrived[turn.id] = now
    }

    /// A `step` event: the step with that turn and index changes, or is added in its place.
    func apply(_ step: TurnStep) {
        steps[step.turn] = Self.placed(step, in: steps[step.turn] ?? [])
        latestStepTurn = step.turn
    }

    /// Stop was pressed: what still runs ended.
    func settleSteps() {
        steps = Self.settled(steps)
    }

    /// The answer to the turn came: what its last steps still show as running is done.
    func settleLatestSteps() {
        guard let latestStepTurn, let list = steps[latestStepTurn] else { return }
        steps[latestStepTurn] = Self.settled(list, as: .done)
    }

    /// Whether a step of any turn still runs: Oby is working, and Stop shows.
    var working: Bool { steps.values.contains { $0.contains { $0.state == .running } } }

    /// Another runner, or none: nothing the last one said holds.
    func forget() {
        generation += 1
        steps = [:]
        latestStepTurn = nil
        arrived = [:]
        streamed = [:]
        refs = [:]
        ended = []
        artifacts = [:]
        gone = []
        runnerTurns = []
        hasOlder = false
        loading = false
        loaded = false
        problem = nil
    }

    /// The thread: the runner's turns and the app's own, oldest first, one per id.
    func thread(with local: [Turn]) -> [Turn] { Self.merged(runnerTurns, local) }

    /// The long answer shown under Oby's short reply. Keeping it in the turn (separate from
    /// `text`) means speech always receives only the short reply.
    static func markdownDetails(for turn: Turn) -> AttributedString? {
        guard turn.who == .oby, let details = turn.details else { return nil }
        return try? AttributedString(markdown: details, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }

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

    // MARK: Steps

    /// `step` in the turn's list: in place of the one with its index, else where its index puts it.
    nonisolated static func placed(_ step: TurnStep, in list: [TurnStep]) -> [TurnStep] {
        var list = list
        if let at = list.firstIndex(where: { $0.index == step.index }) {
            list[at] = step
        } else {
            list.insert(step, at: list.firstIndex { $0.index > step.index } ?? list.count)
        }
        return list
    }

    /// Every step that still runs, ended as failed: it won't be heard of again.
    nonisolated static func settled(_ steps: [String: [TurnStep]]) -> [String: [TurnStep]] {
        steps.mapValues { settled($0) }
    }

    /// `state` is what a step that still runs ends as: failed when it was stopped or lost, done
    /// when the turn's answer came without its end.
    nonisolated static func settled(_ list: [TurnStep], as state: TurnStep.State = .failed) -> [TurnStep] {
        list.map { step in
            var step = step
            if step.state == .running { step.state = state }
            return step
        }
    }

    /// The steps to show under `turn`: its own. The user's turn the runner hasn't listed yet (the
    /// phone's echo of it) has none by its id, so the last user turn takes the steps of a turn
    /// the thread doesn't have.
    nonisolated static func steps(under turn: Turn, among steps: [String: [TurnStep]], latest: String?, thread: [Turn]) -> [TurnStep] {
        if let own = steps[turn.id] { return own }
        guard turn.who == .user, let latest, !thread.contains(where: { $0.id == latest }),
              thread.last(where: { $0.who == .user })?.id == turn.id else { return [] }
        return steps[latest] ?? []
    }

    /// The steps to show under `turn` of the thread.
    func steps(under turn: Turn, in thread: [Turn]) -> [TurnStep] {
        Self.steps(under: turn, among: steps, latest: latestStepTurn, thread: thread)
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

    /// Consecutive bubbles share an avatar within five minutes, never across midnight.
    nonisolated static func grouped(_ turn: Turn, after previous: Turn?, calendar: Calendar = .current) -> Bool {
        guard let previous else { return false }
        let gap = turn.date.timeIntervalSince(previous.date)
        return turn.who == previous.who && gap >= 0 && gap < 300
            && calendar.isDate(turn.date, inSameDayAs: previous.date)
    }

    /// Attach a decision to the turn that launched its job; older/unlinked jobs attach by time.
    /// No preceding turn means the decision stands alone at the start of the loaded transcript.
    nonisolated static func decisionAnchor(job: String, created: Date, turns: [Turn]) -> String? {
        let ordered = ordered(turns)
        return ordered.last(where: { ($0.jobs ?? []).contains(job) })?.id
            ?? ordered.last(where: { $0.date <= created })?.id
    }

    /// Whether the decision of `job` belongs in the conversation shown (Sangam: a decision lives
    /// with its task, mac-design C3): with obid's conversations (`served`), only one whose job a
    /// turn here started or obid says `startedIn` this one. One with no job (a plan waiting for
    /// Start, a confirm) only in the conversation it came `from`, never opened out in another;
    /// one from no conversation waits in Needs you. A runner with one thread shows every decision.
    nonisolated static func shows(decisionOf job: String, startedIn: String?, from: String? = nil, served: Bool, shown: String?, turns: [Turn]) -> Bool {
        guard served else { return true }
        guard !job.isEmpty else { return from != nil && from == shown }
        if turns.contains(where: { ($0.jobs ?? []).contains(job) }) { return true }
        return shown != nil && startedIn == shown
    }

    /// Time groups are independent of sender/bubble groups: a reply doesn't start a new time line.
    nonisolated static func showsTime(_ turn: Turn, after previous: Turn?, calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        return !calendar.isDate(turn.date, inSameDayAs: previous.date)
            || turn.date.timeIntervalSince(previous.date) > 15 * 60
    }

    // MARK: Jobs

    /// The jobs a turn started, among `jobs`, in the turn's order; ids not among them are left out
    /// (the apps fetch a runner's job that's older than its list).
    nonisolated static func jobs(of turn: Turn, among jobs: [Job]) -> [Job] {
        (turn.jobs ?? []).compactMap { id in jobs.first { $0.id == id } }
    }

    /// The ids a turn names that `jobs` doesn't have: to fetch from the runner.
    nonisolated static func missing(of turn: Turn, among jobs: [Job]) -> [String] {
        (turn.jobs ?? []).filter { id in !jobs.contains { $0.id == id } }
    }
}
