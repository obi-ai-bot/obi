import SwiftUI

/// A task as a card in its kind's page (Sangam's TaskCard.tsx, the Mac's TaskCardView): its
/// agent's mark, its title and how long it's been going; its agent, account and repository; then
/// what's happening now: the live step while it runs, the decision while it needs you, what it
/// left behind once done; and its stages as a thin bar along the foot. A tap anywhere but its
/// buttons opens its page.
struct TaskCard: View {
    @Environment(Phone.self) private var phone
    @Environment(\.push) private var push
    let item: WorkList.Item<Job>
    /// What a ⋮ action held on the card is doing, and why it didn't go.
    @State private var busy = false
    @State private var problem: String?

    private var job: Job { item.job }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                AgentMark(agent: job.agent).font(Tokens.font(13, .semibold)).frame(width: 16).foregroundStyle(Tokens.muted)
                Text(job.heading).font(Tokens.font(Tokens.textLg, .semibold)).foregroundStyle(Tokens.ink).lineLimit(2)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(TaskFacts.ago(job, now: context.date)).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
                }
            }
            // New (blue) or needs you (orange): its dot in the card's margin, level with the title.
            .overlay(alignment: .topLeading) {
                if item.mark == .new || item.mark == .needs { WorkMarkView(mark: item.mark).offset(x: -16, y: 3) }
            }
            Text(TaskMeta.line(job, account: phone.accountName(job.account))).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted)
                .lineLimit(1).padding(.leading, 26).padding(.top, 4)
            switch item.status {
            case .running:
                HStack(spacing: 10) {
                    if job.status == .queued {
                        Text(job.line).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).lineLimit(1)
                    } else {
                        Sheen(text: job.line.isEmpty ? "Working" : job.line)
                    }
                    Spacer(minLength: 0)
                    if job.maxRounds > 1 {
                        Text("Round \(job.currentRound) of \(job.maxRounds)").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                    }
                }
                .padding(.top, 14)
            case .needs:
                VStack(alignment: .leading, spacing: 0) {
                    if let item = phone.decision(for: job) {
                        InboxDecision(item: item, inset: false)
                    } else if (job.permission != nil && job.isActive) || job.waitsForAnswer {
                        JobDecision(job: job, inset: false)
                    } else {
                        Text(job.badge.text).font(Tokens.font(Tokens.textSm, .medium))
                            .foregroundStyle(job.badge.tone == .red ? Tokens.danger : Tokens.needs)
                        Text(job.line).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).padding(.top, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 14)
                .overlay(alignment: .top) { Tokens.divider.frame(height: 1) }
                .padding(.top, 16)
            case .done:
                if let line = TaskFacts.resultLine(job) {
                    HStack(spacing: 8) {
                        Text(line).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                        if let url = job.published.flatMap(URL.init(string:)) {
                            Link("Open PR", destination: url).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.link)
                        }
                    }
                    .padding(.top, 12)
                }
            }
            if item.status != .done { StageBar(job: job, needs: item.status == .needs).padding(.top, 16) }
            if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 10) }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
        .onTapGesture { push(.task(job.id)) }
        .contextMenu {
            Button("View details", systemImage: "info.circle") { push(.task(job.id)) }
            TaskMenuItems(job: job, items: TaskMenu.items(job, conversation: phone.conversation(of: job) != nil).filter { $0 != .move && $0 != .mode },
                          busy: $busy, onProblem: { problem = $0 })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.heading), \(item.mark.rawValue)")
        .accessibilityAction(named: "Open") { push(.task(job.id)) }
    }
}

/// A task's ⋮ (Sangam's TaskMenu.tsx, docs/oby-ux.md row 21): its conversation; Stop task while it
/// goes, Archive task once it's done (Dismiss instead while it needs you); then the iPhone's Move
/// to… and Mode. His Rename and Delete task wait for obid, which can't rename or delete a job yet.
nonisolated enum TaskMenu {
    enum Item: Equatable { case openConversation, stop, archive, dismiss, move, mode }

    static func items(_ job: Job, conversation: Bool) -> [Item] {
        var items: [Item] = conversation ? [.openConversation] : []
        items.append(job.isActive ? .stop : job.needsYou || job.canPublish ? .dismiss : .archive)
        // Oby's own reviews pick their account themselves.
        if job.reviewOf == nil { items.append(.move) }
        if job.isActive, job.mode != nil { items.append(.mode) }
        return items
    }
}

/// The ⋮'s buttons, on the task's page and held on its card. Move to… and Mode are the page's own.
struct TaskMenuItems: View {
    @Environment(Phone.self) private var phone
    @Environment(\.push) private var push
    let job: Job
    let items: [TaskMenu.Item]
    var onMove: () -> Void = {}
    /// An action under way: the items wait for it.
    var busy: Binding<Bool> = .constant(false)
    var onProblem: (String?) -> Void = { _ in }

    var body: some View {
        ForEach(items, id: \.self) { item in
            switch item {
            case .openConversation:
                if let conversation = phone.conversation(of: job) {
                    Button("Open conversation", systemImage: "bubble.left.and.bubble.right") { push(.conversation(conversation)) }
                }
            case .stop: Button("Stop task", systemImage: "stop", role: .destructive) { run { try await phone.stop(job.id) } }.disabled(busy.wrappedValue)
            case .archive: Button("Archive task", systemImage: "archivebox") { phone.archive(job.id) }
            case .dismiss: Button("Dismiss", systemImage: "xmark") { run { try await phone.dismiss(job.id) } }.disabled(busy.wrappedValue)
            case .move: Button("Move to…", systemImage: "arrow.left.arrow.right", action: onMove)
            case .mode:
                let mode = RunnerMode(job.mode)
                Picker(selection: Binding { mode } set: { choice in if let choice { run { try await phone.setMode(job.id, choice) } } }) {
                    ForEach(RunnerMode.allCases) { Label($0.label, systemImage: $0.symbol).tag(Optional($0)) }
                } label: {
                    Label("Mode: \(mode?.label ?? "unknown")", systemImage: mode?.symbol ?? "hand.raised")
                }
                .pickerStyle(.menu)
                .disabled(busy.wrappedValue)
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy.wrappedValue = true
        Task {
            defer { busy.wrappedValue = false }
            do { try await work(); onProblem(nil) } catch { onProblem(error.localizedDescription) }
        }
    }
}

/// What a task's cards say under the title: its agent, account and repository.
nonisolated enum TaskMeta {
    static func line(_ job: Job, account: String) -> String {
        [job.agentName, account, job.repoName].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension Phone {
    /// An account's name as the runner knows it, else its id.
    func accountName(_ id: String) -> String { accounts.first { $0.id == id }?.name ?? id }
}

/// The stages as one thin bar of segments: done and current lit (current pulsing while it works,
/// orange while the task needs you), failed in red, the rest dim.
struct StageBar: View {
    let job: Job
    let needs: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let pipeline = job.pipeline, !pipeline.stages.isEmpty {
            HStack(spacing: 3) {
                ForEach(pipeline.stages) { stage in
                    Group {
                        if stage.state == .current && !needs && job.status == .running && !reduceMotion {
                            PhaseAnimator([1.0, 0.35]) { level in Capsule().fill(Tokens.stageDone).opacity(level) }
                                animation: { _ in .easeInOut(duration: 0.8) }
                        } else {
                            Capsule().fill(color(stage.state))
                        }
                    }
                    .frame(height: 3)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(pipeline.label)
        }
    }

    private func color(_ state: JobStage.State) -> Color {
        switch state {
        case .done: Tokens.stageDone
        case .current: needs ? Tokens.needs : Tokens.stageDone
        case .failed: Tokens.danger
        case .upcoming, .skipped: Tokens.pill
        }
    }
}

/// One task on its own page (Sangam's TaskView.tsx, the Mac's TaskPage): its title, agent and
/// account; the decision, when there is one, a card of its own; then one card with Result, Stages,
/// Details and what you asked, a line between each; what it can still do under it; and at the
/// foot the box to tell Oby about it.
struct TaskPage: View {
    @Environment(Phone.self) private var phone
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.push) private var push
    let id: String
    @State private var action: String?
    @State private var busy = false
    @State private var problem: String?
    @State private var note = ""
    @FocusState private var typing: Bool
    @State private var noteProblem: String?
    /// Asked the runner for a job the list doesn't have (it keeps only the latest 50).
    @State private var looked = false
    @State private var moving = false
    @State private var researchReport: ResearchDocument?
    @State private var showingReport = false

    private var job: Job? { phone.jobs.first { $0.id == id } }

    var body: some View {
        ScrollView {
            if let job {
                VStack(alignment: .leading, spacing: 0) {
                    header(job)
                    if let item = phone.decision(for: job) {
                        InboxDecision(item: item).padding(.bottom, 8)
                    } else {
                        JobDecision(job: job).padding(.bottom, 8)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        let hasResult = TaskFacts.hasResult(job)
                        if hasResult { section("Result", first: true) { result(job) } }
                        if let pipeline = job.pipeline {
                            section("Stages · \(pipeline.label)", first: !hasResult) { StageList(job: job, stages: pipeline.stages) }
                        } else if !job.step.isEmpty {
                            section("Now", first: !hasResult) { Text(job.step).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text) }
                        }
                        section("Details") { details(job) }
                        section("What you asked") {
                            Text(job.request).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text).lineSpacing(6)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if let notes = job.notes, !notes.isEmpty {
                                Text("You told the agent").font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.label).padding(.top, 14)
                                ForEach(notes.indices, id: \.self) { index in
                                    Text(notes[index]).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text).padding(.top, 6)
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        let followUps = ThreadTaskLine.followUps(of: job.id, in: phone.jobs)
                        if !followUps.isEmpty { section("Follow-ups") { followUpList(followUps) } }
                    }
                    .padding(.horizontal, 18)
                    .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
                    controls(job).padding(.top, 14)
                    if let problem, action == nil {
                        Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 10)
                    }
                }
                .padding(.horizontal, Tokens.gutter).padding(.top, 8).padding(.bottom, 24)
            } else if phone.loaded && looked {
                ContentUnavailableView("This task isn't on the runner any more.", systemImage: "questionmark.folder")
                    .foregroundStyle(Tokens.text).padding(.top, 80)
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Tokens.bg)
        .safeAreaInset(edge: .bottom) {
            // Every task but Oby's own reviews takes words. Not gated on its session: obid's
            // gateway leaves `session` out on purpose, and the runner picks it up itself.
            if let job, job.reviewOf == nil {
                VStack(alignment: .leading, spacing: 6) {
                    // The agent's live line (docs/ios-design.md, "A task's thread"): while your words
                    // wait for its next turn, obid's step reads "You: …".
                    if let line = job.agentLine {
                        HStack(spacing: 8) {
                            WorkMarkView(mark: .working, dot: 6)
                            Sheen(text: line, size: Tokens.textMd).lineLimit(1)
                            Spacer(minLength: 8)
                            if job.maxRounds > 1 {
                                Text("Round \(job.currentRound) of \(job.maxRounds)").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                            }
                        }
                        .padding(.horizontal, Tokens.gutter + 4)
                    }
                    if let noteProblem {
                        Text(noteProblem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.horizontal, Tokens.gutter + 12)
                    }
                    Composer(text: $note, prompt: job.isActive ? "Tell \(job.agentName)…" : "Ask for a follow-up…", typing: $typing) { _ in tell(job.id) }
                        .disabled(busy)
                        .keepsDraft($note, as: Drafts.task(job.id))
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let job {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        TaskMenuItems(job: job, items: TaskMenu.items(job, conversation: phone.conversation(of: job) != nil),
                                      onMove: { problem = nil; moving = true }, busy: $busy, onProblem: { problem = $0 })
                    } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("Task options")
                }
            }
        }
        .sheet(isPresented: $moving) {
            if let job { MoveSheet(job: job) }
        }
        .sheet(isPresented: $showingReport) {
            if let researchReport {
                NavigationStack {
                    ReportView(report: researchReport) { index, start in
                        try await phone.runner.fileProposal(id, index: index, start: start)
                    }
                    .navigationTitle("Research report")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .onChange(of: publishAsked, initial: true) { publishFromNotification() }
        .task(id: id) {
            await phone.fetch(id)
            looked = true
        }
        // While it's open, a new job list keeps this job even when it's older than the latest 50.
        .onAppear { phone.showing(id, true); phone.markSeen(id) }
        .onDisappear { phone.showing(id, false); phone.cancelVoice() }
    }

    private func header(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(job.heading).font(Tokens.font(22, .semibold)).foregroundStyle(Tokens.ink).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Elapsed.line(started: job.started ?? job.created, finished: job.finished, now: context.date))
                        .font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
                }
            }
            HStack(spacing: 8) {
                AgentMark(agent: job.agent).font(Tokens.font(12, .semibold)).foregroundStyle(Tokens.muted)
                Text(TaskMeta.line(job, account: phone.accountName(job.account))).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted)
                    .lineLimit(1)
                Text(job.badge.text).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(tone(job.badge.tone))
            }
            if let verdict = job.verdictLine { Text(verdict).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted) }
            if let moved = job.movedLine { Text(moved).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted) }
        }
        .padding(.bottom, 16)
    }

    private func tone(_ tone: JobBadge.Tone) -> Color {
        switch tone {
        case .orange: Tokens.needs
        case .red: Tokens.danger
        case .green: Tokens.done
        case .blue: Tokens.unread
        case .gray: Tokens.muted
        }
    }

    /// What the agent reported, what it left behind, and Publish or Read report.
    @ViewBuilder private func result(_ job: Job) -> some View {
        if !job.summary.isEmpty {
            // Its `code` and links set apart, as in the conversation.
            Text(SaidText.styled(job.summary)).font(Tokens.font(16, .medium)).foregroundStyle(Tokens.ink).lineSpacing(6)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if let sent = job.sentLines {
            Text(sent).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).padding(.top, 8).textSelection(.enabled)
        }
        if let line = TaskFacts.resultLine(job) {
            Text(line).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.top, 8)
        } else if let commits = job.commits, commits > 0 {
            Text("\(commits) commit\(commits == 1 ? "" : "s") on \(job.branch)").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.top, 8)
        }
        if let url = job.published.flatMap(URL.init(string:)) {
            Link("Open pull request", destination: url).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.link).padding(.top, 6)
        }
        if let error = job.pullRequestError { Text(error).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.top, 6) }
        if job.dismissed != nil {
            Text("Dismissed. Tell the agent something to pick it up again.").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.top, 6)
        }
        if job.canPublish { publish(job).padding(.top, 12) }
        if job.report == true {
            PillButton(title: "Read report") {
                Task { await run { researchReport = try await phone.runner.report(job.id); showingReport = true } }
            }
            .padding(.top, 12)
        }
    }

    /// Publish by hand when Oby's own didn't go: the exact action shows first, and exactly that
    /// goes out once Face ID signs it.
    @ViewBuilder private func publish(_ job: Job) -> some View {
        if let reason = job.publishError { Text(reason).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.needsInk).padding(.bottom, 8) }
        if let action {
            VStack(alignment: .leading, spacing: 10) {
                Text(action).font(Tokens.font(Tokens.textBase, .medium)).foregroundStyle(Tokens.ink).fixedSize(horizontal: false, vertical: true)
                if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger) }
                HStack(spacing: 8) {
                    PillButton(title: busy ? "Publishing…" : "Publish with Face ID", primary: true) {
                        Task {
                            await run {
                                let url = try await phone.publish(job.id, action: action)
                                self.action = nil
                                openURL(url)
                            }
                        }
                    }
                    .disabled(busy)
                    PillButton(title: "Not now", quiet: true) { self.action = nil; problem = nil }.disabled(busy)
                }
            }
        } else {
            PillButton(title: job.published == nil ? "Publish…" : "Publish the new commits…", primary: true) {
                Task { await run { action = try await phone.publishAction(job.id) } }
            }
            .disabled(busy)
        }
    }

    private func details(_ job: Job) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(TaskFacts.facts(job), id: \.name) { fact in
                GridRow {
                    Text(fact.name).foregroundStyle(Tokens.muted).frame(width: 92, alignment: .leading)
                    Text(fact.value).font(fact.mono ? Tokens.mono(13) : Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(Tokens.font(Tokens.textBase))
    }

    /// What applies now, on the page (docs/oby-ux.md row 21): start now, or use an account past its
    /// reserve. The rest is in the ⋮.
    @ViewBuilder private func controls(_ job: Job) -> some View {
        let offers = TaskFacts.controls(job)
        let reserved = job.waitsToStart ? Usage.liftable(job.waiting?.reserved, among: phone.accounts, id: \.id, usage: \.usage) : []
        CenteredFlow(spacing: 8, centred: false) {
            if offers.startNow {
                PillButton(title: "Start now") { Task { await run { try await phone.startNow(job.id) } } }.disabled(busy)
            }
            ForEach(reserved) { account in
                PillButton(title: Usage.useAnyway(account.usage)) {
                    Task { await run { _ = try await phone.runner.liftReserve(account.id, true) } }
                }
                .disabled(busy)
            }
        }
        ForEach(reserved) { account in
            Text(Usage.liftNote(account.usage)).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.top, 6)
        }
    }

    private func section(_ title: String, first: Bool = false, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.label).padding(.bottom, 14)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16).padding(.bottom, 18)
        .overlay(alignment: .top) { if !first { Tokens.divider.frame(height: 1) } }
    }

    /// Each follow-up as Sangam's thread shows it: what you said, Oby's line, and its card.
    private func followUpList(_ followUps: [Job]) -> some View {
        ForEach(Array(followUps.enumerated()), id: \.element.id) { index, next in
            let account = phone.accountName(next.account)
            VStack(alignment: .leading, spacing: 8) {
                Text(next.request).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text).lineSpacing(6)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(ThreadTaskLine.followUp(next, account: account)).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ThreadTask(job: next, account: account)
            }
            .padding(.top, index == 0 ? 0 : 16)
        }
    }

    /// What you tell Oby about it goes to its agent (`POST /v1/jobs/{id}/messages`); a finished
    /// one gets a follow-up, which the runner answers with and its section lists.
    private func tell(_ id: String) {
        guard let text = ChatThread.words(note), text.count <= 2000, !busy else {
            if note.count > 2000 { noteProblem = "Keep your message under 2,000 characters." }
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await phone.tell(id, text)
                note = ""
                typing = false
                noteProblem = nil
            } catch { noteProblem = error.localizedDescription }
        }
    }

    private var publishAsked: Bool { phone.publishing == id && phone.loaded && scenePhase == .active }

    /// The notification's Publish: the action shows, and Face ID asks for it now.
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

/// The stages on the task's page: a mark per stage and a dotted line down to the next; its name,
/// then its live step or its detail, and why it failed.
private struct StageList: View {
    let job: Job
    let stages: [JobStage]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                let last = index == stages.count - 1
                let mark = TaskFacts.mark(stage.state, needs: job.needsYou || job.waitsForAnswer || job.waitsForPermission, working: job.status == .running)
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        StageMark(mark: mark).frame(width: 16, height: 18)
                        if !last { DottedLine().frame(width: 2).frame(minHeight: 20).padding(.top, 4).padding(.bottom, 2) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if mark == .current { Sheen(text: stage.title, size: Tokens.textBase) } else {
                                Text(stage.title).font(Tokens.font(Tokens.textBase, .medium))
                                    .foregroundStyle(mark == .upcoming || mark == .skipped ? Tokens.text : Tokens.ink)
                            }
                            if mark == .skipped { Text("Skipped").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted) }
                        }
                        if mark == .current, job.status == .running, !job.step.isEmpty, job.step != stage.detail {
                            Text(job.step).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted)
                        }
                        if let detail = stage.detail { Text(detail).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted) }
                        if let reason = stage.reason { Text(reason).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.danger) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, last ? 0 : 14)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(stage.state.rawValue.capitalized)
            }
        }
    }
}

/// A stage's mark in its 16-point spot: a green circle with a check once done, a grey dot pulsing
/// while worked on, orange while the task needs you, a ring still to come, a dash if skipped, red
/// if it failed.
private struct StageMark: View {
    let mark: TaskFacts.Mark

    var body: some View {
        switch mark {
        case .done:
            Image(systemName: "checkmark").font(Tokens.font(8, .heavy)).foregroundStyle(Tokens.bg)
                .frame(width: 14, height: 14).background(Tokens.done, in: Circle())
        case .current: WorkMarkView(mark: .working, dot: 10)
        case .needs: Circle().fill(Tokens.needs).frame(width: 10, height: 10)
        case .upcoming: Circle().strokeBorder(Tokens.check, lineWidth: 1.5).frame(width: 10, height: 10)
        case .skipped: Capsule().fill(Tokens.check).frame(width: 10, height: 2)
        case .failed: Circle().fill(Tokens.danger).frame(width: 10, height: 10)
        }
    }
}

/// Round 2-point dots, 6 apart, down to the next stage.
private struct DottedLine: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                var y: CGFloat = 1
                while y < geometry.size.height { path.addEllipse(in: CGRect(x: 0, y: y - 1, width: 2, height: 2)); y += 6 }
            }
            .fill(Tokens.check.opacity(0.75))
        }
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
        // Cursor's own list; none until a Cursor account is signed in, then only "as it is".
        if agent == "cursor" { return options?.cursor?.models.map { (id: $0.id, name: $0.name) } ?? [] }
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
