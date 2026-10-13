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
    @State private var moving = false

    private var job: Job? { phone.jobs.first { $0.id == id } }

    var body: some View {
        ScrollView {
            if let job {
                VStack(alignment: .leading, spacing: 24) {
                    header(job)
                    decision(job)
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
                    // Waiting for room while only weekly reserves stand in the way (#278): one tap
                    // lifts one until its reset, and the job starts on it.
                    if job.waitsToStart {
                        ForEach(Usage.liftable(job.waiting?.reserved, among: phone.accounts, id: \.id, usage: \.usage)) { account in
                            VStack(alignment: .leading, spacing: 4) {
                                Button(Usage.useAnyway(account.usage), systemImage: "lock.open") {
                                    Task { await run { _ = try await phone.runner.liftReserve(account.id, true) } }
                                }.disabled(busy)
                                Text(Usage.liftNote(account.usage)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    // Waiting for its start condition (#216): it can start now instead.
                    if job.waitsToStart {
                        Button("Start now", systemImage: "play.fill") {
                            Task { await run { try await phone.startNow(job.id) } }
                        }.disabled(busy)
                    }
                    // Oby's own reviews pick their account themselves.
                    if job.reviewOf == nil {
                        Button("Move to…", systemImage: "arrow.left.arrow.right") { moving = true }.disabled(busy)
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
            if let job, job.status == .running || (!job.isActive && job.resumable) {
                composer(job).padding(.horizontal).padding(.vertical, 10).background(.bar)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let job, job.isActive, job.mode != nil {
                modeMenu(job)
            }
        }
        .sheet(isPresented: $moving) {
            if let job { MoveSheet(job: job) }
        }
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
                HStack { StatusPill(badge: job.badge); elapsed(job) }
                VStack(alignment: .leading, spacing: 8) { StatusPill(badge: job.badge); elapsed(job) }
            }
            Text("\(job.agentName) · \(phone.accounts.first { $0.id == job.account }?.name ?? job.account)")
                .font(.subheadline).foregroundStyle(.secondary)
            if let moved = job.movedLine {
                Label(moved, systemImage: "arrow.left.arrow.right").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// What the job's agent waits for: its OK on a command or a file, else the answer to its
    /// question or its plan. One tap answers; your own words go too.
    @ViewBuilder private func decision(_ job: Job) -> some View {
        if let permission = job.permission, job.isActive {
            DecisionCard(title: permission.title, detail: permission.detail, options: CardOption.permission(permission),
                         busy: busy, wordsNote: CardOption.denyWords,
                         onChoose: { option in
                             guard let decision = RunnerPermission.Decision(rawValue: option.answer) else { return }
                             Task { await run { try await phone.answer(job, decision) } }
                         },
                         onWords: { words in Task { await run { try await phone.answer(job, .deny, message: words) } } })
                .id(permission.id)
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        } else if let question = job.question, job.waitsForAnswer {
            DecisionCard(title: question.text, plan: question.plan, options: question.cardOptions, busy: busy,
                         onChoose: { option in Task { await run { try await phone.tell(job.id, option.answer) } } },
                         onWords: { words in Task { await run { try await phone.tell(job.id, words) } } })
                .id(question.text)
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    /// Ask, Accept edits, Plan or Bypass, while it runs: a permission the new mode allows is answered.
    private func modeMenu(_ job: Job) -> some View {
        Menu {
            Picker("Mode", selection: Binding {
                RunnerMode(job.mode)
            } set: { mode in
                guard let mode else { return }
                Task { await run { try await phone.setMode(job.id, mode) } }
            }) {
                ForEach(RunnerMode.allCases) { mode in
                    Label {
                        Text(mode.label)
                        Text(mode.help)
                    } icon: {
                        Image(systemName: mode.symbol)
                    }
                    .tag(RunnerMode?.some(mode))
                }
            }
        } label: {
            Label(RunnerMode(job.mode)?.label ?? "Mode", systemImage: RunnerMode(job.mode)?.symbol ?? "hand.raised")
                .labelStyle(.titleAndIcon)
        }
        .disabled(busy)
        .accessibilityLabel("Mode: \(RunnerMode(job.mode)?.label ?? "unknown")")
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

/// "Move to…": a tool, one of its accounts with its usage (or the least busy with room), and a
/// model, then what the move will do, before it runs.
private struct MoveSheet: View {
    @Environment(Phone.self) private var phone
    @Environment(\.dismiss) private var dismiss
    let job: Job
    @State private var agent: String
    /// Nil: the runner keeps the job's own on the same tool, else picks the least busy with room.
    @State private var account: String?
    /// Nil: as it is (the job's own model on the same tool).
    @State private var model: String?
    @State private var options: ModelOptions?
    @State private var busy = false
    @State private var problem: String?

    init(job: Job) {
        self.job = job
        _agent = State(initialValue: job.agent)
    }

    private var models: [(id: String, name: String)] {
        if agent == "claude" { return MoveChoice.claudeModels.map { (id: $0, name: ModelChoice.name($0)) } }
        let listed: [(id: String, name: String)] = options?.codex.models.map { (id: $0.id, name: $0.name) } ?? []
        return listed.isEmpty ? [(id: MoveChoice.codexStrongest, name: ModelChoice.name(MoveChoice.codexStrongest))] : listed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tool") {
                    Picker("Tool", selection: $agent) {
                        ForEach(MoveChoice.tools, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: agent) { account = nil; model = nil }
                }
                Section {
                    row(agent == job.agent ? "Keep its account" : "Least busy with room", detail: agent == job.agent ? nil : "Under 80% of its limits",
                        selected: account == nil) { account = nil }
                    ForEach(phone.accounts.filter { $0.agent == agent }) { item in
                        row(item.name, detail: MoveChoice.usage(signedIn: item.signedIn, fiveHour: item.fiveHour, sevenDay: item.sevenDay),
                            warn: MoveChoice.busy(fiveHour: item.fiveHour, sevenDay: item.sevenDay), selected: account == item.id) { account = item.id }
                            .disabled(!item.signedIn)
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Oby never picks an account past 80% of its 5-hour or weekly limit; one you pick takes the job anyway.")
                }
                Section("Model") {
                    row("As it is", detail: job.model.map(ModelChoice.name), selected: model == nil) { model = nil }
                    row("Settings default", detail: nil, selected: model == MoveChoice.toolDefault) { model = MoveChoice.toolDefault }
                    ForEach(models, id: \.id) { choice in
                        row(choice.name, detail: nil, selected: model == choice.id) { model = choice.id }
                    }
                }
                Section {
                    Text(MoveChoice.effect(active: job.isActive, running: job.status == .running)).font(.footnote)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Move \(job.heading)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Moving…" : "Move") { move() }.disabled(busy)
                }
            }
            .task { options = try? await phone.runner.modelOptions() }
        }
    }

    private func row(_ title: String, detail: String?, warn: Bool = false, selected: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(warn ? Color.orange : Color.secondary) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await phone.move(job.id, agent: agent, account: account, model: model)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
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
