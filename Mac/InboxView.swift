import SwiftUI

/// The island's Inbox, at the top of the list: what only you can answer, from the runner's jobs
/// and this Mac's, the longest-waiting first (docs/pipeline-cases.md, I.1). The first one is open,
/// as a decision card (Shared/DecisionCard.swift): its answers are on ⌘1 to ⌘3, your own words
/// go too, Later puts it off for an hour and Done lets it go; Open job opens its job's screen, where
/// a runner's job publishes too. Every kind the iPhone settles settles here, the same way. Once it's
/// settled, the next one opens. Answered on the iPhone, it goes from here too.
struct IslandInbox: View {
    let desk: Desk
    let feed: RunnerFeed
    /// Opens the item's job: its id, and whether it's this Mac's own.
    var onOpen: (_ job: String, _ local: Bool) -> Void = { _, _ in }
    /// The item open now (an Entry's id), or nil for the longest-waiting one.
    @State private var opened: String?
    /// Why the last answer didn't go through, until the next one does.
    @State private var problem: String?
    @State private var busy = false

    /// An item, and whether it's this Mac's own (else the runner's).
    struct Entry: Identifiable {
        var item: InboxItem
        var local: Bool
        var id: String { (local ? "mac/" : "runner/") + item.id }
    }

    /// Whether anything waits now, here or on the runner.
    static func waits(desk: Desk, feed: RunnerFeed, now: Date = .now) -> Bool {
        !entries(desk: desk, feed: feed, now: now).isEmpty
    }

    static func entries(desk: Desk, feed: RunnerFeed, now: Date) -> [Entry] {
        (InboxItem.waiting(desk.inbox, now: now).map { Entry(item: $0, local: true) }
            + InboxItem.waiting(feed.inbox, now: now).map { Entry(item: $0, local: false) })
            .sorted { $0.item.created < $1.item.created }
    }

    var body: some View {
        // Every half minute: "waiting 3m" moves on, and what was put off comes back.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let entries = Self.entries(desk: desk, feed: feed, now: context.date)
            if !entries.isEmpty {
                let current = entries.first { $0.id == opened } ?? entries[0]
                VStack(alignment: .leading, spacing: 8) {
                    Text("Inbox · \(entries.count)")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                        .padding(.leading, 4).padding(.top, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(entries) { entry in
                        if entry.id == current.id { card(entry, now: context.date) } else { row(entry, now: context.date) }
                    }
                }
                // Settled elsewhere, or another one opened: the problem was the one before's.
                .onChange(of: current.id, initial: true) { problem = nil }
            }
        }
    }

    /// The open item: what it asks, its answers (on ⌘1 to ⌘3, the recommended one first), your
    /// own words, and the ways out.
    private func card(_ entry: Entry, now: Date) -> some View {
        let item = entry.item
        // The Mac's `kind` is Engine's enum, the runner's a string: both read the same.
        let kind = "\(item.kind)"
        let extras = entry.local ? nil : feed.extras[item.job]
        let permission = kind == "permission" ? extras?.permission : nil
        // Oby's plain words (#65), when the runner wrote them; the item as it is otherwise.
        let words = entry.local ? InboxWords() : feed.inboxWords[item.id] ?? InboxWords()
        // A permission's words go with a deny; anything else's are the answer. An item without a job takes none.
        let answerWords: ((String) -> Void)? = item.job.isEmpty ? nil : { words in
            if permission != nil { deny(entry, words) } else { settle(entry, answer: words) }
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(item.line(now: now)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            DecisionCard(title: words.title(item.text), happened: words.body, behindDetails: words.details(item.text),
                         detail: permission?.detail,
                         plan: kind == "question" ? extras?.question?.plan : nil,
                         options: CardOption.inbox(item.options, kind: kind, question: extras?.question, permission: permission, words: words, details: item.details),
                         busy: busy, wordsNote: kind == "permission" ? CardOption.denyWords : nil,
                         onChoose: { settle(entry, answer: $0.answer) },
                         onWords: answerWords)
                .id(entry.id)
            HStack(spacing: 14) {
                Button("Later") { settle(entry, later: .now.addingTimeInterval(3600)) }
                    .help("Put it off for an hour")
                Button("Done") { settle(entry, done: true) }
                    .help("Let it go without answering")
                if !item.job.isEmpty {
                    Button("Open job") { onOpen(item.job, entry.local) }
                        .help("The job's screen: its result, Publish and Dismiss")
                }
                if let problem {
                    Text(problem).foregroundStyle(.red).lineLimit(2)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(busy)
    }

    /// Another item, waiting its turn: click to open it.
    private func row(_ entry: Entry, now: Date) -> some View {
        Button {
            opened = entry.id
            problem = nil
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.text).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(entry.item.line(now: now)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Deny, with the user's words for the agent: the runner settles the item.
    private func deny(_ entry: Entry, _ words: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await feed.answer(entry.item.job, .deny, message: words)
                opened = nil
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// This Mac's own items settle on its desk, the runner's through the runner; then the next one opens.
    private func settle(_ entry: Entry, answer: String? = nil, done: Bool? = nil, later: Date? = nil) {
        busy = true
        Task {
            defer { busy = false }
            do {
                if entry.local {
                    let how: Desk.Settle = if let answer { .answer(answer) } else if let later { .later(later) } else { .done }
                    try await desk.answer(entry.item.id, how)
                } else {
                    try await feed.settle(entry.item.id, answer: answer, done: done, later: later)
                }
                opened = nil
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
