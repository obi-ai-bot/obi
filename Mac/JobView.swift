import SwiftUI

/// One job, opened from the island's list: the same screen as the iPhone's (iOS/JobScreen.swift),
/// in the island's own style. Its stages, the result (Publish after Touch ID for this Mac's own
/// jobs, Dismiss for one that needs you), what you asked, its details, what you told the agent,
/// Stop, and a line to tell the agent more.
struct JobView: View {
    let job: Job
    /// Where it runs: the runner's name, like "tetrix-lab", or "This Mac".
    let place: String
    /// The account's name, when this Mac knows it (its own accounts), else nil and the id shows.
    let account: String?
    let onStop: () -> Void
    /// Nil where this Mac can't publish: a runner's job needs the iPhone's Face ID.
    let onPublish: (() async throws -> Void)?
    let onMessage: (String) async throws -> Void
    let onDismiss: () async throws -> Void
    @State private var busy = false
    @State private var problem: String?
    @State private var confirming = false
    @State private var note = ""
    @State private var telling = false
    @State private var noteProblem: String?
    @State private var requestExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            pipeline
            result
            DisclosureGroup("What you asked", isExpanded: $requestExpanded) {
                Text(job.request).font(.system(size: 13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
            .font(.system(size: 13, weight: .semibold))
            details
            if let notes = job.notes, !notes.isEmpty {
                DisclosureGroup("You told the agent (\(notes.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notes.indices, id: \.self) { index in
                            Label(notes[index], systemImage: "text.bubble").font(.system(size: 13))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                .font(.system(size: 13, weight: .semibold))
            }
            if job.isActive {
                Button(action: onStop) { pill("Stop job") }
                    .buttonStyle(.plain)
                    .disabled(busy)
            }
            if let problem, !confirming {
                Text(problem).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
            }
            if job.status == .running || (!job.isActive && job.session != nil) {
                composer
            }
        }
        .padding(.horizontal, 4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AgentMark(agent: job.agent).font(.system(size: 20, weight: .semibold)).frame(width: 24)
                Text(job.heading).font(.system(size: 19, weight: .semibold)).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 8) {
                StatusBadge(job: job)
                if let verdict = job.verdictLine {
                    Text(verdict).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Elapsed.line(started: job.started ?? job.created, finished: job.finished, now: context.date))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                }
            }
            Text("\(job.agentName) · \(account ?? job.account) · \(place)")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
        }
    }

    /// "Stage 2 of 5" and the stages, as the iPhone's job screen draws them.
    private var pipeline: some View {
        let pipeline = job.pipeline
        return VStack(alignment: .leading, spacing: 10) {
            Text(pipeline.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(pipeline.stages) { stage in
                    StageRow(stage: stage, last: stage.id == pipeline.stages.last?.id)
                }
            }
        }
    }

    @ViewBuilder private var result: some View {
        if !job.summary.isEmpty || job.commits != nil || job.published != nil || job.needsYou || job.dismissed != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Result").font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if !job.summary.isEmpty {
                    Text(job.summary).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let commits = job.commits {
                    Label("\(commits) \(commits == 1 ? "commit" : "commits") on \(job.branch)", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
                if let url = job.published.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        Label("Open pull request", systemImage: "arrow.up.right.square").font(.system(size: 13, weight: .semibold))
                    }
                }
                if let error = job.pullRequestError {
                    Label(error, systemImage: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                if job.canPublish {
                    publishActions
                } else if job.needsYou {
                    // Failed, interrupted or out of reviews: nothing to publish, so Dismiss stands alone.
                    dismissButton
                }
                if job.dismissed != nil {
                    Label("Dismissed. Tell the agent something to pick it up again.", systemImage: "xmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// Oby's own publish failed: Publish by hand, after Oby shows exactly what that does. A
    /// runner's job is published from the iPhone instead.
    @ViewBuilder private var publishActions: some View {
        if let reason = job.publishError {
            Text(reason).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(3)
        }
        if onPublish == nil {
            HStack(spacing: 10) {
                Text("Publish from your iPhone").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                dismissButton
            }
        } else if confirming {
            VStack(alignment: .leading, spacing: 8) {
                Text(Publish.action(for: job, base: job.base ?? "")).font(.system(size: 13, weight: .medium))
                if let problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
                }
                HStack(spacing: 8) {
                    Button(action: publish) {
                        Label(busy ? "Publishing…" : "Publish with Touch ID", systemImage: "touchid")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 14).frame(height: 30)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    Button { confirming = false; problem = nil } label: { pill("Not now") }
                        .buttonStyle(.plain)
                        .disabled(busy)
                }
            }
        } else {
            HStack(spacing: 10) {
                Button { confirming = true } label: { pill(job.published == nil ? "Publish" : "Publish the new commits") }
                    .buttonStyle(.plain)
                dismissButton
            }
        }
    }

    private var dismissButton: some View {
        Button(action: dismiss) { pill("Dismiss") }
            .buttonStyle(.plain)
            .disabled(busy)
            .help("Let this job go: it stays in the list, and stops needing you")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Details").font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
            detail("Repository", job.repo)
            detail("Branch", job.branch)
            detail("Base", job.base ?? "Repository default")
            detail("Model", job.model.map(AgentModels.name) ?? "Account default")
            if job.maxRounds > 1 { detail("Rounds", "Round \(job.currentRound) of \(job.maxRounds)") }
            if let check = job.check { detail("Done when", "\(check) passes") }
        }
    }

    private func detail(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 16)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 13))
        .textSelection(.enabled)
    }

    /// One line for the agent, and why it didn't go if it didn't.
    private var composer: some View {
        let blank = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Tell the agent…", text: $note)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(tell)
                Button(action: tell) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(blank || telling ? 0.4 : 1), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(blank || telling)
                .accessibilityLabel("Send to the agent")
            }
            .padding(.leading, 12).padding(.trailing, 4)
            .frame(height: 32)
            .background(.white.opacity(0.08), in: Capsule())
            if let noteProblem {
                Text(noteProblem).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private func publish() {
        Task {
            await run {
                try await onPublish?()
                confirming = false
            }
        }
    }

    private func dismiss() {
        Task { await run(onDismiss) }
    }

    private func tell() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(text.count), !telling else { return }
        telling = true
        Task {
            defer { telling = false }
            do {
                try await onMessage(text)
                note = ""
                noteProblem = nil
            } catch {
                noteProblem = error.localizedDescription
            }
        }
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func pill(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).frame(height: 24)
            .background(.white.opacity(0.12), in: Capsule())
    }
}

/// The status pill, with the words and colour both apps give the job (`Job.badge`, Shared/Runner.swift).
struct StatusBadge: View {
    let job: Job

    var body: some View {
        let badge = job.badge
        Text(badge.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(badge.tone.color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(badge.tone.color.opacity(0.18), in: Capsule())
    }
}

/// One stage of the pipeline, as the iPhone's job screen draws it: a marker, a line down to the
/// next stage, the title, its detail and, when it failed, why.
private struct StageRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stage: JobStage
    let last: Bool

    private var color: Color {
        switch stage.state {
        case .done: .green
        case .current: .blue
        case .failed: .red
        case .upcoming, .skipped: .white.opacity(0.45)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                marker.frame(width: 20, height: 20)
                if !last { Rectangle().fill(.white.opacity(0.2)).frame(width: 2).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(stage.title).font(.system(size: 14, weight: .semibold))
                    if stage.state == .skipped { Text("Skipped").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)) }
                }
                if let detail = stage.detail { Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)) }
                if let reason = stage.reason { Text(reason).font(.system(size: 12)).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, last ? 0 : 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .opacity(stage.state == .upcoming || stage.state == .skipped ? 0.7 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(stage.state.rawValue.capitalized)
    }

    @ViewBuilder private var marker: some View {
        if stage.state == .current && !reduceMotion {
            ProgressView().controlSize(.small).tint(color).accessibilityHidden(true)
        } else {
            let symbol = switch stage.state {
            case .done: "checkmark.circle.fill"
            case .current: "circle.inset.filled"
            case .upcoming: "circle"
            case .failed: "exclamationmark.circle.fill"
            case .skipped: "minus.circle"
            }
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(color).accessibilityHidden(true)
        }
    }
}
