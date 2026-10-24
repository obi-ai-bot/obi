import SwiftUI

/// One thing only you can answer (`GET /v1/inbox`), as Sangam's decision block (AskBlock, the
/// shared AskCard): its kind, Oby's headline, what happened, the command or plan, the choices with
/// the recommended one filled, Later, and your own words. Answered here, it goes from the Mac's
/// window too. Shown on a task's card and page, in its conversation, and, with no task on Home, in the Inbox.
struct InboxDecision: View {
    @Environment(\.openURL) private var openURL
    @Environment(Phone.self) private var phone
    let item: InboxItem
    /// A link to the task, when it isn't what's around the block already.
    var openTask = false
    /// A card of its own; off inside a task's card, which is one already.
    var inset = true
    @State private var busy = false
    @State private var problem: String?
    @State private var words = ""

    private var job: Job? { phone.jobs.first { $0.id == item.job } }
    private var permission: RunnerPermission? { item.kind == "permission" ? job?.permission : nil }
    /// A confirm item (obid only, #546): its title is what Confirm does, why it waits under it, the
    /// words it would send quoted apart; Confirm or Cancel, nothing recommended, no words.
    private var confirming: Bool { item.kind == RunnerConfirm.kind }
    private var takesWords: Bool { !item.job.isEmpty && !confirming }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskCard(kind: AskKind.label(item.kind, plan: job?.question?.plan != nil), failed: AskKind.failed(item.kind),
                    source: openTask ? job?.heading : nil,
                    title: confirming ? item.title : item.words.title(item.text),
                    happened: confirming ? InboxWords.plain(item.text) : item.words.body,
                    behindDetails: confirming ? nil : item.words.details(item.text),
                    detail: confirming ? item.confirm?.words : permission?.detail,
                    plan: item.kind == "question" ? job?.question?.plan : nil,
                    options: CardOption.inbox(item.options, kind: item.kind, question: job?.question, permission: permission,
                                              words: item.words, details: item.details, does: item.title),
                    busy: busy || phone.waitsToSend(answer: item.id),
                    onChoose: choose,
                    onLater: { settle(later: .now.addingTimeInterval(3600)) })
            if phone.waitsToSend(answer: item.id) {
                Text(ReachNotice.waiting).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.top, 10)
            } else if takesWords { OwnWords(words: $words, prompt: item.kind == "permission" ? "No, and tell the agent why…" : "Answer in your own words…", busy: busy, send: sendWords) }
            if openTask, !item.job.isEmpty {
                NavigationLink(value: Route.task(item.job)) {
                    Text("Open task").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                }
                .padding(.top, 10)
            }
            if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 8) }
        }
        .modifier(AskInset(on: inset))
    }

    private func choose(_ option: CardOption) {
        if option.answer == "Open the PR", let url = PublishedLink.url(job?.published) { openURL(url); return }
        settle(answer: option.answer)
    }

    /// A permission's words go with a Deny, for the agent; anything else's are the answer.
    private func sendWords(_ text: String) {
        run {
            if let job, permission != nil { try await phone.answer(job, .deny, message: text) } else { try await phone.settle(item.id, answer: text) }
            words = ""
        }
    }

    private func settle(answer: String? = nil, later: Date? = nil) {
        run { try await phone.settle(item.id, answer: answer, later: later) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await work(); problem = nil } catch { problem = error.localizedDescription }
        }
    }
}

/// A job's own question or permission when the runner has no inbox item for it (an older runner):
/// the same block, answered on the job.
struct JobDecision: View {
    @Environment(Phone.self) private var phone
    let job: Job
    var inset = true
    @State private var busy = false
    @State private var problem: String?
    @State private var words = ""

    var body: some View {
        if let permission = job.permission, job.isActive {
            block {
                AskCard(kind: permission.isQuestion ? AskKind.label("agentQuestion") : "Permission", title: permission.title, detail: permission.detail,
                        options: CardOption.permission(permission), busy: busy,
                        onChoose: { option in
                            guard let decision = RunnerPermission.Decision(rawValue: option.answer) else { return }
                            run { try await phone.answer(job, decision) }
                        })
                // On the agent's question (#858) obid takes a Deny with words as its answer.
                OwnWords(words: $words, prompt: permission.isQuestion ? "Answer in your own words…" : "No, and tell the agent why…", busy: busy) { text in run { try await phone.answer(job, .deny, message: text); words = "" } }
            }
            .id(permission.id)
        } else if job.waitsForAnswer, let question = job.question {
            block {
                AskCard(kind: AskKind.label("question", plan: question.plan != nil), title: question.text, plan: question.plan,
                        options: question.cardOptions, busy: busy, onChoose: { option in run { try await phone.tell(job.id, option.answer) } })
                OwnWords(words: $words, prompt: "Answer in your own words…", busy: busy) { text in run { try await phone.tell(job.id, text); words = "" } }
            }
            .id(question.text)
        }
    }

    private func block(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 8) }
        }
        .modifier(AskInset(on: inset))
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await work(); problem = nil } catch { problem = error.localizedDescription }
        }
    }
}

/// Whether a job waits on a decision the page or card can show: an inbox item, else its own.
extension Phone {
    func decision(for job: Job) -> InboxItem? {
        InboxItem.waiting(inbox).first { $0.job == job.id }
    }
}

/// A decision as a card of its own (radius 18, the chip colour), or bare inside another card.
private struct AskInset: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.askRadius, style: .continuous))
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Under a decision: your own words instead of a choice, sent with the arrow.
private struct OwnWords: View {
    @Binding var words: String
    let prompt: String
    let busy: Bool
    let send: (String) -> Void

    private var typed: String? { ChatThread.words(words) }

    var body: some View {
        HStack(spacing: 6) {
            TextField(prompt, text: $words, axis: .vertical)
                .lineLimit(1...4)
                .font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.ink)
                .submitLabel(.send)
                .onSubmit { if let typed { send(typed) } }
            if let typed {
                Button { send(typed) } label: {
                    Image(systemName: "arrow.up").font(Tokens.font(13, .semibold)).foregroundStyle(Tokens.ink)
                        .frame(width: 28, height: 28).background(Tokens.active, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send your answer")
            }
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
        .frame(minHeight: 36)
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Tokens.line) }
        .padding(.top, 12)
        .disabled(busy)
    }
}
