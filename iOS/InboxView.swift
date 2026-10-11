import SwiftUI

/// Home's Inbox, above the jobs: what only you can answer, the longest-waiting first
/// (docs/pipeline-cases.md, I.1). The first one is open, with a button per answer, and a question
/// takes your own words too; Later puts it off for an hour, Done lets it go. Once it's settled, the
/// next one opens. Answered on the Mac, it goes from here too.
struct InboxSection: View {
    @Environment(Phone.self) private var phone
    /// The item open now, or nil for the longest-waiting one.
    @State private var opened: String?
    @State private var reply = ""
    /// Why the last answer didn't go through, until the next one does.
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        // Every half minute: "waiting 3m" moves on, and what was put off comes back.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let items = InboxItem.waiting(phone.inbox, now: context.date)
            if !items.isEmpty {
                let current = items.first { $0.id == opened } ?? items[0]
                VStack(alignment: .leading, spacing: 8) {
                    Text("Inbox · \(items.count)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.top, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(items) { item in
                        if item.id == current.id { card(item, now: context.date) } else { row(item, now: context.date) }
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
    private func card(_ item: InboxItem, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.line(now: now)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ReadingText(item.text, weight: .semibold)
            ForEach(item.options, id: \.self) { option in
                Button { settle(item, answer: option) } label: {
                    Text(option).fontWeight(.medium).readingText()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            if item.kind == "question" {
                HStack(spacing: 8) {
                    TextField(item.options.isEmpty ? "Your answer" : "Or type your answer", text: $reply, axis: .vertical)
                        .lineLimit(1...4)
                        .readingText()
                        .submitLabel(.send)
                        .onSubmit { answerTyped(item) }
                    Button { answerTyped(item) } label: {
                        Image(systemName: "arrow.up").font(.footnote.weight(.bold))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(typed.isEmpty ? 0.4 : 1), in: Circle())
                    }
                    .disabled(typed.isEmpty)
                    .accessibilityLabel("Answer")
                }
                .padding(.leading, 14).padding(.trailing, 5).padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            }
            HStack(spacing: 18) {
                Button("Later") { settle(item, later: .now.addingTimeInterval(3600)) }
                    .accessibilityHint("Puts it off for an hour")
                Button("Done") { settle(item, done: true) }
                    .accessibilityHint("Lets it go without answering")
                Spacer()
                if !item.job.isEmpty { NavigationLink("Open job", value: item.job) }
            }
            .font(.subheadline)
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .disabled(busy)
    }

    /// Another item, waiting its turn: tap to open it.
    private func row(_ item: InboxItem, now: Date) -> some View {
        Button {
            opened = item.id
            reply = ""
            problem = nil
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(item.line(now: now)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var typed: String { reply.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func answerTyped(_ item: InboxItem) {
        guard !typed.isEmpty else { return }
        settle(item, answer: typed)
    }

    /// Through the runner, so the Mac's island settles it too; then the next one opens.
    private func settle(_ item: InboxItem, answer: String? = nil, done: Bool? = nil, later: Date? = nil) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await phone.settle(item.id, answer: answer, done: done, later: later)
                opened = nil
                reply = ""
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
