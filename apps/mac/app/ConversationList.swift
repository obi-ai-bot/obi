import Foundation
import Observation

/// The conversations obid keeps (#493, docs/runner-api.md "obid only: conversations"), as the side
/// panel lists them, and which one the window shows. The Swift runner keeps one thread and answers
/// 404 to `GET /v1/conversations`: then `served` stays false, nothing here shows, and every call
/// goes out as it did before, so the one thread is the latest conversation of a runner that has
/// them. Only the runner on this Mac plans through the runner (`RunnerFeed.local`); a remote
/// runner's conversations aren't listed, as the Mac's own brain would answer in them.
/// Where `POST /v1/plans` puts the user's words (obid only, #493): the conversation it names, a new
/// one, or (neither) the latest, as every app from before conversations sends them.
nonisolated enum PlanTarget: Equatable, Sendable {
    case latest
    case conversation(String)
    case new
}

extension Runner {
    /// `POST /v1/plans` with the words going where `target` says.
    func planned(_ said: String, answer: (question: String, option: String)? = nil, attachments: [String] = [],
                 in target: PlanTarget) async throws -> PlannedTurn {
        switch target {
        case .latest: try await planned(said, answer: answer, attachments: attachments)
        case .conversation(let id): try await planned(said, answer: answer, attachments: attachments, conversation: id)
        case .new: try await planned(said, answer: answer, attachments: attachments, new: true)
        }
    }
}

@Observable
final class ConversationList {
    /// The runner serves conversations and this Mac plans through it: the list shows.
    private(set) var served = false
    /// The conversations, pinned first, then newest first.
    private(set) var items: [RunnerConversation] = []
    /// The one the window shows, or nil: none yet, or a new one, which its first words start.
    private(set) var shown: String?
    /// A new conversation is open and empty; its first words start it (`"new": true`).
    private(set) var starting = false
    /// The words that start a new conversation are on their way: the first conversation the runner
    /// announces meanwhile is theirs.
    private(set) var creating = false
    /// Why the last rename, pin or delete didn't go through, or nil.
    private(set) var problem: String?
    /// The conversations known when the words that start a new one went out.
    @ObservationIgnored private var known: Set<String> = []
    /// The words starting a new conversation, while they're on their way.
    @ObservationIgnored private var creatingWords: String?
    /// The next words are the talk key's, said away from the conversation page: they go to the
    /// latest conversation, as the Watch's do (#493), and obid picks it (no `conversation`, #507).
    @ObservationIgnored var nextToLatest = false

    /// The runner followed, and the thread the window shows.
    @ObservationIgnored var runner: () -> Runner? = { nil }
    @ObservationIgnored let thread: ConversationModel

    init(thread: ConversationModel) { self.thread = thread }

    // MARK: Following the runner

    /// Reads the list on every connection to the runner. A runner that doesn't serve it (or one this
    /// Mac doesn't plan through) leaves the one thread as it was.
    func load(from runner: Runner, planning: Bool) async throws {
        guard planning else { return take(nil) }
        // obid keeps at most 200 unless more are pinned.
        take(try await runner.conversations(limit: 200))
    }

    /// The list the runner gave, or nil: it keeps one thread.
    func take(_ list: [RunnerConversation]?) {
        guard let list else { return reset() }
        served = true
        items = ConversationOrder.ordered(list.filter { !$0.deleted })
        problem = nil
        // The one shown was deleted meanwhile: a new one is open. None shown yet: the latest.
        if let shown, !items.contains(where: { $0.id == shown }) { self.shown = nil }
        if shown == nil, !starting { shown = Self.latest(items)?.id }
    }

    /// Another runner, or none: one thread again.
    func reset() {
        served = false
        items = []
        shown = nil
        starting = false
        creating = false
        problem = nil
    }

    /// A `conversation` event: it started, got a turn, was renamed or pinned, or was deleted.
    func apply(_ conversation: RunnerConversation) {
        guard served else { return }
        let new = !items.contains { $0.id == conversation.id }
        items = ConversationOrder.placed(conversation, in: items)
        if conversation.deleted {
            guard conversation.id == shown else { return }
            // Deleted where it was open: its next words start a new one.
            shown = nil
            starting = true
            thread.forget()
        } else if new, creating, starting, shown == nil, !known.contains(conversation.id),
                  creatingWords.map({ ConversationOrder.started(by: $0, conversation) }) ?? true {
            // The words this window sent to start one: it's theirs (obid titles it from them),
            // before its first turn lands. Another device's new one is only listed; the answer
            // names this window's anyway (`joined`).
            known.insert(conversation.id)
            // Shown at once, so its first turn (the next event) isn't dropped; its history follows.
            select(conversation.id)
            Task { await thread.reload() }
        }
    }

    /// What the trail calls the conversation shown: its title, or a new one's name.
    var shownTitle: String {
        shown.flatMap { id in items.first { $0.id == id }?.title } ?? Self.newTitle
    }

    nonisolated static let newTitle = "New conversation"

    /// Whether a `turn` or a `step` of `conversation` belongs on the window's thread: one runner
    /// conversation is shown at a time; one that names none (a runner with one thread) always does.
    func shows(_ conversation: String?) -> Bool {
        guard served, let conversation else { return true }
        return conversation == shown
    }

    // MARK: What the window does

    /// Opens a conversation's history in the window.
    func open(_ id: String) async {
        guard served, id != shown else { return }
        await show(id)
    }

    private func select(_ id: String) {
        shown = id
        starting = false
        thread.forget()
    }

    private func show(_ id: String) async {
        select(id)
        await thread.reload()
    }

    /// New conversation: empty, until its first words start it.
    func startNew() {
        guard served else { return }
        shown = nil
        starting = true
        thread.forget()
    }

    // MARK: Words to Oby

    /// Where the words about to go to `POST /v1/plans` land. A runner with one thread gets neither
    /// field. Marks a new conversation as under way, started by `said`.
    func target(_ said: String? = nil) -> PlanTarget {
        defer { nextToLatest = false }
        guard served, !nextToLatest else { return .latest }
        if let shown, !starting { return .conversation(shown) }
        known = Set(items.map(\.id))
        creating = true
        creatingWords = said
        return .new
    }

    /// The runner answered: the words joined `conversation` (nil from a runner with one thread).
    func joined(_ conversation: String?) async {
        let started = creating
        creating = false
        // Still on the new conversation these words started: it opens. Somewhere else by now, or
        // words that joined the latest one: the window stays where it is.
        guard served, started, starting, let conversation else { return }
        known.insert(conversation)
        await show(conversation)
    }

    /// What obid finds for `query`, in titles and in what was said (`GET /v1/conversations?q=`),
    /// or nil: nothing to look for, or the runner couldn't answer.
    func search(_ query: String) async -> [RunnerConversation]? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard served, !query.isEmpty, let runner = runner() else { return nil }
        return try? await runner.conversations(query: query, limit: 200)
    }

    /// The request failed: nothing was started.
    func failed() { creating = false }

    // MARK: Rename, pin, delete

    func rename(_ id: String, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let conversation = items.first(where: { $0.id == id }), conversation.title != title else { return }
        await change { try await $0.updateConversation(id, title: title) }
    }

    func pin(_ id: String, _ pinned: Bool) async {
        await change { try await $0.updateConversation(id, pinned: pinned) }
    }

    func delete(_ id: String) async {
        guard let runner = runner() else { return }
        do {
            try await runner.deleteConversation(id)
            problem = nil
            apply(RunnerConversation(id: id, title: "", deleted: true))
        } catch {
            problem = error.localizedDescription
        }
    }

    private func change(_ call: (Runner) async throws -> RunnerConversation) async {
        guard let runner = runner() else { return }
        do {
            apply(try await call(runner))
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Order

    /// The one with the latest turn: what the runner continues without a `conversation`.
    nonisolated static func latest(_ list: [RunnerConversation]) -> RunnerConversation? {
        list.max { $0.latest == $1.latest ? $0.id > $1.id : $0.latest < $1.latest }
    }

    /// The list as the panel shows it, matching `query` in the title (any case): Pinned, then Recent.
    nonisolated static func sections(_ list: [RunnerConversation], matching query: String) -> (pinned: [RunnerConversation], recent: [RunnerConversation]) {
        let query = query.trimmingCharacters(in: .whitespaces)
        return ConversationOrder.sections(list.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) })
    }
}

extension RunnerFeed {
    /// The side panel lists conversations and the window carries on in the one shown.
    var conversationsOn: Bool { conversations.served }

    /// The conversation that started the runner's job, while it's still listed (deleted, a job keeps
    /// the id and its card opens its own page).
    func startedIn(job: String) -> String? {
        extras[job]?.conversation.flatMap { id in conversations.items.contains { $0.id == id } ? id : nil }
    }
}

extension IslandModel {
    /// Whether a job's page offers the way to its conversation: the one that started it, or (a
    /// runner with one thread) the thread, when one of its turns started the job.
    func hasConversation(of job: String, local: Bool) -> Bool {
        if feed.conversationsOn, !local { return feed.startedIn(job: job) != nil }
        return ConversationModel.started(job, in: thread)
    }

    /// Makes the conversation that started the job the one the window shows.
    func showConversation(of job: String, local: Bool) {
        guard feed.conversationsOn, !local, let id = feed.startedIn(job: job) else { return }
        Task { await feed.conversations.open(id) }
    }
}
