import SwiftUI

/// Home's Inbox, above the jobs: what only you can answer, the longest-waiting first
/// (docs/pipeline-cases.md, I.1). The first one is open, as a decision card (apps/shared/DecisionCard.swift):
/// its answers, the recommended one first, and your own words; Later puts it off for an hour, Done
/// lets it go. Once it's settled, the next one opens. Answered on the Mac, it goes from here too.
struct InboxSection: View {
    @Environment(\.openURL) private var openURL
    @Environment(Phone.self) private var phone
    /// The item open now, or nil for the longest-waiting one.
    @State private var opened: String?
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
                // Settled elsewhere, or another one opened: the problem was the one before's.
                .onChange(of: current.id, initial: true) { problem = nil }
            }
        }
    }

    /// The open item: what it asks, its answers, and the ways out.
    private func card(_ item: InboxItem, now: Date) -> some View {
        let job = phone.jobs.first { $0.id == item.job }
        let permission = item.kind == "permission" ? job?.permission : nil
        // A confirm item (obid only, #546): its title is what Confirm does, why it waits under it,
        // the words it would send quoted apart; Confirm or Cancel, nothing recommended, no words.
        let confirming = item.kind == RunnerConfirm.kind
        // A permission's words go with a deny; anything else's are the answer. An item without a job takes none.
        let answerWords: ((String) -> Void)? = item.job.isEmpty || confirming ? nil : { words in
            if let job, permission != nil { deny(job, words) } else { settle(item, answer: words) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text(item.line(now: now)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            // Oby's plain words (#65), when the runner wrote them; the item as it is otherwise.
            DecisionCard(title: confirming ? item.title : item.words.title(item.text),
                         happened: confirming ? InboxWords.plain(item.text) : item.words.body,
                         behindDetails: confirming ? nil : item.words.details(item.text),
                         detail: confirming ? item.confirm?.words : permission?.detail,
                         plan: item.kind == "question" ? job?.question?.plan : nil,
                         options: CardOption.inbox(item.options, kind: item.kind, question: job?.question, permission: permission, words: item.words,
                                                   details: item.details, does: item.title),
                         busy: busy, wordsNote: item.kind == "permission" ? CardOption.denyWords : nil,
                         onChoose: { option in
                             if option.answer == "Open the PR",
                                let published = phone.jobs.first(where: { $0.id == item.job })?.published,
                                let url = URL(string: published) { openURL(url) }
                             else { settle(item, answer: option.answer) }
                         },
                         onWords: answerWords)
                .id(item.id)
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
            problem = nil
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind == RunnerConfirm.kind ? item.title : item.text).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(item.line(now: now)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Deny, with the user's words for the agent: the runner settles the item.
    private func deny(_ job: Job, _ words: String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await phone.answer(job, .deny, message: words)
                opened = nil
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// Through the runner, so the Mac's island settles it too; then the next one opens.
    private func settle(_ item: InboxItem, answer: String? = nil, done: Bool? = nil, later: Date? = nil) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await phone.settle(item.id, answer: answer, done: done, later: later)
                opened = nil
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
