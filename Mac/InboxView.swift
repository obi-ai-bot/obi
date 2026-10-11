import SwiftUI

/// The island's Inbox, at the top of the list: what only you can answer, from the runner's jobs
/// and this Mac's, the longest-waiting first (docs/pipeline-cases.md, I.1). The first one is open:
/// its answers are on ⌘1 to ⌘9, a question takes your own words too, Later puts it off for an hour
/// and Done lets it go. Once it's settled, the next one opens. Answered on the iPhone, it goes from
/// here too.
struct IslandInbox: View {
    let desk: Desk
    let feed: RunnerFeed
    /// The item open now (an Entry's id), or nil for the longest-waiting one.
    @State private var opened: String?
    @State private var reply = ""
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
                // Settled elsewhere, or another one opened: what was typed was for the one before.
                .onChange(of: current.id, initial: true) {
                    reply = ""
                    problem = nil
                }
            }
        }
    }

    /// The open item: what it asks, its answers, and the ways out.
    private func card(_ entry: Entry, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.item.line(now: now)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            ReadingText(entry.item.text, weight: .semibold)
            ForEach(Array(entry.item.options.prefix(9).enumerated()), id: \.offset) { index, option in
                Button { settle(entry, answer: option) } label: {
                    HStack {
                        Text(option).fontWeight(.medium).readingText()
                        Spacer(minLength: 8)
                        Text("⌘\(index + 1)").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            if entry.item.kind == .question {
                HStack(spacing: 8) {
                    TextField(entry.item.options.isEmpty ? "Your answer" : "Or type your answer", text: $reply)
                        .textFieldStyle(.plain).readingText()
                        .onSubmit { answerTyped(entry) }
                    Button { answerTyped(entry) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(typed.isEmpty ? 0.4 : 1), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(typed.isEmpty)
                    .accessibilityLabel("Answer")
                }
                .padding(.leading, 14).padding(.trailing, 5).frame(height: 34)
                .background(.white.opacity(0.06), in: Capsule())
            }
            HStack(spacing: 14) {
                Button("Later") { settle(entry, later: .now.addingTimeInterval(3600)) }
                    .help("Put it off for an hour")
                Button("Done") { settle(entry, done: true) }
                    .help("Let it go without answering")
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
            reply = ""
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

    private var typed: String { reply.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func answerTyped(_ entry: Entry) {
        guard !typed.isEmpty else { return }
        settle(entry, answer: typed)
    }

    /// This Mac's own items settle on its desk, the runner's through the runner; then the next one opens.
    private func settle(_ entry: Entry, answer: String? = nil, done: Bool? = nil, later: Date? = nil) {
        busy = true
        Task {
            defer { busy = false }
            do {
                if entry.local {
                    let how: Desk.Settle = if let answer { .answer(answer) } else if let later { .later(later) } else { .done }
                    try desk.settle(entry.item.id, how)
                } else {
                    try await feed.settle(entry.item.id, answer: answer, done: done, later: later)
                }
                opened = nil
                reply = ""
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
