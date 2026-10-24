import SwiftUI
import WebKit

/// Where a tab's stack can go: a kind of work's page, a task's page, a conversation (obid's by
/// id, nil for the latest or the one thread), the one Home's box just started, every task,
/// Archived, and the Inbox (what needs you with no task on Home).
enum Route: Hashable {
    case kind(WorkType)
    case task(String)
    case conversation(String?)
    case newConversation
    case all
    case archived
    case inbox
    case settings
}

extension EnvironmentValues {
    /// Opens a route over the stack the view is in.
    @Entry var push: (Route) -> Void = { _ in }
}

extension View {
    /// The way to open them, set on the stack itself so every page in it gets it.
    func pushes(onto path: Binding<[Route]>) -> some View {
        environment(\.push) { path.wrappedValue.append($0) }
    }

    /// Every page a tab's stack can open.
    func routes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .kind(let kind): KindPage(kind: kind)
            case .task(let id): TaskPage(id: id)
            case .conversation(let id): ConversationPage(id: id)
            case .newConversation: ConversationPage(id: nil, isNew: true)
            case .all: AllTasksPage()
            case .archived: ArchivedPage()
            case .inbox: InboxPage()
            case .settings: SettingsScreen()
            }
        }
    }

    /// Sangam's dark page: the background behind everything, its ink for the bars' controls.
    func obyPage() -> some View {
        background(Tokens.bg)
            .toolbarBackground(Tokens.bg, for: .navigationBar)
            .scrollContentBackground(.hidden)
    }
}

/// Home (Sangam's Home.tsx, docs/ios-design.md "Home"): Oby on its stage, what's running and what
/// needs you under it, a chip for every kind of work, then, as the iPhone has no side panel, the
/// running tasks and the latest conversations, and the message box. What you send there starts a
/// conversation and opens it. A chip opens its kind's page; "needs you", the decision that has
/// waited longest, with its task (docs/oby-ux.md rows 9-10); See all, every task.
struct HomeView: View {
    @Environment(Phone.self) private var phone
    @Environment(\.scenePhase) private var scenePhase
    let character: ObyCharacter
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        @Bindable var phone = phone
        // Why the Mac can't be reached: one line over every screen, the bars under it.
        VStack(spacing: 0) {
        if let notice = phone.notice { ReachLine(notice: notice) }
        NavigationStack(path: $phone.homePath) {
            ScrollView {
                VStack(spacing: 0) {
                    stage
                    lists.padding(.top, 22).padding(.horizontal, -10)
                }
                .padding(.horizontal, Tokens.gutter).padding(.top, 6).padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .obyPage()
            .safeAreaInset(edge: .bottom) {
                Composer(text: $text, prompt: HomeLine.placeholder(fullName: HomeLine.owner(ofMac: phone.link?.name) ?? ""),
                         typing: $typing, onSend: send)
                    .keepsDraft($text, as: Drafts.home)
            }
            .toolbar {
                // One panel button, as Sangam's: while the panel is open, its own puts it away.
                if phone.panel == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { typing = false; phone.panel = .home } label: { Image(systemName: "sidebar.left") }
                            .accessibilityLabel("Show sidebar")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { phone.homePath.append(.settings) } label: { OwnerPicture(name: HomeLine.owner(ofMac: phone.link?.name)) }
                        .accessibilityLabel("Settings")
                }
            }
            .routes()
        }
        .pushes(onto: $phone.homePath)
        }
        .animation(Tokens.warm, value: phone.notice)
        .onDisappear { phone.cancelVoice() }
        .onChange(of: scenePhase) { if scenePhase != .active { phone.leftForeground(background: scenePhase == .background) } }
        .onChange(of: phone.homePath) { if !phone.homePath.isEmpty { phone.cancelVoice(); typing = false } }
        .onChange(of: mood, initial: true) { character.mood = mood }
    }

    private var mood: String {
        if case .thinking = phone.talk { return "thinking" }
        return phone.active.contains(where: \.isWorking) ? "working" : "idle"
    }

    /// Oby, the line under it, and the chips.
    private var stage: some View {
        let work = phone.work
        let running = work.count { $0.status == .running }
        let needs = WorkList.needsYou(work, loose: phone.loose.count)
        return VStack(spacing: 0) {
            StageOby(character: character)
            Button {
                if let first = PhoneWork.firstNeeding(work, inbox: phone.answering) { phone.homePath.append(first) }
            } label: {
                Text(HomeLine.attention(running: running, needs: needs))
                    .font(Tokens.font(Tokens.textBase))
                    .foregroundStyle(running + needs == 0 ? Tokens.text : Tokens.muted)
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(.plain)
            .disabled(needs == 0)
            .accessibilityHint(needs > 0 ? "Opens what needs you" : "")
            .padding(.top, 14)
            CenteredFlow(spacing: 8) {
                ForEach(WorkList.kinds(work)) { group in
                    HomeChip(label: group.label, fresh: group.fresh, needs: group.needs > 0) {
                        if let kind = group.type { phone.homePath.append(.kind(kind)) }
                    }
                }
            }
            .frame(maxWidth: 362)
            .padding(.top, 16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Your tasks")
        }
        .frame(maxWidth: .infinity)
    }

    /// Running and Recent (the iPhone's side panel, cut short).
    @ViewBuilder private var lists: some View {
        let rows = PhoneWork.running(phone.work)
        let recent = phone.conversations.map(PhoneWork.recent) ?? []
        VStack(alignment: .leading, spacing: 0) {
            if !rows.isEmpty {
                ListLabel(title: "Running", more: "See all") { phone.homePath.append(.all) }
                ForEach(rows) { item in
                    Button { phone.homePath.append(.task(item.id)) } label: {
                        HomeTaskRow(item: item, step: PhoneWork.step(item, decision: phone.decision(for: item.job)))
                    }
                    .buttonStyle(RowPress())
                }
            }
            if !recent.isEmpty {
                ListLabel(title: "Recent", more: "All conversations") { phone.panel = .conversations }
                    .padding(.top, rows.isEmpty ? 0 : 14)
                ForEach(recent) { conversation in
                    Button { phone.homePath.append(.conversation(conversation.id)) } label: {
                        HomeConversationRow(conversation: conversation, last: conversation.turn?.text ?? phone.previews[conversation.id])
                    }
                    .buttonStyle(RowPress())
                    .task { await phone.preview(conversation.id) }
                }
            }
        }
    }

    /// `spoken`: the draft has dictated words, so the thread says "You, by voice".
    private func send(spoken: Bool) {
        phone.ask(text, spoken: spoken, new: true)
        text = ""
        typing = false
        phone.homePath.append(.newConversation)
    }
}

/// Oby on its stage (`.oby-frame`), the same face on Home and on the unpaired screen.
struct StageOby: View {
    @Environment(\.colorScheme) private var colorScheme
    let character: ObyCharacter

    var body: some View {
        WebView(character.page)
            .webViewContentBackground(.hidden)
            .opacity(character.ready ? 1 : 0)
            .allowsHitTesting(false)
            .frame(width: 160, height: 157)
            // White in both themes: on light, a soft shadow keeps its shape (the design's `--oby-glow`).
            .shadow(color: .black.opacity(colorScheme == .light ? 0.10 : 0), radius: 11, y: 10)
            .accessibilityElement()
            .accessibilityLabel("Oby")
    }
}

/// A list's label with its way to the rest (`.list-label`): 26 tall, 12pt `label`.
private struct ListLabel: View {
    let title: String
    let more: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title).accessibilityAddTraits(.isHeader)
            Spacer()
            Button(more, action: action).buttonStyle(.plain)
        }
        .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.label)
        .padding(.horizontal, 10).frame(height: 26)
    }
}

/// A row pressed: `hover`, 6 round.
private struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Tokens.hover : .clear, in: RoundedRectangle(cornerRadius: Tokens.rowRadius, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// A running task on Home (`.task-row`): its agent's mark, its title, what it's on, its mark.
private struct HomeTaskRow: View {
    let item: WorkList.Item<Job>
    let step: String

    var body: some View {
        HStack(spacing: 10) {
            AgentMark(agent: item.job.agent).font(Tokens.font(12, .semibold)).frame(width: 16).foregroundStyle(Tokens.ink.opacity(0.7))
            VStack(alignment: .leading, spacing: 0) {
                Text(item.job.heading).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.item).fadeOut()
                Text(step).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).lineLimit(1)
            }
            WorkMarkView(mark: item.mark).frame(width: 12, height: 12)
        }
        .padding(.horizontal, 10).frame(height: 44)
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.mark.rawValue)
    }
}

/// A conversation on Home (`.convo-row`): its name, the last thing said, when.
private struct HomeConversationRow: View {
    let conversation: RunnerConversation
    let last: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title.isEmpty ? "Conversation" : conversation.title)
                    .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.item).fadeOut()
                if let last, !last.isEmpty {
                    Text(last).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).fadeOut()
                }
            }
            if conversation.latest > .distantPast {
                Text(ConversationOrder.ago(conversation.latest)).font(Tokens.font(Tokens.textSm)).monospacedDigit()
                    .foregroundStyle(Tokens.muted).padding(.top, 6)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6).frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }
}

/// A kind of work's chip on Home: a blue dot ahead of its name while it holds a new task, an
/// orange one when something in it needs you; both can show.
struct HomeChip: View {
    let label: String
    let fresh: Bool
    let needs: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if fresh || needs {
                    HStack(spacing: 4) {
                        if fresh { Circle().fill(Tokens.unread).frame(width: 6, height: 6).accessibilityLabel("New") }
                        if needs { Circle().fill(Tokens.needs).frame(width: 6, height: 6).accessibilityLabel("Needs you") }
                    }
                }
                Text(label).font(Tokens.font(Tokens.textBase)).lineLimit(1)
            }
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, 16).frame(height: 34)
            .background(Tokens.pill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// One kind of work's page (Sangam's GroupView.tsx): its name, Running and Completed tabs with
/// their counts (Review PR and Issues have To do first, for GitHub's items no job works on yet), a
/// card per task under the open tab, and under Completed the way to Archived.
struct KindPage: View {
    @Environment(Phone.self) private var phone
    @Environment(\.push) private var push
    let kind: WorkType
    /// The tab picked, or nil for the one it opens on.
    @State private var picked: WorkList.Tab?
    /// Issues and Review PR each remember which projects, repositories and milestones to show. Empty shows every one.
    @AppStorage("githubProjects.issues") private var issuesProjects = ""
    @AppStorage("githubProjects.review") private var reviewProjects = ""
    @AppStorage("githubRepos.issues") private var issuesRepos = ""
    @AppStorage("githubRepos.review") private var reviewRepos = ""
    @AppStorage("githubMilestones.issues") private var issuesMilestones = ""
    @AppStorage("githubMilestones.review") private var reviewMilestones = ""

    /// GitHub's part of the page: only Review PR and Issues have one.
    private var gitHub: Bool { kind == .review || kind == .issues }
    private var connect: GitHubWork.Connect { gitHub ? .init(phone.gitHubWork) : .unknown }
    /// Routines only: each routine's next run.
    private var upcoming: [RunnerRoutine] { kind == .routines ? RunnerRoutine.upcoming(phone.routines) : [] }
    /// To do is where the page opens, unless a job runs or needs you, only when it has something:
    /// GitHub's items, or Connect GitHub.
    private var opensOnToDo: Bool { gitHub && (!toDo.isEmpty || connect == .signedOut) }
    private var toDo: [GitHubWork.Column] { gitHub ? phone.gitHubWork?.toDo(kind, later: phone.gitHubLater) ?? [] : [] }

    /// GitHub's sign-in is the Mac's alone: a paired phone never signs the Mac in to someone's GitHub.
    static let connectLine = "See the pull requests waiting for your review and the issues assigned to you here, and hand any of them to Oby in one tap. Connect GitHub on your Mac, in Settings › Connectors."

    var body: some View {
        let items = WorkList.ranked(phone.work.filter { $0.type == kind })
        let tab = picked ?? WorkList.firstTab(items, toDo: opensOnToDo)
        let columns = GitHubWork.columns(toDo, picked: GitHubWork.projectSet(projectRaw.wrappedValue), repos: GitHubWork.projectSet(repoRaw.wrappedValue), milestones: GitHubWork.projectSet(milestoneRaw.wrappedValue))
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.label).font(Tokens.font(28, .semibold)).foregroundStyle(Tokens.ink)
                    .padding(.bottom, 12).accessibilityAddTraits(.isHeader)
                LineTabs(tab: tab, counts: WorkList.counts(items, toDo: gitHub ? columns.reduce(0) { $0 + $1.items.count } : nil, upcoming: upcoming.count)) {
                    picked = $0
                }
                .padding(.bottom, 8)
                if gitHub && tab == .todo {
                    WorkFilters(columns: toDo, projects: projectRaw, repos: repoRaw, milestones: milestoneRaw)
                }
                let cards = WorkList.items(items, in: tab)
                if tab == .todo {
                    GitHubToDo(kind: kind, work: phone.gitHubWork, columns: columns,
                               connect: connect == .signedOut ? ConnectGitHubCard(line: Self.connectLine, connect: nil) : nil,
                               loading: !phone.loaded && phone.connection == .connecting,
                               start: { try await phone.startGitHubWork($0.id) }, later: { phone.gitHubLater.insert($0.id) })
                }
                // A routine waiting for its next run says when (Sangam's tasks.ts).
                if tab == .running { ForEach(upcoming) { UpcomingRoutineCard(routine: $0) } }
                ForEach(cards) { TaskCard(item: $0) }
                if tab != .todo && cards.isEmpty && (tab == .done || upcoming.isEmpty) {
                    if !phone.loaded && phone.connection == .connecting {
                        CardBones(rows: 2)
                    } else {
                        Text(tab == .done ? "Nothing completed yet" : "Nothing running")
                            .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.vertical, 8).padding(.horizontal, 4)
                    }
                }
                if tab == .done {
                    Button("Older ones are in Archived") { push(.archived) }
                        .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                        .padding(.top, 8).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Tokens.gutter).padding(.top, 8).padding(.bottom, 32)
        }
        .obyPage()
        .navigationBarTitleDisplayMode(.inline)
        // The tab it opens on stays put while you're on it, so a task arriving doesn't switch it.
        // On Review PR and Issues it waits for GitHub's list, so it doesn't settle on an empty Running first.
        .onAppear { if !gitHub || phone.gitHubWork != nil { picked = picked ?? WorkList.firstTab(items, toDo: opensOnToDo) } }
        .onChange(of: phone.gitHubWork == nil) { if picked == nil { picked = WorkList.firstTab(items, toDo: opensOnToDo) } }
        .refreshable { await phone.reload() }
        // Opening Review PR or Issues looks at GitHub again; the list arrives as an event.
        .task { if gitHub { await phone.refreshGitHubWork() } }
    }

    private var projectRaw: Binding<String> { stored($issuesProjects, $reviewProjects) }
    private var repoRaw: Binding<String> { stored($issuesRepos, $reviewRepos) }
    private var milestoneRaw: Binding<String> { stored($issuesMilestones, $reviewMilestones) }

    private func stored(_ issues: Binding<String>, _ review: Binding<String>) -> Binding<String> {
        switch kind {
        case .issues: issues
        case .review: review
        default: .constant("")
        }
    }
}

/// Every task Home lists (Sangam's side panel): by kind of work or by status, each group's done
/// ones capped behind Show more; Clear done, and the way to Archived.
struct AllTasksPage: View {
    @Environment(Phone.self) private var phone
    @Environment(\.push) private var push
    @AppStorage(GroupBy.key) private var groupBy = GroupBy.type
    @State private var more: Set<String> = []
    @State private var problem: String?

    var body: some View {
        let groups = WorkList.groups(phone.work, by: groupBy)
        List {
            if groups.isEmpty {
                if !phone.loaded && phone.connection == .connecting {
                    RowBones().listRowBackground(Color.clear)
                } else {
                    Text(phone.loaded ? "Nothing yet. Ask Oby for something on Home." : "Reaching the runner…")
                        .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted)
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(groups) { group in
                let shown = WorkList.shown(group, more: more.contains(group.id))
                Section {
                    ForEach(shown.rows) { item in
                        Button { push(.task(item.id)) } label: { TaskRow(item: item) }
                            .listRowBackground(Tokens.surface)
                    }
                    if shown.hidden > 0 {
                        Button(more.contains(group.id) ? "Show less" : "Show \(shown.hidden) more") {
                            if more.contains(group.id) { more.remove(group.id) } else { more.insert(group.id) }
                        }
                        .font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted)
                        .listRowBackground(Tokens.surface)
                    }
                } header: {
                    Text("\(group.label) · \(group.count) \(group.countLabel)").font(Tokens.font(Tokens.textMd, .medium)).foregroundStyle(Tokens.item)
                        .textCase(nil)
                }
            }
            Section {
                Button("Archived") { push(.archived) }.foregroundStyle(Tokens.ink).listRowBackground(Tokens.surface)
            } footer: {
                if let problem { Text(problem).foregroundStyle(Tokens.danger) }
            }
        }
        .obyPage()
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await phone.reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Group by", selection: $groupBy) {
                        ForEach(GroupBy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    // Through the runner (it keeps the time), so the Mac's window clears too.
                    Button("Clear done") {
                        Task { do { try await phone.clear(); problem = nil } catch { problem = error.localizedDescription } }
                    }
                    .disabled(!phone.visibleJobs.contains { $0.clearable(among: phone.jobs) })
                } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Group by")
            }
        }
    }
}

/// A task in a list: its mark, its agent's mark, its title, and how long ago.
private struct TaskRow: View {
    let item: WorkList.Item<Job>

    var body: some View {
        HStack(spacing: 10) {
            AgentMark(agent: item.job.agent).font(Tokens.font(12, .semibold)).frame(width: 16).foregroundStyle(Tokens.muted)
            Text(item.job.heading).font(Tokens.font(Tokens.textBase))
                .foregroundStyle(item.status == .done ? Tokens.doneTitle : Tokens.openTitle).lineLimit(1)
            Spacer(minLength: 8)
            Text(TaskFacts.ago(item.job)).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
            WorkMarkView(mark: item.mark)
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.mark.rawValue)
    }
}

/// Archived (Sangam's ArchiveView.tsx), kept by this iPhone: the done tasks that left Home, most
/// recently done first, with a search over them.
struct ArchivedPage: View {
    @Environment(Phone.self) private var phone
    @Environment(\.push) private var push
    @State private var query = ""

    var body: some View {
        let all = phone.archived.sorted { ($0.finished ?? $0.created) > ($1.finished ?? $1.created) }
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = all.filter { q.isEmpty || "\($0.heading) \($0.agentName) \($0.repoName)".localizedCaseInsensitiveContains(q) }
        List {
            ForEach(shown) { job in
                Button { push(.task(job.id)) } label: {
                    HStack(spacing: 10) {
                        AgentMark(agent: job.agent).font(Tokens.font(12, .semibold)).frame(width: 16).foregroundStyle(Tokens.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.heading).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.item).lineLimit(1)
                            Text(TaskMeta.line(job, account: phone.accountName(job.account))).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(ConversationOrder.ago(job.finished ?? job.created)).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                    }
                    .frame(minHeight: 44)
                }
                .listRowBackground(Tokens.surface)
            }
            if shown.isEmpty {
                Text(all.isEmpty ? "Nothing archived yet" : "Nothing archived matches “\(q)”")
                    .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).listRowBackground(Color.clear)
            }
        }
        .searchable(text: $query, prompt: "Search archived tasks")
        .obyPage()
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The Inbox (docs/oby-ux.md row 10): what only you can answer and has no task on Home (an audit,
/// an Oby failure, a task older than the list), the longest-waiting first. The rest live with
/// their task: on its card, its page and in its conversation.
struct InboxPage: View {
    @Environment(Phone.self) private var phone

    var body: some View {
        // Every half minute: what was put off comes back.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let items = PhoneWork.loose(InboxItem.waiting(phone.inbox, now: context.date), among: phone.work)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Inbox").font(Tokens.font(28, .semibold)).foregroundStyle(Tokens.ink).padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.line(now: context.date)).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).lineLimit(1)
                            InboxDecision(item: item, openTask: true)
                        }
                    }
                    if items.isEmpty {
                        Text("Nothing needs you").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted)
                    }
                }
                .padding(.horizontal, Tokens.gutter).padding(.top, 8).padding(.bottom, 32)
            }
        }
        .obyPage()
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await phone.reload() }
    }
}
