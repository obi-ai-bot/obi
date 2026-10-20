import Foundation
import Observation

/// One job's session as its view shows it, live (#785): every page of it from obid, then each
/// `transcript` event as it comes (an entry put in place by its `n`, more words added to the one
/// the agent is writing), and a slow check every 5 seconds while the job runs for anything an event
/// missed. It keeps the latest `most` entries. An entry's detail is fetched only when its row opens,
/// and only once obid is known to serve detail: until then no row opens, so nothing is made up.
@MainActor @Observable
final class LiveSession {
    let job: String
    @ObservationIgnored private let load: (Int?) async throws -> TranscriptPage
    @ObservationIgnored private let loadDetail: (Int) async throws -> TranscriptDetail
    private(set) var entries: [TranscriptEntry] = [] {
        didSet {
            // More words for an entry never change what the filters count.
            guard !appending else { return }
            counts = Dictionary(uniqueKeysWithValues: TranscriptEntry.Filter.allCases.map { tab in (tab, entries.count(where: tab.takes)) })
        }
    }
    @ObservationIgnored private var appending = false
    /// How many entries each filter takes, kept as the entries change.
    private(set) var counts: [TranscriptEntry.Filter: Int] = [:]
    /// The entry the agent is writing into now: more words came in the last moment (`append`).
    private(set) var arriving: Int?
    @ObservationIgnored private var lastAppend = 0
    /// Older entries were dropped to keep the latest `most`.
    private(set) var trimmed = false
    private(set) var loaded = false
    /// The runner has no session for the job (404): it's asked no more.
    private(set) var unavailable = false
    /// Why the last read failed, while there's nothing to show.
    private(set) var failure: String?
    /// Whether obid serves an entry's detail (#784): nil until it has been asked once.
    private(set) var detailServed: Bool?
    private(set) var details: [Int: TranscriptDetail] = [:]

    /// The most entries kept.
    nonisolated static let most = 2000

    init(job: String, load: @escaping (Int?) async throws -> TranscriptPage, loadDetail: @escaping (Int) async throws -> TranscriptDetail) {
        self.job = job
        self.load = load
        self.loadDetail = loadDetail
    }

    /// Reads what's new now, then, while `live`, again every 5 seconds behind the events.
    func follow(live: Bool) async {
        repeat {
            await catchUp()
            guard live, !unavailable else { return }
            try? await Task.sleep(for: .seconds(5))
        } while !Task.isCancelled
    }

    /// What came or changed since the last entry, every page of it, merged into the entries as
    /// they are once it's all here (an event may have come meanwhile); then whether detail is served.
    func catchUp() async {
        guard !unavailable else { return }
        do {
            let fresh = try await Self.pages(after: entries.last?.n, load: load)
            (entries, trimmed) = Self.kept(entries, trimmed: trimmed, adding: fresh)
            failure = nil
        } catch let error as RunnerError where error.status == 404 {
            unavailable = true
        } catch {
            if entries.isEmpty { failure = error.localizedDescription }
        }
        loaded = true
        await askDetailServed()
    }

    /// An event from the runner's stream: another job's is left alone.
    func apply(_ event: TranscriptEvent) {
        guard event.job == job else { return }
        if let entry = event.entry {
            (entries, trimmed) = Self.kept(entries, trimmed: trimmed, adding: [entry])
        } else if let n = event.n, let append = event.append, let index = entries.firstIndex(where: { $0.n == n }) {
            appending = true
            entries[index].text = (entries[index].text ?? entries[index].summary ?? "") + append
            appending = false
            arrived(n)
        }
    }

    /// Words came for `n`: it's arriving until a second and a half passes with no more.
    private func arrived(_ n: Int) {
        arriving = n
        lastAppend += 1
        let mark = lastAppend
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            if let self, self.lastAppend == mark { self.arriving = nil }
        }
    }

    /// An entry's detail, fetched the first time its row opens; nil when it can't be read.
    func detail(_ n: Int) async -> TranscriptDetail? {
        if let known = details[n] { return known }
        guard detailServed == true, let detail = try? await loadDetail(n) else { return nil }
        details[n] = detail
        return detail
    }

    /// Asks once, with a call that has ended, whether obid serves detail: a 404 says it doesn't.
    private func askDetailServed() async {
        guard detailServed == nil, let call = entries.first(where: { $0.kind == "tool" && !$0.running }) else { return }
        do {
            details[call.n] = try await loadDetail(call.n)
            detailServed = true
        } catch let error as RunnerError where error.status == 404 {
            detailServed = false
        } catch {}
    }

    /// What came or changed after entry `after`, following `next` page by page until there's no
    /// more (or a page brings nothing new).
    nonisolated static func pages(after: Int?, load: (Int?) async throws -> TranscriptPage) async throws -> [TranscriptEntry] {
        var fresh: [TranscriptEntry] = []
        var after = after
        while !Task.isCancelled {
            let page = try await load(after)
            fresh += page.entries
            guard let next = page.next, next != after, !page.entries.isEmpty else { break }
            after = next
        }
        return fresh
    }

    /// The entries once `new` comes: each by its `n`, a new one added and one obid sends again (a
    /// call that has ended since) put in its place, in `n` order, at most the latest `most`.
    nonisolated static func kept(_ kept: [TranscriptEntry], trimmed: Bool = false, adding new: [TranscriptEntry]) -> (entries: [TranscriptEntry], trimmed: Bool) {
        var all = kept
        var at = Dictionary(kept.enumerated().map { ($1.n, $0) }, uniquingKeysWith: { $1 })
        for entry in new {
            if let index = at[entry.n] {
                // Words that came as `append` after this copy was read stay.
                var entry = entry
                if let mine = all[index].text, mine.count > entry.words.count, mine.hasPrefix(entry.words) { entry.text = mine }
                all[index] = entry
            } else { at[entry.n] = all.count; all.append(entry) }
        }
        if !zip(all, all.dropFirst()).allSatisfy({ $0.n < $1.n }) { all.sort { $0.n < $1.n } }
        return all.count > most ? (Array(all.suffix(most)), true) : (all, trimmed)
    }
}
