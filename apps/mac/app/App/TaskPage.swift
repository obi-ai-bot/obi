import SwiftUI

/// What the window can do with one job, this Mac's own or the runner's: the same calls the job's
/// screen makes (apps/mac/app/JobView.swift), gathered once so its card and its page share them.
struct TaskActions {
    var place: String
    var account: String?
    var extras: RunnerJobExtras?
    var accounts: [AccountState]
    var stop: () -> Void
    var message: (String) async throws -> Void
    var dismiss: () async throws -> Void
    var permission: (RunnerPermission.Decision, String?) async throws -> Void
    var mode: ((RunnerMode) async throws -> Void)?
    var startNow: (() async throws -> Void)?
    var useAnyway: ((String) async throws -> Void)?
    /// Move to…; nil for Oby's own reviews, which pick their account themselves.
    var move: ((MoveTarget) async throws -> Void)?
    /// Nil where this Mac can't publish (a runner's job, on a Mac without Touch ID).
    var publishing: JobView.Publishing?
    var readReport: (() async throws -> ResearchDocument)?
    var fileProposal: ((Int, Bool) async throws -> FileProposalResult)?
    /// The page's box (Sangam's TaskView): the words, and the files with them, for Oby to pass on;
    /// answers the job that heard them, the follow-up they started on a finished one. Nil: `message`.
    var tell: ((String, [String]) async throws -> Job)? = nil
    /// The box's +: only obid on this Mac reads the tray's files, and only a follow-up takes them.
    var attaches = false
    /// Puts its decision off an hour (Later on its inbox item, as the conversation's cards do), and
    /// says whether there was anything to put off; nil where nothing offers Later.
    /// Run it here: a job that came back from a teammate's Mac moves to this one (#808); nil for
    /// this Mac's own jobs.
    var runHere: (() async throws -> Void)? = nil
    var later: (() async throws -> Bool)? = nil
    /// The shares of their API accounts teammates gave you that this job's agent can run on
    /// (#809), and moving it onto one; none for this Mac's own jobs.
    var shares: [RunnerShares.Share] = []
    var useShare: ((RunnerShares.Share) async throws -> Void)? = nil

    /// The + is there where the files can go: obid on this Mac, and a finished job, whose words
    /// start a follow-up (a job at work takes words only).
    static func attaches(_ job: Job, runnerHere: Bool) -> Bool { runnerHere && !job.isActive }

    /// What Later puts off: the job's open inbox item, else the permission it waits on.
    enum LaterTarget: Equatable { case item(String), permission(String) }

    static func laterTarget(_ job: String, inbox: [InboxItem], permissions: [RunnerFeed.PermissionRecord] = []) -> LaterTarget? {
        if let item = inbox.first(where: { $0.job == job && $0.done == nil }) { return .item(item.id) }
        return permissions.first { $0.job == job && $0.done == nil }.map { .permission($0.id) }
    }

    @MainActor static func of(_ job: Job, local: Bool, model: IslandModel) -> TaskActions {
        let desk = model.desk, feed = model.feed
        if local {
            return TaskActions(
                place: "This Mac", account: desk.accounts.accounts.first { $0.account.id == job.account }?.account.name,
                extras: RunnerJobExtras(local: job), accounts: desk.accounts.accounts,
                stop: { desk.stop(job.id) },
                message: { try desk.message(job.id, $0) }, dismiss: { try desk.dismiss(job.id) },
                permission: { try desk.answerPermission(job.id, $0, message: $1) },
                mode: { try desk.changeMode(job.id, to: $0) },
                startNow: { try desk.startNow(job.id) }, useAnyway: { _ = desk.liftReserve($0, true) },
                move: job.reviewOf == nil ? { target in _ = try desk.move(job.id, to: target) } : nil,
                publishing: JobView.Publishing(action: { Publish.action(for: job, base: job.base ?? "") },
                                               publish: { _ in _ = try await desk.publish(job.id, approve: Publish.touchID) }),
                readReport: {
                    guard let saved = desk.store.report(job.id) else { throw Shell.Failure(message: "This job has no research report.") }
                    return ResearchDocument(job: saved.job, commit: saved.commit, markdown: saved.markdown,
                                            proposals: saved.proposals.map { ResearchProposal(index: $0.index, repo: $0.repo, title: $0.title, body: $0.body, labels: $0.labels, filed: $0.filed, filedAt: $0.filedAt) })
                },
                fileProposal: { index, start in try await fileLocalProposal(job, index: index, start: start, desk: desk) },
                tell: { text, _ in
                    try desk.message(job.id, text)
                    // The thread the window opens on it gets the words and Oby's answer, as obid's conversation does.
                    if model.hasConversation(of: job.id, local: true) {
                        let account = desk.accounts.accounts.first { $0.account.id == job.account }?.account.name ?? job.account
                        desk.told(text, reply: TaskFacts.relay(job, heard: job, account: account), job: job.id)
                    }
                    return job
                },
                later: {
                    guard case .item(let id) = laterTarget(job.id, inbox: desk.inbox) else { return false }
                    _ = try await desk.answer(id, .later(.now.addingTimeInterval(3600)))
                    return true
                })
        }
        return TaskActions(
            place: feed.name, account: nil, extras: feed.extras[job.id], accounts: feed.accounts,
            stop: { Task { if let stopped = try? await feed.about(job.id, { try await $0.stop(job.id) }) { feed.apply(stopped) } } },
            message: { text in if feed.runner != nil { feed.apply(try await feed.about(job.id) { try await $0.tell(job.id, text) }) } },
            dismiss: { if feed.runner != nil { feed.apply(try await feed.about(job.id) { try await $0.dismiss(job.id) }) } },
            permission: { try await feed.answer(job.id, $0, message: $1) },
            mode: { try await feed.setMode(job.id, $0) },
            startNow: { if feed.runner != nil { feed.apply(try await feed.about(job.id) { try await $0.startNow(job.id) }) } },
            useAnyway: { account in if feed.runner != nil { _ = try await feed.acting().liftReserve(account, true) } },
            move: job.reviewOf == nil ? { target in
                guard feed.runner != nil else { throw RunnerError(message: "The runner isn't set up.") }
                feed.apply(try await feed.about(job.id) { try await $0.move(job.id, agent: target.agent, account: target.account, model: target.model) })
            } : nil,
            publishing: feed.device.key.isAvailable
                ? JobView.Publishing(action: { try await feed.publishAction(job.id) }, publish: { try await feed.publish(job.id, action: $0) })
                : nil,
            readReport: { try await feed.about(job.id) { try await $0.report(job.id) } },
            fileProposal: { index, start in try await feed.about(job.id) { try await $0.fileProposal(job.id, index: index, start: start) } },
            tell: { text, files in
                guard feed.runner != nil else { throw RunnerError(message: "The runner isn't set up.") }
                let heard = try await feed.about(job.id) { try await $0.tell(job.id, text, conversation: true, attachments: files) }
                feed.apply(heard)
                return heard
            },
            attaches: attaches(job, runnerHere: feed.local),
            runHere: { if feed.runner != nil { feed.apply(try await feed.about(job.id) { try await $0.place(job.id, on: nil) }) } },
            later: {
                switch laterTarget(job.id, inbox: feed.inbox, permissions: feed.permissionHistory) {
                case .item(let id): try await feed.settle(id, later: .now.addingTimeInterval(3600)); return true
                case .permission(let id): feed.laterPermission(id); return true
                case nil: return false
                }
            },
            shares: feed.shares.filter { $0.agent == job.agent && $0.left > 0 },
            useShare: { share in
                if feed.runner != nil { feed.apply(try await feed.about(job.id) { try await $0.place(job.id, on: share.from, grant: share.grant) }) }
            })
    }

    /// Files one of this Mac's research report's proposed issues, after the secret scan, and starts
    /// work on it when asked.
    @MainActor private static func fileLocalProposal(_ job: Job, index: Int, start: Bool, desk: Desk) async throws -> FileProposalResult {
        guard var saved = desk.store.report(job.id),
              let position = saved.proposals.firstIndex(where: { $0.index == index }) else {
            throw Shell.Failure(message: "There's no proposed issue with that index.")
        }
        guard saved.proposals[position].filed == nil else { throw Shell.Failure(message: "This issue was already filed.") }
        let proposal = saved.proposals[position]
        do {
            let findings = try await Publish.scan(texts: [("issue title", proposal.title), ("issue body", proposal.body)])
            guard findings.isEmpty else { throw Shell.Failure(message: "The proposed issue didn't pass Oby's secret scan.") }
        } catch { throw Shell.Failure(message: "Oby's secret scanner couldn't run or found a secret; nothing was filed.") }
        let result = try await Shell.run(["gh", "issue", "create", "-R", proposal.repo, "--title", proposal.title, "--body-file", "-"],
                                         input: Data(proposal.body.utf8), as: .app)
        guard result.status == 0, let url = URL(string: result.text), url.scheme == "https", url.host == "github.com" else {
            throw Shell.Failure(message: result.err.isEmpty ? "GitHub couldn't create the proposed issue." : result.err)
        }
        let issueURL = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.proposals[position].filed = issueURL
        saved.proposals[position].filedAt = .now
        desk.store.save(saved)
        desk.sent(job.id, Outgoing(action: .issue, repo: proposal.repo, id: issueURL))
        let number = url.path.split(separator: "/").last.flatMap { Int($0) }
        var started: Job?
        if start, let number {
            started = try await desk.dispatch(Desk.NewJob(repo: proposal.repo, kind: "build", task: "Work on #\(number): \(proposal.title)", issue: number))
        }
        return FileProposalResult(issue: issueURL, jobId: started?.id)
    }
}

/// What a job waits on you for, answerable in place (its card, its page): its OK on a command or
/// a file, else the answer to its question or plan; other needs say what they are.
struct TaskDecision: View {
    let job: Job
    let actions: TaskActions
    @Binding var busy: Bool
    @Binding var problem: String?
    /// On the task's page, where the box under it tells the agent (which answers it too).
    var box = false
    /// Later: puts it off an hour, as the conversation's cards do; nil where it isn't offered.
    var onLater: (() -> Void)? = nil

    private var question: Question? {
        actions.extras?.question ?? job.question.map { Question(text: $0.text, options: $0.options, recommended: $0.recommended, plan: $0.plan) }
    }

    var body: some View {
        if let permission = actions.extras?.permission, job.isActive {
            AskCard(kind: "Permission", title: permission.title, detail: permission.detail, options: CardOption.permission(permission),
                    busy: busy, keyboardEnabled: box, hint: box ? CardOption.denyWords : nil,
                    onChoose: { option in
                        guard let decision = RunnerPermission.Decision(rawValue: option.answer) else { return }
                        run { try await actions.permission(decision, nil) }
                    }, onLater: onLater)
                .id(permission.id)
        } else if job.waitsForAnswer, let question {
            AskCard(kind: AskKind.label("question", plan: question.plan != nil), title: question.text, plan: question.plan,
                    options: question.cardOptions, busy: busy, keyboardEnabled: box,
                    hint: box ? "Or answer in your own words below" : nil, onChoose: { option in run { try await actions.message(option.answer) } },
                    onLater: onLater)
                .id(question.text)
        } else if job.nextStepOffered != nil, let on = actions.extras?.runsOn, let runHere = actions.runHere {
            // It came back from a teammate's Mac (Sangam's "Came back" card, #808): run it here, or
            // send it back there once that Mac is free.
            let wait = "Wait for \(RunnerMac.person(on.owner))’s Mac"
            let (title, happened) = Self.cameBack(job.line)
            AskCard(kind: "Came back", title: title, happened: happened,
                    options: CardOption.of([Self.runHereLabel, wait], recommended: 0), busy: busy,
                    onChoose: { option in
                        run {
                            if option.answer == Self.runHereLabel { try await runHere() }
                            try await actions.message(Job.tryAgainWords)
                        }
                    }, onLater: onLater)
                .id("\(job.id)-\(job.finished?.timeIntervalSince1970 ?? 0)")
        } else if job.nextStepOffered != nil, let resumes = job.resumes, actions.extras?.runsOn == nil,
                  let share = actions.shares.first, let useShare = actions.useShare {
            // Its account is full (Sangam's "Your Claude is full until 4 PM", #809): run it on a
            // teammate's share of their API account, on their Mac, or wait for the reset.
            let use = Self.useShareLabel(share)
            AskCard(kind: "Out of usage", title: Self.fullTitle(job, until: resumes), happened: Self.shareLine(share),
                    options: CardOption.of([use, Self.waitLabel], recommended: 0), busy: busy,
                    onChoose: { option in
                        run {
                            if option.answer == use {
                                try await useShare(share)
                                try await actions.message(Job.tryAgainWords)
                            } else {
                                _ = try await actions.later?()
                            }
                        }
                    }, onLater: onLater)
                .id("\(job.id)-share-\(job.finished?.timeIntervalSince1970 ?? 0)")
        } else if let next = job.nextStepOffered {
            AskCard(kind: job.needsYouKind, title: job.line, happened: job.resumesLine, options: CardOption.of([next], recommended: 0), busy: busy,
                    onChoose: { _ in run { try await actions.message(Job.tryAgainWords) } }, onLater: onLater)
                .id("\(job.id)-\(job.finished?.timeIntervalSince1970 ?? 0)")
        }
    }

    static let runHereLabel = "Run it here"

    /// obid's words for a job that came back, as Sangam's card shows them: the headline ("That Mac
    /// couldn’t keep running it"), then what happened, split at the first sentence.
    static func cameBack(_ line: String) -> (String, String?) {
        guard let end = line.range(of: ". ") else { return (line, nil) }
        return (String(line[..<end.lowerBound]), String(line[end.upperBound...]))
    }
    static let waitLabel = "Wait for the reset"

    /// "Use Wellington’s share".
    static func useShareLabel(_ share: RunnerShares.Share) -> String { "Use \(RunnerMac.person(share.owner))’s share" }

    /// "Your Claude is full until 4 PM".
    static func fullTitle(_ job: Job, until: Date) -> String {
        let tool = job.agent == "codex" ? "Codex" : job.agent == "cursor" ? "Cursor" : "Claude"
        return "Your \(tool) is full until \(until.formatted(date: .omitted, time: .shortened))"
    }

    /// "Wellington shares 30% of Deskree API’s month with you, and 18% is left. It would run on
    /// Wellington’s Mac, on that account, and you get the pull request."
    static func shareLine(_ share: RunnerShares.Share) -> String {
        let name = RunnerMac.person(share.owner)
        return "\(name) shares \(share.share)% of \(share.account)’s month with you, and \(share.left)% is left. It would run on \(name)’s Mac, on that account, and you get the pull request."
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await work(); problem = nil } catch { problem = error.localizedDescription }
        }
    }

    /// Whether there's a decision to show.
    static func shows(_ job: Job, extras: RunnerJobExtras?) -> Bool {
        (extras?.permission != nil && job.isActive) || (job.waitsForAnswer && (extras?.question != nil || job.question != nil))
            || job.nextStepOffered != nil
    }
}

/// A task as a card in its kind's page (Sangam's TaskCard): where it came from and what it is,
/// which agent has it where, then what's happening now (the live step while it runs, the decision
/// while it needs you, what it left behind once done), and its stages as a thin bar along the foot.
/// A click anywhere but its buttons opens its page.
struct TaskCardView: View {
    let item: WorkList.Item<SidebarSections.JobRow>
    let model: IslandModel
    let state: ChatState
    let onOpen: () -> Void
    @State private var hovering = false
    @State private var busy = false
    @State private var problem: String?

    private var job: Job { item.job.job }

    var body: some View {
        let actions = TaskActions.of(job, local: item.job.local, model: model)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AgentMark(agent: job.agent).font(Tokens.font(13, .semibold)).frame(width: 16).foregroundStyle(Tokens.muted)
                Text(job.heading).font(Tokens.font(Tokens.textLg, .semibold)).foregroundStyle(Tokens.ink).fadeOut()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(TaskFacts.ago(job, now: context.date)).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
                }
            }
            // New (blue) or needs you (orange): its dot in the card's margin, level with the title.
            .overlay(alignment: .leading) {
                if item.mark == .new || item.mark == .needs { WorkMarkView(mark: item.mark).offset(x: -18) }
            }
            Text(meta(actions)).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted).fadeOut()
                .padding(.leading, 26).padding(.top, 4)
            if item.status == .running {
                HStack(spacing: 10) {
                    if job.status == .queued {
                        Text(job.line).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).fadeOut()
                    } else {
                        Sheen(text: job.line)
                    }
                    Spacer(minLength: 0)
                    if job.maxRounds > 1 {
                        Text("Round \(job.currentRound) of \(job.maxRounds)").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                    }
                }
                .padding(.top, 14)
            }
            if item.status == .needs {
                VStack(alignment: .leading, spacing: 0) {
                    if TaskDecision.shows(job, extras: actions.extras) {
                        TaskDecision(job: job, actions: actions, busy: $busy, problem: $problem,
                                     onLater: actions.later.map { later in {
                                         Task {
                                             do { _ = try await later(); problem = nil } catch { problem = error.localizedDescription }
                                         }
                                     } })
                    } else {
                        Text(job.badge.text).font(Tokens.font(Tokens.textSm, .medium))
                            .foregroundStyle(job.badge.tone == .red ? Tokens.danger : Tokens.needs)
                        Text(job.line).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).padding(.top, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 8) }
                }
                .padding(.top, 14)
                .overlay(alignment: .top) { Tokens.divider.frame(height: 1) }
                .padding(.top, 16)
            }
            if item.status == .done, let line = TaskFacts.resultLine(job) {
                HStack(spacing: 8) {
                    Text(line).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                    if let url = PublishedLink.url(job.published) {
                        Link("Open PR", destination: url).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.text)
                    }
                }
                .padding(.top, 12)
            }
            if item.status != .done { StageBar(job: job, needs: item.status == .needs).padding(.top, 16) }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Tokens.chipHover : Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
        .overlay(alignment: .topTrailing) {
            if hovering && job.isActive {
                StopButton { model.stopChatJob(job.id, local: item.job.local) }.padding(.top, 14).padding(.trailing, 14)
            }
        }
        .onHover { hovering = $0 }
        .animation(Tokens.fade, value: hovering)
        // The task's menu, as on its side panel row; Rename opens its page, renaming in the title bar.
        .contextMenu {
            TaskMenu(row: item.job, model: model, state: state, onViewDetails: onOpen,
                     onOpenChat: { state.trail.push(.talk) },
                     onRename: { onOpen(); state.renaming = .init(id: item.id, inBar: true) })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(job.heading), \(item.mark.rawValue)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
    }

    private func meta(_ actions: TaskActions) -> String {
        let repo = job.repo.split(separator: "/").last.map(String.init)
        // "Claude Code · Personal · on Wellington’s Mac · oby" (Sangam's design, #808).
        let on = item.job.local ? nil : model.feed.extras[job.id]?.runsOn.map { "on \(RunnerMac.person($0.owner))’s Mac" }
        return ([job.agentName, actions.account ?? LiveView.account(of: job, local: item.job.local, desk: model.desk, feed: model.feed)]
            + [on, repo].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The stages as one thin bar of segments: done and current lit (current pulsing while it works,
/// orange while the task needs you), failed in red, the rest dim.
struct StageBar: View {
    let job: Job
    let needs: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let stages = job.pipeline.stages
        HStack(spacing: 3) {
            ForEach(stages) { stage in
                Group {
                    if stage.state == .current && !needs && job.status == .running && !reduceMotion {
                        PhaseAnimator([1.0, 0.35]) { level in Capsule().fill(Color.white.opacity(0.55)).opacity(level) }
                            animation: { _ in .easeInOut(duration: 0.8) }
                    } else {
                        Capsule().fill(color(stage.state))
                    }
                }
                .frame(height: 3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(job.pipeline.label)
    }

    private func color(_ state: JobStage.State) -> Color {
        switch state {
        case .done: Color.white.opacity(0.55)
        case .current: needs ? Tokens.needs : Color.white.opacity(0.55)
        case .failed: Tokens.danger
        case .upcoming, .skipped: Tokens.pill
        }
    }
}


/// One task on its own page (Sangam's TaskView with #741's timeline, Alternative B of
/// obi-ai-bot/obi#739). Its title and agent · account · where, with the mode to change; the
/// decision, when there is one, a card of its own (a failure says what failed); then one card with
/// Result (and what went out), the Timeline (the time track, then the stages as the spine with the
/// work, the checks and the secret scan under them; "Stages" as before while the runner serves no
/// times), Usage, Details with the full session under it, what you asked and its follow-ups; what
/// it can still do under it; and at the foot the box to tell Oby about it, with Stop in its end slot
/// while it runs (A14). A part whose facts the runner doesn't serve yet isn't drawn.
struct TaskPage: View {
    let job: Job
    let actions: TaskActions
    let tray: Tray
    /// The job's alert's Publish opened this page: the sentence shows, and Touch ID asks for it now.
    var publishNow = false
    /// Called as that starts, so it starts once.
    var onPublishNow: () -> Void = {}
    /// Esc in the box: back a page.
    var onBack: (() -> Void)? = nil
    /// Its follow-ups, oldest first (`ThreadTaskLine.followUps`), and opening one's page.
    var followUps: [Job] = []
    var onOpenJob: (String) -> Void = { _ in }
    /// Full session: the job's live session, over this page with Session in the trail (#785); nil
    /// for this Mac's own jobs, which keep none.
    var onSession: (() -> Void)? = nil
    /// The main composer's gauge and voice (Sangam's TaskView uses Home's Composer).
    var usage: [UsageRow]? = nil
    var voice: Voice? = nil
    var talkKeyListening = false
    /// The words went: the job that heard them (a follow-up a finished one started), for the
    /// window to open its conversation, as Sangam's `tellFromTask` does. False when it has none
    /// kept: then the words and Oby's answer show here.
    var onTold: (Job) -> Bool = { _ in false }
    @State private var moving = false
    /// The last words said here and Oby's answer, where no conversation keeps them (or Later's).
    @State private var exchange: (said: String, reply: String)?
    @State private var busy = false
    @State private var problem: String?
    @State private var note = ""
    @State private var typing = false
    @State private var height: CGFloat = 600
    /// The exact sentence Publish would carry out, shown before Touch ID approves it.
    @State private var action: String?
    @State private var report: ResearchDocument?
    /// Why the words for the agent didn't go, over the box.
    @State private var noteProblem: String?
    @State private var showingReport = false

    private var facts: JobFacts? { actions.extras?.facts }
    private var mode: String? { actions.extras?.mode }
    /// It waits on you: its clock is paused, and its stage is orange.
    private var needs: Bool { TaskDecision.shows(job, extras: actions.extras) && job.isActive }
    private var failure: Bool { TaskPage.failure(job) && !TaskDecision.shows(job, extras: actions.extras) }

    /// Where words said on the page lead (Sangam's tellFromTask): the job's conversation when one
    /// is kept, else they stay here with Oby's answer under them.
    enum AfterTold: Equatable { case conversation, page }

    static func afterTold(hasConversation: Bool) -> AfterTold { hasConversation ? .conversation : .page }

    /// It ended without finishing and you haven't let it go: the page leads with what failed.
    static func failure(_ job: Job) -> Bool {
        (job.status == .failed || job.status == .interrupted) && job.dismissed == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    if TaskDecision.shows(job, extras: actions.extras) {
                        TaskDecision(job: job, actions: actions, busy: $busy, problem: $problem, box: true,
                                     onLater: actions.later.map { later in {
                                         run {
                                             // Oby says it'll wait only when something was put off.
                                             if try await later() { exchange = ("Later", TaskFacts.laterReply) }
                                         }
                                     } })
                            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 18)
                            .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.askRadius, style: .continuous))
                    } else if failure {
                        failed
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        // Once it's done (Sangam's #741), or while a published one runs again.
                        let hasResult = TaskFacts.hasResult(job) && !failure && (!job.isActive || job.published != nil)
                        if hasResult {
                            PageSection("Result", first: true) { result }
                        }
                        JobTimeline(job: job, facts: facts, mode: mode, needs: needs,
                                    onSession: onSession, first: !hasResult)
                        if JobUsageLine.shows(facts) {
                            PageSection("Usage") {
                                JobUsageLine(usage: facts?.usage, share: facts?.windowShare,
                                             account: actions.accounts.first { $0.account.id == job.account }?.usage, done: job.status == .done)
                            }
                        }
                        PageSection(title: "Details", accessory: {
                            if let onSession { SectionLink(title: "Full session", action: onSession) }
                        }) { details }
                        PageSection("What you asked") { asked }
                        if let tetrix = actions.extras?.tetrix, !tetrix.isEmpty { PageSection("Tetrix") { TetrixReportView(report: tetrix) } }
                        if !followUps.isEmpty { PageSection("Follow-ups") { followUpList } }
                    }
                    .padding(.horizontal, 18)
                    .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.askRadius, style: .continuous))
                    if moving, let move = actions.move {
                        MovePanel(job: job, accounts: actions.accounts, onMove: move, onClose: { moving = false })
                            .padding(.top, 6)
                    } else {
                        controls.padding(.top, 6)
                    }
                    if let problem, action == nil {
                        Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 2)
                    }
                }
                .frame(maxWidth: Tokens.column, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Tokens.gutter).padding(.top, 8).padding(.bottom, 32)
            }
            .scrollIndicators(.never)
            if let exchange {
                VStack(alignment: .leading, spacing: 4) {
                    Text("You: \(exchange.said)").foregroundStyle(Tokens.text)
                    Text("Oby: \(exchange.reply)").foregroundStyle(Tokens.muted)
                }
                .font(Tokens.font(Tokens.textSm)).textSelection(.enabled)
                .frame(maxWidth: Tokens.column, alignment: .leading).padding(.horizontal, Tokens.gutter + 12).padding(.top, 8)
            }
            if let noteProblem {
                Text(noteProblem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger)
                    .frame(maxWidth: Tokens.column, alignment: .leading).padding(.horizontal, Tokens.gutter + 12).padding(.top, 8)
            }
            MessageBox(text: $note, focused: $typing, tray: tray, placeholder: TaskFacts.box, label: "Tell Oby about \(job.heading)",
                       maximumHeight: height * 0.5, onSend: tell, onScreenshot: screenshot, onStop: { false }, onEscape: onBack,
                       usage: usage, attachments: actions.attaches, voice: voice, talkKeyListening: talkKeyListening,
                       onStopTurn: job.isActive ? actions.stop : nil, working: job.isActive)
                .disabled(busy)
                .keepsDraft($note, as: Drafts.task(job.id))
                .frame(maxWidth: Tokens.column).padding(.horizontal, Tokens.gutter).padding(.top, 8).padding(.bottom, 20)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        // Not a task tied to publishNow: starting clears it, which would cancel the publish.
        .onChange(of: publishNow, initial: true) { if publishNow { publishFromAlert() } }
        .sheet(isPresented: $showingReport) {
            if let report { ReportView(report: report, onFile: actions.fileProposal).frame(minWidth: 560, minHeight: 520) }
        }
    }

    /// The page's head: the agent's mark, the title and how long; who has it where, and the mode.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                AgentMark(agent: job.agent).font(Tokens.font(17, .semibold)).frame(width: 20).foregroundStyle(Tokens.ink).opacity(0.7)
                Text(job.heading).font(Tokens.font(22, .semibold)).foregroundStyle(Tokens.ink).lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text((TaskPage.failure(job) ? "Failed " : "") + TaskFacts.ago(job, now: context.date))
                        .font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
                }
            }
            HStack(spacing: 10) {
                Text([job.agentName, actions.account ?? job.account, actions.place].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted)
                Text(job.badge.text).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(tone(job.badge.tone))
                if let change = actions.mode, job.status != .done, let mode = RunnerMode(mode) { modeMenu(mode, change) }
            }
            .padding(.leading, 30)
            ForEach([job.isWaiting ? job.line : nil, job.verdictLine, job.movedLine].compactMap { $0 }, id: \.self) { line in
                Text(line).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.leading, 30)
            }
            if let routine = actions.extras?.routine {
                Text(routine.line).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.leading, 30)
            }
            if let line = actions.extras?.teammates?.line {
                Text(line).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.leading, 30)
            }
        }
        .padding(.bottom, 8)
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

    /// What failed and what it left (Sangam's failed card, #741): the failing tests, when the runner
    /// serves them; another round, the session to read, and Stop here (Dismiss: it stops needing you).
    private var failed: some View {
        let lines = job.summary.split(separator: "\n", maxSplits: 1).map(String.init)
        let failing = facts?.checks?.last?.failing?.map { [$0.test, $0.message.map { "  " + $0 }].compactMap { $0 }.joined(separator: "\n") }
        return AskCard(kind: "Failed", failed: true, title: lines.first ?? job.line, happened: lines.count > 1 ? lines[1] : nil,
                       detail: failing?.joined(separator: "\n"),
                       options: FailedChoice.options(session: onSession != nil), busy: busy,
                       onChoose: { option in
                           switch FailedChoice(rawValue: option.answer) {
                           case .round: run { try await actions.message(FailedChoice.roundWords) }
                           case .session: onSession?()
                           case .dismiss: run(actions.dismiss)
                           case nil: break
                           }
                       })
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 18)
            .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.askRadius, style: .continuous))
    }

    /// What the agent reported, what it left behind and what went out, and Publish or Read report.
    @ViewBuilder private var result: some View {
        if !job.summary.isEmpty {
            Text(job.summary).font(Tokens.font(16, .medium)).foregroundStyle(Tokens.ink).lineSpacing(6)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if let note = job.handoffNote {
            Text("Handoff note").font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.muted).padding(.top, 12)
            Text(note).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).lineSpacing(4)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
        if let line = TaskFacts.resultLine(job) {
            Text(line).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.top, 8)
        } else if let commits = job.commits, commits > 0 {
            Text("\(commits) commit\(commits == 1 ? "" : "s") on \(job.branch)").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.top, 8)
        }
        if let url = PublishedLink.url(job.published) {
            Link("Open pull request", destination: url).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.text).padding(.top, 6)
        }
        if let outgoing = job.outgoing, !outgoing.isEmpty { WentOut(outgoing: outgoing).padding(.top, 14) }
        if let error = job.pullRequestError { Text(error).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.top, 6) }
        if job.dismissed != nil {
            Text("Dismissed. Tell the agent something to pick it up again.").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.top, 6)
        }
        if job.canPublish { publish.padding(.top, 12) }
        if job.report == true {
            PillButton(title: "Read report") {
                Task {
                    do { report = try await actions.readReport?(); showingReport = report != nil } catch { problem = error.localizedDescription }
                }
            }
            .padding(.top, 12)
        }
    }

    /// Publish by hand when Oby's own didn't go: what it would do is shown first, in the runner's
    /// own words for its jobs, and exactly that goes out after Touch ID or the Mac's password.
    @ViewBuilder private var publish: some View {
        if let reason = job.publishError { Text(reason).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.needs).padding(.bottom, 8) }
        if actions.publishing == nil {
            Text("Publish from your iPhone").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
        } else if let action {
            VStack(alignment: .leading, spacing: 10) {
                Text(action).font(Tokens.font(Tokens.textBase, .medium)).foregroundStyle(Tokens.ink).fixedSize(horizontal: false, vertical: true)
                if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger) }
                HStack(spacing: 8) {
                    PillButton(title: busy ? "Publishing…" : TouchIDKey.publish, primary: true) { publish(action) }.disabled(busy)
                    PillButton(title: "Not now", quiet: true) { self.action = nil; problem = nil }.disabled(busy)
                }
            }
        } else {
            PillButton(title: job.published == nil ? "Publish" : "Publish the new commits", primary: true) {
                guard let publishing = actions.publishing else { return }
                run { action = try await publishing.action() }
            }
            .disabled(busy)
        }
    }

    /// The alert's Publish, as on the iPhone: the sentence shows, and Touch ID asks with it.
    private func publishFromAlert() {
        onPublishNow()
        guard let publishing = actions.publishing, job.canPublish, !busy else { return }
        run {
            let sentence = try await publishing.action()
            action = sentence
            try await publishing.publish(sentence)
            action = nil
        }
    }

    private func publish(_ sentence: String) {
        guard let publishing = actions.publishing else { return }
        run {
            try await publishing.publish(sentence)
            action = nil
        }
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(TaskFacts.facts(job, mode: mode), id: \.name) { fact in
                GridRow {
                    Text(fact.name).foregroundStyle(Tokens.muted).frame(width: 96, alignment: .leading)
                    Text(fact.value).font(fact.mono ? Tokens.mono(13) : Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(Tokens.font(Tokens.textBase))
    }

    /// What you asked, and what you told the agent along the way.
    @ViewBuilder private var asked: some View {
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

    /// Each follow-up as Sangam's thread shows it: what you said, Oby's line, and its card.
    private var followUpList: some View {
        ForEach(Array(followUps.enumerated()), id: \.element.id) { index, next in
            // Its own account, which a move may have changed: by name, as the iPhone shows it.
            let account = actions.accounts.first { $0.account.id == next.account }?.account.name ?? next.account
            VStack(alignment: .leading, spacing: 8) {
                Text(next.request).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text).lineSpacing(6)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(ThreadTaskLine.followUp(next, account: account)).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ThreadTask(job: next, account: account, onOpen: { onOpenJob(next.id) })
            }
            .padding(.top, index == 0 ? 0 : 16)
        }
    }

    /// What the job can still do: start now when it waits for its time, use an account past its
    /// weekly reserve, move it, stop it while the box can't (queued), or let it go.
    @ViewBuilder private var controls: some View {
        // Stop is the box's end slot while it runs or waits its turn.
        let offers = TaskFacts.controls(job)
        let reserved = job.waitsToStart && actions.useAnyway != nil
            ? Usage.liftable(job.waiting?.reserved, among: actions.accounts, id: \.account.id, usage: \.usage) : []
        if offers.startNow || offers.dismiss || !reserved.isEmpty || actions.move != nil {
            CenteredFlow(spacing: 8, centred: false) {
                if offers.startNow, let startNow = actions.startNow {
                    PillButton(title: "Start now") { run(startNow) }.disabled(busy).help("Start it now instead of waiting")
                }
                ForEach(reserved, id: \.account.id) { state in
                    PillButton(title: Usage.useAnyway(state.usage)) { run { try await actions.useAnyway?(state.account.id) } }.disabled(busy)
                }
                if actions.move != nil {
                    PillButton(title: "Move to…") { problem = nil; moving = true }.disabled(busy)
                        .help("Move this job to another tool, account or model")
                }
                if offers.dismiss {
                    PillButton(title: "Dismiss", quiet: true) { run(actions.dismiss) }.disabled(busy)
                        .help("Let this job go: it stays in the list, and stops needing you")
                }
            }
            // What lifting a reserve does, and until when.
            ForEach(reserved, id: \.account.id) { state in
                Text(Usage.liftNote(state.usage)).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.top, 6)
            }
        }
    }

    private func modeMenu(_ mode: RunnerMode, _ change: @escaping (RunnerMode) async throws -> Void) -> some View {
        Menu {
            ForEach(RunnerMode.allCases) { choice in
                Button { run { try await change(choice) } } label: {
                    if choice == mode { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                }
                .help(choice.help)
            }
        } label: {
            HStack(spacing: 3) {
                Text(mode.label)
                Image(systemName: "chevron.down").font(Tokens.font(8, .semibold))
            }
            .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.text)
            .padding(.leading, 9).padding(.trailing, 8).frame(height: 22).background(Tokens.pill, in: Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(busy)
        .padding(.leading, 4)
        .help("Mode: \(mode.help)").accessibilityLabel("Mode: \(mode.label)")
    }

    private func tell() {
        guard !busy else { return }
        let text: String
        switch ChatSend.typed(note) {
        case .empty: return
        // Too long: say so, and leave the words in the box to shorten.
        case .tooLong: noteProblem = ChatSend.tooLong; return
        case .send(let words): text = words
        }
        let files = actions.attaches ? tray.paths : []
        busy = true
        Task {
            defer { busy = false }
            do {
                if let tell = actions.tell {
                    let heard = try await tell(text, files)
                    if !files.isEmpty { tray.clear() }
                    note = ""
                    noteProblem = nil
                    if !onTold(heard) {
                        let account = actions.accounts.first { $0.account.id == heard.account }?.account.name ?? heard.account
                        exchange = (text, TaskFacts.relay(job, heard: heard, account: account))
                    }
                } else {
                    try await actions.message(text)
                    note = ""
                    noteProblem = nil
                }
            } catch { noteProblem = error.localizedDescription }
        }
    }

    private func screenshot() {
        Task {
            await tray.screenshot()
            typing = true
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await work(); problem = nil } catch { problem = error.localizedDescription }
        }
    }
}

#if DEBUG
/// The page in each of the canvas's six states (JobPageFixture), as obid would send the job. The
/// Mac's window is dark only (Tokens), so each state has the one preview.
struct TaskPagePreview: View {
    let fixture: JobPageFixture

    var body: some View {
        let data = fixture.json()
        if let job = try? Runner.decoder.decode(Job.self, from: data) {
            let extras = try? Runner.decoder.decode(RunnerJobExtras.self, from: data)
            let account = AccountState(account: Account(id: "personal", agent: "claude", name: "Personal", payer: "me"),
                                       label: "Max", fiveHour: fixture.windows.fiveHour, sevenDay: fixture.windows.sevenDay)
            TaskPage(job: job, actions: TaskActions(place: "Studio", account: "Personal", extras: extras, accounts: [account], stop: {},
                                                    message: { _ in }, dismiss: {}, permission: { _, _ in }, mode: { _ in },
                                                    attaches: true, later: { true }),
                     tray: Tray(), onSession: {},
                     usage: [UsageRow(id: "personal", agent: "claude", name: "Personal", week: fixture.windows.sevenDay)])
                .frame(width: 700, height: 1480).background(Tokens.bg)
        }
    }
}

#Preview("Working") { TaskPagePreview(fixture: .working) }
#Preview("Planning") { TaskPagePreview(fixture: .planning) }
#Preview("Waiting for you") { TaskPagePreview(fixture: .needs) }
#Preview("Running checks") { TaskPagePreview(fixture: .checks) }
#Preview("Failed") { TaskPagePreview(fixture: .failed) }
#Preview("Done") { TaskPagePreview(fixture: .done) }
#endif
