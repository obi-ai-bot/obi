import SwiftUI

/// One job: its stages, how it ended, Publish with the crown, a word to the agent.
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
                    stages(job)
                    result(job)
                    if let outcome = watch.outcomes[job.id] {
                        Text(outcome).font(.footnote).foregroundStyle(.secondary)
                    }
                    if job.canPublish {
                        Button(job.published == nil ? "Publish…" : "Publish new commits…") {
                            Task { await run { action = try await watch.publishAction(job.id) } }
                        }
                        .tint(.orange).disabled(busy)
                    }
                    if job.status == .running || (!job.isActive && job.session != nil) {
                        TextFieldLink(prompt: Text("Tell the agent…")) {
                            Label("Tell the agent", systemImage: "text.bubble")
                        } onSubmit: { text in
                            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard (1...2000).contains(text.count) else { return }
                            Task { await run { try await watch.tell(job.id, text) } }
                        }
                        .disabled(busy)
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
                if !job.summary.isEmpty { Text(job.summary).font(.footnote) }
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
        ScrollView {
            VStack(spacing: 10) {
                Text(action).font(.footnote).multilineTextAlignment(.center)
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
        }
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
