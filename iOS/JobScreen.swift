import SwiftUI

/// The runner supplies the pipeline; the phone presents it and sends the user's next words.
struct JobScreen: View {
    @Environment(Phone.self) private var phone
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    let id: String
    @State private var action: String?
    @State private var busy = false
    @State private var problem: String?
    @State private var note = ""
    @State private var telling = false
    @State private var noteProblem: String?
    @State private var requestExpanded = false
    /// Asked the runner for a job the list doesn't have (it keeps only the latest 50).
    @State private var looked = false

    private var job: Job? { phone.jobs.first { $0.id == id } }

    var body: some View {
        ScrollView {
            if let job {
                VStack(alignment: .leading, spacing: 24) {
                    header(job)
                    if let pipeline = job.pipeline {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(pipeline.label).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(pipeline.stages) { stage in
                                    StageRow(stage: stage, last: stage.id == pipeline.stages.last?.id)
                                }
                            }
                        }
                    } else if !job.step.isEmpty {
                        Label(job.step, systemImage: "gearshape.2").font(.subheadline)
                    }
                    result(job)
                    DisclosureGroup("What you asked", isExpanded: $requestExpanded) {
                        ReadingText(job.request).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                    details(job)
                    if let notes = job.notes, !notes.isEmpty {
                        DisclosureGroup("You told the agent (\(notes.count))") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(notes.indices, id: \.self) { index in
                                    Label { ReadingText(notes[index]) } icon: { Image(systemName: "text.bubble") }.readingText()
                                }
                            }.padding(.top, 8)
                        }
                    }
                    if job.isActive {
                        Button("Stop job", role: .destructive) {
                            Task { await run { try await phone.stop(job.id) } }
                        }.disabled(busy)
                    }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                }
                .padding(20)
            } else if phone.loaded && looked {
                ContentUnavailableView("This job isn't on the runner any more.", systemImage: "questionmark.folder")
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            if let job, job.status == .running || (!job.isActive && job.session != nil) {
                composer(job).padding(.horizontal).padding(.vertical, 10).background(.bar)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: publishAsked, initial: true) { publishFromNotification() }
        .task(id: id) {
            await phone.fetch(id)
            looked = true
        }
        // While it's open, a new job list keeps this job even when it's older than the latest 50.
        .onAppear { phone.showing(id, true) }
        .onDisappear { phone.showing(id, false) }
    }

    private func header(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.heading).font(.title2.weight(.semibold)).lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack { StatusPill(job: job); elapsed(job) }
                VStack(alignment: .leading, spacing: 8) { StatusPill(job: job); elapsed(job) }
            }
            Text("\(job.agentName) · \(phone.accounts.first { $0.id == job.account }?.name ?? job.account)")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func elapsed(_ job: Job) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Elapsed.line(started: job.started ?? job.created, finished: job.finished, now: context.date))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func result(_ job: Job) -> some View {
        if !job.summary.isEmpty || job.commits != nil || job.published != nil || job.needsYou || job.dismissed != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Result").font(.headline).accessibilityAddTraits(.isHeader)
                if !job.summary.isEmpty { ReadingText(job.summary).textSelection(.enabled) }
                if let sent = job.sentLines { ReadingText(sent, secondary: true).textSelection(.enabled) }
                if let commits = job.commits {
                    Label("\(commits) \(commits == 1 ? "commit" : "commits")", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let url = job.published.flatMap(URL.init(string:)) {
                    Link(destination: url) { Label("Open pull request", systemImage: "arrow.up.right.square") }
                }
                if let error = job.pullRequestError {
                    Label(error, systemImage: "arrow.clockwise").font(.footnote).foregroundStyle(.secondary)
                }
                if job.canPublish {
                    publishActions(job)
                } else if job.needsYou {
                    // Failed or interrupted: nothing to publish, so Dismiss stands alone.
                    dismissButton(job)
                }
                if job.dismissed != nil {
                    Label("Dismissed. Tell the agent something to pick it up again.", systemImage: "xmark.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func details(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details").font(.headline)
            detail("Repository", job.repo)
            detail("Branch", job.branch)
            detail("Base", job.base ?? "Repository default")
            detail("Model", job.model.map(ModelChoice.name) ?? "Account default")
        }
    }

    private func detail(_ name: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(value).fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundStyle(.secondary)
                Text(value)
            }
        }
        .font(.footnote).textSelection(.enabled)
    }

    private func composer(_ job: Job) -> some View {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Tell the agent…", text: $note, axis: .vertical)
                    .lineLimit(1...5).readingText().padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                Button { send(text, to: job.id) } label: {
                    if telling { ProgressView().frame(minWidth: 44, minHeight: 44) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.title).frame(minWidth: 44, minHeight: 44) }
                }
                .disabled(!(1...2000).contains(text.count) || telling)
                .accessibilityLabel("Send to the agent")
            }
            if text.count > 2000 { Text("Keep your message under 2,000 characters.").font(.footnote).foregroundStyle(.red) }
            if let noteProblem { Text(noteProblem).font(.footnote).foregroundStyle(.red) }
        }
    }

    private func send(_ text: String, to id: String) {
        telling = true
        Task {
            defer { telling = false }
            do {
                try await phone.tell(id, text)
                note = ""
                noteProblem = nil
            } catch { noteProblem = error.localizedDescription }
        }
    }

    @ViewBuilder private func publishActions(_ job: Job) -> some View {
        if let action {
            ReadingText(action)
            Button(busy ? "Publishing…" : "Publish with Face ID", systemImage: "faceid") {
                Task {
                    await run {
                        let url = try await phone.publish(job.id, action: action)
                        self.action = nil
                        openURL(url)
                    }
                }
            }.buttonStyle(.borderedProminent).disabled(busy)
            Button("Not now") { self.action = nil }.disabled(busy)
        } else {
            HStack(spacing: 12) {
                Button(job.published == nil ? "Publish…" : "Publish new commits…") {
                    Task { await run { action = try await phone.publishAction(job.id) } }
                }.buttonStyle(.borderedProminent).disabled(busy)
                dismissButton(job)
            }
        }
    }

    /// Lets go of a job that needs you: the runner keeps it, and it stops counting everywhere.
    private func dismissButton(_ job: Job) -> some View {
        Button("Dismiss", systemImage: "xmark.circle") {
            Task { await run { try await phone.dismiss(job.id) } }
        }
        .buttonStyle(.bordered).disabled(busy)
    }

    private var publishAsked: Bool { phone.publishing == id && phone.loaded && scenePhase == .active }

    private func publishFromNotification() {
        guard publishAsked else { return }
        phone.publishing = nil
        guard let job, job.canPublish, !busy else { return }
        Task {
            await run {
                let action = try await phone.publishAction(job.id)
                self.action = action
                let url = try await phone.publish(job.id, action: action)
                self.action = nil
                openURL(url)
            }
        }
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await work(); problem = nil }
        catch { problem = error.localizedDescription }
    }
}

private struct StageRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var markerSize = 24
    let stage: JobStage
    let last: Bool

    private var color: Color {
        switch stage.state {
        case .done: .green
        case .current: .accentColor
        case .failed: .red
        case .upcoming, .skipped: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                marker.frame(width: markerSize, height: markerSize)
                if !last { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 2).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(stage.title).font(.headline)
                    if stage.state == .skipped { Text("Skipped").font(.caption) }
                }
                if let detail = stage.detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                if let reason = stage.reason { Text(reason).font(.subheadline).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, last ? 0 : 20)
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(stage.state == .upcoming || stage.state == .skipped ? Color.secondary : Color.primary)
        .accessibilityElement(children: .combine)
        .accessibilityValue(stage.state.rawValue.capitalized)
    }

    @ViewBuilder private var marker: some View {
        if stage.state == .current && !reduceMotion {
            ProgressView().tint(color).accessibilityHidden(true)
        } else {
            let symbol = switch stage.state {
            case .done: "checkmark.circle.fill"
            case .current: "circle.inset.filled"
            case .upcoming: "circle"
            case .failed: "exclamationmark.circle.fill"
            case .skipped: "minus.circle"
            }
            Image(systemName: symbol).font(.body).foregroundStyle(color).accessibilityHidden(true)
        }
    }
}
