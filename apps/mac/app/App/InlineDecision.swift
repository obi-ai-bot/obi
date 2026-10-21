import SwiftUI

/// Answers stay pending until the desk/runner confirms them. The shared inbox record is the receipt,
/// including when another device answered; no optimistic result is stored in the view.
struct InlineDecision: View {
    let entry: IslandInbox.Entry
    let desk: Desk
    let feed: RunnerFeed
    var keyboardEnabled = false
    var focusRequest = 0
    var onOpen: (_ job: String, _ local: Bool) -> Void = { _, _ in }
    var onTell: (() -> Void)? = nil
    @State private var expanded = false
    @State private var busy = false
    @State private var problem: String?
    @State private var questionSnapshot: Question?
    @State private var permissionSnapshot: RunnerPermission?

    private var item: InboxItem { entry.item }
    private var settled: Bool { item.done != nil }
    private var words: InboxWords {
        entry.local ? InboxWords(headline: item.headline, happened: item.happened, recommended: item.recommended, why: item.why)
            : feed.inboxWords[item.id] ?? InboxWords()
    }
    private var extras: RunnerJobExtras? { entry.local ? nil : feed.extras[item.job] }
    /// Its kind as the runner names it: Engine reads a `confirm` item (#546) as a `start`.
    private var kind: String { entry.local ? "\(item.kind)" : item.shownKind(words) }
    /// A confirm item: its title is what Confirm does, the words it would send are quoted apart,
    /// and it takes Confirm or Cancel, nothing recommended, no words of the user's own.
    private var confirming: Bool { kind == RunnerConfirm.kind }

    private var livePermission: RunnerPermission? {
        guard item.kind == .permission else { return nil }
        if entry.local, let permission = desk.jobs.first(where: { $0.id == item.job })?.permission {
            return RunnerPermission(id: permission.id, tool: permission.tool, title: permission.title,
                                    detail: permission.detail, rule: permission.rule, always: permission.always)
        }
        return extras?.permission
    }
    private var permission: RunnerPermission? { livePermission ?? permissionSnapshot }

    private var liveQuestion: Question? {
        extras?.question ?? desk.jobs.first { entry.local && $0.id == item.job }?.question.map {
            Question(text: $0.text, options: $0.options, details: $0.details, recommended: $0.recommended)
        }
    }

    private var question: Question? { liveQuestion ?? questionSnapshot }
    static func receipt(_ item: InboxItem, permission: RunnerPermission? = nil) -> String? {
        guard let done = item.done, let answer = InboxWords.plain(item.answer) else { return nil }
        if item.kind == .permission {
            let subject = InboxWords.plain(permission?.detail) ?? permission?.title ?? item.text
            let choice: String = switch Inbox.decision(answer).0 {
            case .allow: "Allowed once"
            case .always: "Always allowed"
            case .deny: "Denied"
            }
            return "\(choice): \(subject) · \(ConversationModel.clock(done))"
        }
        return "You chose: \(answer) · \(ConversationModel.clock(done))"
    }

    @ViewBuilder var body: some View {
        if !settled || Self.receipt(item, permission: permission) != nil { card }
    }

    /// Sangam's decision in a conversation: a card of its own, its kind over Oby's headline, what
    /// happened, the command or plan it's about, the choices; answered, one line that opens it again.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let receipt = Self.receipt(item, permission: permission) {
                Receipt(text: receipt, expanded: $expanded)
            }
            if !settled || expanded {
                AskCard(kind: AskKind.label(kind, plan: question?.plan != nil), failed: AskKind.failed(kind),
                        source: confirming ? feed.jobs.first { $0.id == item.job }?.shortTitle : item.title,
                        title: confirming ? item.title : words.title(item.text),
                        happened: confirming ? InboxWords.plain(item.text) : words.body,
                        behindDetails: confirming ? nil : words.details(item.text),
                        detail: confirming ? words.confirm?.words : permission?.detail, plan: question?.plan,
                        options: CardOption.inbox(item.options, kind: kind, question: question,
                                                  permission: permission, words: words, details: item.details, does: item.title),
                        busy: busy || settled, answered: settled, keyboardEnabled: keyboardEnabled && !settled, focusRequest: focusRequest,
                        hint: !settled && item.kind.takesWords && onTell != nil
                            ? (item.kind == .permission ? "No, and tell the agent what to do differently" : "Answer in your own words…") : nil,
                        onHint: item.kind.takesWords ? onTell : nil,
                        onChoose: { answer($0.answer) },
                        onLater: settled ? nil : { answer(later: .now.addingTimeInterval(3600)) },
                        onOpen: item.job.isEmpty ? nil : { onOpen(item.job, entry.local) })
                    .padding(.top, settled ? 12 : 0)
            }
            if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 8) }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.askRadius, style: .continuous))
        .onChange(of: livePermission, initial: true) {
            if !settled, let livePermission { permissionSnapshot = livePermission }
        }
        .onChange(of: liveQuestion, initial: true) {
            if !settled, let liveQuestion { questionSnapshot = liveQuestion }
        }
    }

    private func answer(_ value: String? = nil, later: Date? = nil) {
        guard !busy, !settled else { return }
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do {
                if entry.local {
                    try await desk.answer(item.id, value.map { .answer($0) } ?? .later(later ?? .now))
                } else {
                    try await feed.settle(item.id, answer: value, later: later)
                }
            } catch { problem = error.localizedDescription }
        }
    }
}

/// An answered decision, as it stays in the conversation: a check and what was chosen, when; a
/// click opens the card again.
struct Receipt: View {
    let text: String
    @Binding var expanded: Bool

    var body: some View {
        Button { withAnimation(Tokens.warm) { expanded.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(Tokens.font(11, .semibold))
                Text(text).font(Tokens.font(Tokens.textMd)).fadeOut()
                Image(systemName: "chevron.down").font(Tokens.font(9, .semibold)).rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .foregroundStyle(Tokens.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

/// A watcher's or the channel listener's item (`watch`, `listen`) as a decision in the
/// conversation, tagged with where it came from (Slack or GitHub's mark, as Sangam's sourced work):
/// obid's own title and text, a finished review shown whole before Approve, the item's choices and
/// Later, and its link opened only on a click.
struct InlineNotice: View {
    let notice: WatchNotice
    let feed: RunnerFeed
    var keyboardEnabled = false
    var focusRequest = 0
    /// Opens a job's page: a review the item can't show offers its job ("Open the job to read it").
    var onOpen: (_ job: String) -> Void = { _ in }
    @Environment(\.openURL) private var openURL
    @State private var busy = false
    @State private var problem: String?

    /// Slack's or GitHub's mark, by where obid says it came from (`watch.source`).
    static func brand(_ notice: WatchNotice) -> String {
        notice.source == "github" ? "github" : "slack"
    }

    /// Whether it offers its job's page: a review it doesn't show (flagged, empty, unscanned).
    static func opensJob(_ notice: WatchNotice) -> Bool {
        !notice.job.isEmpty && notice.review == nil
    }

    /// Its choices: Approve says what it posts.
    static func options(_ notice: WatchNotice) -> [CardOption] {
        notice.options.map { option in
            CardOption(label: option, answer: option,
                       detail: option == "Approve" ? "Posts the review above on the pull request, as a comment from your GitHub login." : nil)
        }
    }

    var body: some View {
        let brand = Self.brand(notice)
        VStack(alignment: .leading, spacing: 0) {
            AskCard(kind: brand == "github" ? "GitHub" : "Slack", brand: brand,
                    shown: notice.review, title: notice.title, happened: notice.text,
                    options: Self.options(notice), busy: busy, keyboardEnabled: keyboardEnabled, focusRequest: focusRequest,
                    hint: notice.url.map { _ in brand == "github" ? "Open on GitHub" : "Open in Slack" },
                    onHint: notice.url.map { url in { openURL(url) } },
                    onChoose: { settle(answer: $0.answer) },
                    onLater: { settle(later: .now.addingTimeInterval(3600)) },
                    onOpen: Self.opensJob(notice) ? { onOpen(notice.job) } : nil)
            if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 8) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.askRadius, style: .continuous))
    }

    private func settle(answer: String? = nil, later: Date? = nil) {
        guard !busy else { return }
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do { try await feed.settle(notice: notice.id, answer: answer, later: later) } catch { problem = error.localizedDescription }
        }
    }
}
