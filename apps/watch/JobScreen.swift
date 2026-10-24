import SwiftUI

/// One job: what its agent waits for (a decision card), its stages, how it ended, Publish with
/// the crown, a word to the agent.
struct JobScreen: View {
    @Environment(Watch.self) private var watch
    let id: String
    /// The sentence publishing would carry out, while the crown confirm is up.
    @State private var action: String?
    @State private var busy = false
    @State private var problem: String?

    private var job: Job? { watch.jobs.first { $0.id == id } }

    var body: some View {
        ScrollView {
            if let job {
                VStack(alignment: .leading, spacing: 10) {
                    Text(job.heading).font(.headline).accessibilityAddTraits(.isHeader)
                    let (status, color) = JobStatus.of(job)
                    Text(status).font(.caption.weight(.semibold)).foregroundStyle(color)
                    if let moved = job.movedLine { Text(moved).font(.caption2).foregroundStyle(.secondary) }
                    decision(job)
                    stages(job)
                    result(job)
                    if let outcome = watch.outcomes[job.id] {
                        ReadingText(outcome, secondary: true)
                    }
                    if job.canPublish {
                        Button(job.published == nil ? "Publish…" : "Publish new commits…") {
                            Task { await run { action = try await watch.publishAction(job.id) } }
                        }
                        .tint(.orange).disabled(busy)
                    }
                    if job.status == .running || (!job.isActive && job.resumable) {
                        TextFieldLink(prompt: Text("Tell the agent…")) {
                            Label("Tell the agent", systemImage: "text.bubble")
                        } onSubmit: { text in
                            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard (1...2000).contains(text.count) else { return }
                            Task { await run { try await watch.tell(job.id, text) } }
                        }
                        .disabled(busy)
                    }
                    // Waiting for its start condition (#216): it can start now instead.
                    if job.waitsToStart {
                        Button("Start now") {
                            Task { await run { try await watch.startNow(job.id) } }
                        }.disabled(busy)
                    }
                    // Oby's own reviews pick their account themselves.
                    if job.reviewOf == nil {
                        NavigationLink("Move to…") { MoveList(job: job) }.disabled(busy)
                    }
                    if job.needsYou {
                        Button("Dismiss") {
                            Task { await run { try await watch.dismiss(job.id) } }
                        }.disabled(busy)
                    }
                    if job.isActive {
                        Button("Stop job", role: .destructive) {
                            Task { await run { try await watch.stop(job.id) } }
                        }.disabled(busy)
                    }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                }
            } else if watch.loaded {
                Text("This job isn't on the runner any more.").font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .sheet(isPresented: Binding { action != nil } set: { if !$0 { action = nil } }) {
            if let action {
                CrownConfirm(action: action) {
                    self.action = nil
                    Task { await run { try await watch.publish(id, action: action) } }
                }
            }
        }
        .onChange(of: publishAsked, initial: true) { publishFromNotification() }
    }

    /// Its OK on a command or a file, else the answer to its question or its plan: options as
    /// buttons, the recommended one first, and dictation for your own answer.
    @ViewBuilder private func decision(_ job: Job) -> some View {
        if let permission = job.permission, job.isActive {
            DecisionCard(title: permission.title, detail: permission.detail, options: CardOption.permission(permission),
                         busy: busy, wordsNote: CardOption.wordsNote(permission),
                         onChoose: { option in
                             guard let decision = RunnerPermission.Decision(rawValue: option.answer) else { return }
                             Task { await run { try await watch.answer(job, decision) } }
                         },
                         onWords: { words in Task { await run { try await watch.answer(job, .deny, message: words) } } })
                .id(permission.id)
        } else if let question = job.question, job.waitsForAnswer {
            DecisionCard(title: question.text, plan: question.plan, options: question.cardOptions, busy: busy,
                         onChoose: { option in Task { await run { try await watch.tell(job.id, option.answer) } } },
                         onWords: { words in Task { await run { try await watch.tell(job.id, words) } } })
                .id(question.text)
        }
    }

    @ViewBuilder private func stages(_ job: Job) -> some View {
        if let pipeline = job.pipeline {
            Text(pipeline.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(pipeline.stages) { StageRow(stage: $0) }
        } else if !job.step.isEmpty {
            Label(job.step, systemImage: "gearshape.2").font(.footnote)
        }
    }

    @ViewBuilder private func result(_ job: Job) -> some View {
        if !job.summary.isEmpty || job.commits != nil || job.published != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("Result").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if !job.summary.isEmpty { ReadingText(job.summary) }
                if let commits = job.commits {
                    Text("\(commits) \(commits == 1 ? "commit" : "commits")").font(.caption2).foregroundStyle(.secondary)
                }
                if job.published != nil {
                    Label("Pull request open", systemImage: "arrow.up.right.square").font(.caption2).foregroundStyle(.secondary)
                }
                if let error = job.publishError {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.top, 4)
        }
    }

    private var publishAsked: Bool { watch.publishing == id && watch.loaded }

    /// Publish on the notification: the crown confirm comes up with the action, once it's known.
    private func publishFromNotification() {
        guard publishAsked else { return }
        watch.publishing = nil
        guard let job, job.canPublish, !busy else { return }
        Task { await run { action = try await watch.publishAction(job.id) } }
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await work(); problem = nil }
        catch { problem = error.localizedDescription }
    }
}

/// "Move to…" on the Watch: a tool (Oby picks its least busy account with room), an account with
/// its usage, or a model. What the move does is said first; a tap moves it.
private struct MoveList: View {
    @Environment(Watch.self) private var watch
    @Environment(\.dismiss) private var dismiss
    let job: Job
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        List {
            Section {
                Text(MoveChoice.effect(active: job.isActive, running: job.status == .running)).font(.caption2).foregroundStyle(.secondary)
                if let problem { Text(problem).font(.caption2).foregroundStyle(.red) }
            }
            Section("Tools") {
                ForEach(MoveChoice.tools, id: \.0) { tool in
                    Button(tool.1) { move(agent: tool.0) }.disabled(busy || tool.0 == job.agent)
                }
            }
            Section("Accounts") {
                ForEach(watch.accounts) { account in
                    Button { move(account: account.id) } label: {
                        VStack(alignment: .leading) {
                            Text(account.title)
                            Text(MoveChoice.usage(signedIn: account.signedIn, fiveHour: account.fiveHour, sevenDay: account.sevenDay))
                                .font(.caption2)
                                .foregroundStyle(MoveChoice.busy(fiveHour: account.fiveHour, sevenDay: account.sevenDay) ? Color.orange : Color.secondary)
                        }
                    }
                    .disabled(busy || !account.signedIn || account.id == job.account)
                }
            }
            Section("Models") {
                ForEach(MoveChoice.claudeModels + [MoveChoice.codexStrongest], id: \.self) { model in
                    Button(ModelChoice.name(model)) { move(model: model) }.disabled(busy || model == job.model)
                }
            }
        }
        .navigationTitle("Move to")
    }

    private func move(agent: String? = nil, account: String? = nil, model: String? = nil) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await watch.move(job.id, agent: agent, account: account, model: model)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

private struct StageRow: View {
    let stage: JobStage

    private var color: Color {
        switch stage.state {
        case .done: .green
        case .current: .accentColor
        case .failed: .red
        case .upcoming, .skipped: .secondary
        }
    }

    private var symbol: String {
        switch stage.state {
        case .done: "checkmark.circle.fill"
        case .current: "circle.inset.filled"
        case .upcoming: "circle"
        case .failed: "exclamationmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.title).font(.footnote.weight(.semibold))
                if let detail = stage.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                if let reason = stage.reason { Text(reason).font(.caption2).foregroundStyle(.red) }
            }
        }
        .foregroundStyle(stage.state == .upcoming || stage.state == .skipped ? Color.secondary : Color.primary)
        .accessibilityElement(children: .combine)
        .accessibilityValue(stage.state.rawValue.capitalized)
    }
}

/// Publish, confirmed by turning the Digital Crown: the ring fills as it turns, and a full turn
/// publishes. A tap can't do it by mistake.
struct CrownConfirm: View {
    let action: String
    let confirm: () -> Void
    @State private var turn = 0.0
    @State private var fired = false
    @FocusState private var focused: Bool

    var body: some View {
        // No scroll view here: the crown belongs to the ring, not to scrolling.
        VStack(spacing: 10) {
            Text(action).font(.footnote).multilineTextAlignment(.center).lineLimit(4).minimumScaleFactor(0.7)
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 8)
                Circle().trim(from: 0, to: min(turn, 1))
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: fired ? "checkmark" : "digitalcrown.arrow.clockwise")
                    .font(.title3.weight(.semibold))
            }
            .frame(width: 72, height: 72)
            .animation(.easeOut(duration: 0.1), value: turn)
            Text(fired ? "Publishing…" : "Turn the crown to publish")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .focusable()
        .focused($focused)
        .digitalCrownRotation($turn, from: 0, through: 1, by: 0.02, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: turn) {
            guard turn >= 1, !fired else { return }
            fired = true
            confirm()
        }
        .onAppear { focused = true }
    }
}
