import SwiftUI

/// One job, opened from the window's list: the same screen as the iPhone's (apps/ios/app/JobScreen.swift),
/// in the window's own style. What its agent waits for (a decision card), its stages, the result
/// (Publish after Touch ID, Dismiss for one that needs you), what you asked, its details, what you
/// told the agent, Move to…, Stop, and a line to tell the agent more. A runner's job has a Mode menu too.
struct JobView: View {
    let job: Job
    /// Where it runs: the runner's name, like "tetrix-lab", or "This Mac".
    let place: String
    /// The account's name, when this Mac knows it (its own accounts), else nil and the id shows.
    let account: String?
    let onStop: () -> Void
    /// Nil where this Mac can't publish: a runner's job, on a Mac without Touch ID.
    let publishing: Publishing?
    let onMessage: (String) async throws -> Void
    let onDismiss: () async throws -> Void
    /// Its mode, the permission it waits on and its question with the plan: what the runner says
    /// about its job, or this Mac's own job's (`RunnerJobExtras(local:)`).
    var extras: RunnerJobExtras? = nil
    /// Changes the job's mode, here or on the runner.
    var onMode: ((RunnerMode) async throws -> Void)? = nil
    /// Allow, Always allow or Deny, with words for a deny.
    var onPermission: ((RunnerPermission.Decision, String?) async throws -> Void)? = nil
    /// The job's alert's Publish opened this screen: it shows the sentence and asks for Touch ID now.
    var publishNow = false
    /// Called as that starts, so it starts once.
    var onPublishNow: () -> Void = {}
    /// The accounts where it runs (this Mac's or the runner's), for Move to…, with their usage.
    var accounts: [AccountState] = []
    /// Moves it (Engine/Move.swift); nil for Oby's own reviews, which pick their account themselves.
    var onMove: ((MoveTarget) async throws -> Void)? = nil
    /// Starts it now when it waits for its `startWhen` (#216, Engine/StartWhen.swift); nil where it can't.
    var onStartNow: (() async throws -> Void)? = nil
    /// Lifts an account's weekly reserve, by id, when the job waits for room only reserves hold
    /// back (#278); nil where it can't.
    var onUseAnyway: ((String) async throws -> Void)? = nil
    var readReport: (() async throws -> ResearchDocument)? = nil
    var fileProposal: ((Int, Bool) async throws -> FileProposalResult)? = nil
    @State private var busy = false
    @State private var moving = false
    @State private var problem: String?
    /// The exact sentence Publish would carry out, shown before Touch ID approves it, or nil.
    @State private var action: String?
    @State private var note = ""
    @State private var telling = false
    @State private var noteProblem: String?
    @State private var requestExpanded = false
    @State private var researchReport: ResearchDocument?
    @State private var showingReport = false

    /// Publishing by hand: what it would do, in the words shown and approved (the runner's own,
    /// for its jobs), and doing exactly that, after Touch ID.
    struct Publishing {
        var action: () async throws -> String
        var publish: (String) async throws -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            decision
            pipeline
            result
            if job.report == true {
                Button("Read report", systemImage: "doc.text") {
                    Task {
                        do { researchReport = try await readReport?(); showingReport = researchReport != nil }
                        catch { problem = error.localizedDescription }
                    }
                }
                .buttonStyle(.bordered)
                .sheet(isPresented: $showingReport) {
                    if let researchReport {
                        ReportView(report: researchReport, onFile: fileProposal)
                            .frame(minWidth: 560, minHeight: 520)
                    }
                }
            }
            DisclosureGroup("What you asked", isExpanded: $requestExpanded) {
                ReadingText(job.request).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
            .font(.system(size: 13, weight: .semibold))
            details
            if let notes = job.notes, !notes.isEmpty {
                DisclosureGroup("You told the agent (\(notes.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notes.indices, id: \.self) { index in
                            Label { ReadingText(notes[index]) } icon: { Image(systemName: "text.bubble") }.readingText()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                .font(.system(size: 13, weight: .semibold))
            }
            // Waiting for room while only weekly reserves stand in the way (#278): one tap lifts
            // one until its reset, and the job starts on it.
            if job.waitsToStart, let onUseAnyway {
                ForEach(Usage.liftable(job.waiting?.reserved, among: accounts, id: \.account.id, usage: \.usage), id: \.account.id) { state in
                    VStack(alignment: .leading, spacing: 4) {
                        Button { Task { await run { try await onUseAnyway(state.account.id) } } } label: { pill(Usage.useAnyway(state.usage)) }
                            .buttonStyle(.plain)
                            .disabled(busy)
                        Text(Usage.liftNote(state.usage)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            if moving, let onMove {
                MovePanel(job: job, accounts: accounts, onMove: onMove, onClose: { moving = false; problem = nil })
            } else if job.isActive || onMove != nil {
                HStack(spacing: 10) {
                    if job.waitsToStart, let onStartNow {
                        Button { Task { await run(onStartNow) } } label: { pill("Start now") }
                            .buttonStyle(.plain)
                            .disabled(busy)
                            .help("Start it now instead of waiting")
                    }
                    if onMove != nil {
                        Button { problem = nil; moving = true } label: { pill("Move to…") }
                            .buttonStyle(.plain)
                            .disabled(busy)
                            .help("Move this job to another tool, account or model")
                    }
                    if job.isActive {
                        Button(action: onStop) { pill("Stop job") }
                            .buttonStyle(.plain)
                            .disabled(busy)
                    }
                }
            }
            if let problem, action == nil {
                Text(problem).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
            }
            if job.status == .running || (!job.isActive && job.resumable) {
                composer
            }
        }
        .padding(.horizontal, 4)
        // Not a task tied to publishNow: starting clears it, which would cancel the publish.
        .onChange(of: publishNow, initial: true) { if publishNow { Task { await publishFromNotification() } } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AgentMark(agent: job.agent).font(.system(size: 20, weight: .semibold)).frame(width: 24)
                Text(job.heading).font(.system(size: 19, weight: .semibold)).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 8) {
                StatusPill(badge: job.badge)
                if let verdict = job.verdictLine {
                    Text(verdict).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Elapsed.line(started: job.started ?? job.created, finished: job.finished, now: context.date))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                }
            }
            HStack(spacing: 10) {
                Text("\(job.agentName) · \(account ?? job.account) · \(place)")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                if let onMode, job.isActive, let mode = RunnerMode(extras?.mode) { modeMenu(mode, onMode) }
            }
            if let moved = job.movedLine {
                Label(moved, systemImage: "arrow.left.arrow.right").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    /// Its OK on a command or a file, else the answer to its question or its plan: the runner's
    /// with the recommended option first, this Mac's own jobs' as they ask.
    @ViewBuilder private var decision: some View {
        if let permission = extras?.permission, let onPermission, job.isActive {
            DecisionCard(title: permission.title, detail: permission.detail, options: CardOption.permission(permission),
                         busy: busy, wordsNote: CardOption.wordsNote(permission),
                         onChoose: { option in
                             guard let decision = RunnerPermission.Decision(rawValue: option.answer) else { return }
                             Task { await run { try await onPermission(decision, nil) } }
                         },
                         onWords: { words in Task { await run { try await onPermission(.deny, words) } } })
                .id(permission.id)
                .padding(14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if job.waitsForAnswer, let question = extras?.question ?? job.question.map({ Question(text: $0.text, options: $0.options, recommended: $0.recommended, plan: $0.plan) }) {
            DecisionCard(title: question.text, plan: question.plan, options: question.cardOptions, busy: busy,
                         onChoose: { option in Task { await run { try await onMessage(option.answer) } } },
                         onWords: { words in Task { await run { try await onMessage(words) } } })
                .id(question.text)
                .padding(14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// Ask, Accept edits, Plan or Bypass, while it runs.
    private func modeMenu(_ mode: RunnerMode, _ change: @escaping (RunnerMode) async throws -> Void) -> some View {
        Menu {
            ForEach(RunnerMode.allCases) { choice in
                Button {
                    Task { await run { try await change(choice) } }
                } label: {
                    if choice == mode { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                }
                .help(choice.help)
            }
        } label: {
            Label(mode.label, systemImage: mode.symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 24)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(busy)
        .help("Mode: \(mode.help)")
        .accessibilityLabel("Mode: \(mode.label)")
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
                    ReadingText(job.summary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let sent = job.sentLines {
                    ReadingText(sent, secondary: true).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let commits = job.commits {
                    Label("\(commits) \(commits == 1 ? "commit" : "commits") on \(job.branch)", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
                if let url = PublishedLink.url(job.published) {
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

    /// Oby's own publish failed, or new commits wait: Publish by hand, after Oby shows exactly
    /// what that does (for a runner's job, the runner's sentence, unchanged).
    @ViewBuilder private var publishActions: some View {
        if let reason = job.publishError {
            Text(reason).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(3)
        }
        if publishing == nil {
            HStack(spacing: 10) {
                Text("Publish from your iPhone").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                dismissButton
            }
        } else if let action {
            VStack(alignment: .leading, spacing: 8) {
                ReadingText(action, weight: .medium)
                if let problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
                }
                HStack(spacing: 8) {
                    Button { publish(action) } label: {
                        Label(busy ? "Publishing…" : "Publish with Touch ID", systemImage: "touchid")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 14).frame(height: 30)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    Button { self.action = nil; problem = nil } label: { pill("Not now") }
                        .buttonStyle(.plain)
                        .disabled(busy)
                }
            }
        } else {
            HStack(spacing: 10) {
                Button(action: ask) { pill(job.published == nil ? "Publish" : "Publish the new commits") }
                    .buttonStyle(.plain)
                    .disabled(busy)
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
                    .readingText()
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

    /// What Publish would do, to show before anything goes out.
    private func ask() {
        guard let publishing else { return }
        Task { await run { action = try await publishing.action() } }
    }

    /// Exactly the sentence shown goes to Touch ID and out; a cancel sends nothing.
    private func publish(_ action: String) {
        guard let publishing else { return }
        Task {
            await run {
                try await publishing.publish(action)
                self.action = nil
            }
        }
    }

    /// The alert's Publish, as on the iPhone: the sentence shows, and Touch ID asks with it.
    private func publishFromNotification() async {
        onPublishNow()
        guard let publishing, job.canPublish, !busy else { return }
        await run {
            let action = try await publishing.action()
            self.action = action
            try await publishing.publish(action)
            self.action = nil
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

extension Desk {
    /// The Mode menu of one of this Mac's own jobs (#134), as the runner's does for its jobs.
    func changeMode(_ id: String, to mode: RunnerMode) throws {
        guard let mode = PermissionMode(rawValue: mode.rawValue) else { return }
        try setMode(id, mode)
    }

    /// Allow, Always allow or Deny on what one of this Mac's own jobs waits for; words go with a deny.
    func answerPermission(_ id: String, _ decision: RunnerPermission.Decision, message: String?) throws {
        guard let permission = job(id)?.permission, let decision = PermissionDecision(rawValue: decision.rawValue) else { return }
        try answerPermission(id, permission.id, decision, message: message)
    }
}

/// Move to…: a tool, one of its accounts with its usage, and a model, then what the move will do.
/// The job screen and the window's task page both open it.
struct MovePanel: View {
    let job: Job
    /// The accounts where it runs, with their usage.
    let accounts: [AccountState]
    let onMove: (MoveTarget) async throws -> Void
    let onClose: () -> Void
    @State private var moveAgent: String
    /// Nil: keep its account on the same tool, else the least busy with room.
    @State private var moveAccount: String?
    /// Nil: its model as it is.
    @State private var moveModel: String?
    @State private var busy = false
    @State private var problem: String?

    init(job: Job, accounts: [AccountState], onMove: @escaping (MoveTarget) async throws -> Void, onClose: @escaping () -> Void) {
        self.job = job
        self.accounts = accounts
        self.onMove = onMove
        self.onClose = onClose
        _moveAgent = State(initialValue: job.agent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Move to").font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                ForEach(MoveChoice.tools, id: \.0) { tool in
                    choice(tool.1, selected: moveAgent == tool.0) { moveAgent = tool.0; moveAccount = nil; moveModel = nil }
                }
            }
            Text("Account").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            choice(moveAgent == job.agent ? "Keep its account" : "Least busy with room", selected: moveAccount == nil) { moveAccount = nil }
            ForEach(accounts.filter { $0.account.agent == moveAgent }, id: \.account.id) { state in
                let usage = MoveChoice.usage(signedIn: state.signedIn, fiveHour: state.fiveHour, sevenDay: state.sevenDay)
                choice("\(state.account.name) · \(usage)", selected: moveAccount == state.account.id,
                       warn: MoveChoice.busy(fiveHour: state.fiveHour, sevenDay: state.sevenDay)) { moveAccount = state.account.id }
                    .disabled(!state.signedIn)
            }
            Text("Oby never picks an account past 80% of its 5-hour or weekly limit; one you pick takes the job anyway.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            Text("Model").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 6) {
                choice("As it is", selected: moveModel == nil) { moveModel = nil }
                choice("Settings default", selected: moveModel == Moves.toolDefault) { moveModel = Moves.toolDefault }
            }
            HStack(spacing: 6) {
                ForEach(Moves.models[moveAgent] ?? [], id: \.self) { model in
                    choice(AgentModels.name(model), selected: moveModel == model) { moveModel = model }
                }
            }
            Text(MoveChoice.effect(active: job.isActive, running: job.status == .running))
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(.red).lineLimit(3)
            }
            HStack(spacing: 8) {
                Button(action: move) {
                    Text(busy ? "Moving…" : "Move").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                Button { problem = nil; onClose() } label: { pill("Not now") }
                    .buttonStyle(.plain)
                    .disabled(busy)
            }
        }
        .padding(14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func choice(_ title: String, selected: Bool, warn: Bool = false, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.black : warn ? Color.orange : Color.white)
                .padding(.horizontal, 10).frame(height: 24)
                .background(selected ? Color.white : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move() {
        let target = MoveTarget(agent: moveAgent, account: moveAccount, model: moveModel)
        Task {
            busy = true
            defer { busy = false }
            do {
                try await onMove(target)
                problem = nil
                onClose()
            } catch { problem = error.localizedDescription }
        }
    }

    private func pill(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).frame(height: 24)
            .background(.white.opacity(0.12), in: Capsule())
    }
}
