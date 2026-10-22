import SwiftUI

/// One kind of work's page (#496, Sangam's GroupView): its name, Running and Completed tabs with
/// their counts (Review PR and Issues have To do first, for GitHub's items no job works on yet),
/// and a card per task under the open tab. Under Completed, where older ones go.
struct GroupPane: View {
    let model: IslandModel
    let state: ChatState
    let kind: WorkType
    /// The kind's tasks, in Home's order (`WorkList.ranked`).
    let items: [WorkList.Item<SidebarSections.JobRow>]
    let onOpenJob: (_ job: String, _ local: Bool) -> Void
    let onOpenArchive: () -> Void
    /// Connect GitHub: Settings › Connectors, where GitHub's row signs obid's gh in with GitHub's
    /// own device sign-in (#690).
    let onConnectGitHub: () -> Void
    /// Back where it was opened from: a click on the page that isn't on its title, tabs, a card or a link.
    let onClose: () -> Void
    /// The tab picked, or nil for the one it opens on (`WorkList.firstTab`).
    @State private var picked: WorkList.Tab?
    /// Issues and Review PR each remember which projects, repositories and milestones to show. Empty shows every one.
    @AppStorage("githubProjects.issues") private var issuesProjects = ""
    @AppStorage("githubProjects.review") private var reviewProjects = ""
    @AppStorage("githubRepos.issues") private var issuesRepos = ""
    @AppStorage("githubRepos.review") private var reviewRepos = ""
    @AppStorage("githubMilestones.issues") private var issuesMilestones = ""
    @AppStorage("githubMilestones.review") private var reviewMilestones = ""
    /// The page's height, so the empty space under a short list closes it too.
    @State private var height: CGFloat = 0

    private var tab: WorkList.Tab { picked ?? WorkList.firstTab(items, toDo: opensOnToDo) }
    private var ranked: [WorkList.Item<SidebarSections.JobRow>] { WorkList.ranked(items) }
    private var feed: RunnerFeed { model.feed }
    /// GitHub's part of the page: only Review PR and Issues have one.
    private var gitHub: Bool { kind == .review || kind == .issues }
    private var connect: GitHubWork.Connect { gitHub ? .init(feed.gitHubWork) : .unknown }
    /// Routines only: each routine's next run.
    private var upcoming: [RunnerRoutine] { kind == .routines ? RunnerRoutine.upcoming(feed.routines) : [] }
    /// To do is where the page opens, unless a job runs or needs you, only when it has something:
    /// GitHub's items, or Connect GitHub.
    private var opensOnToDo: Bool { gitHub && (!toDo.isEmpty || connect == .signedOut) }
    private var toDo: [GitHubWork.Column] { gitHub ? feed.gitHubWork?.toDo(kind, later: feed.gitHubLater) ?? [] : [] }

    static let archivedLink = "Older ones are in Archived"

    static let connectLine = "See the pull requests waiting for your review and the issues assigned to you here, and hand any of them to Oby in one click. Signing in uses GitHub's own page; GitHub's CLI keeps the login."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.label).font(Tokens.font(28, .semibold)).foregroundStyle(Tokens.ink)
                    .padding(.bottom, 16).accessibilityAddTraits(.isHeader)
                let columns = GitHubWork.columns(toDo, picked: GitHubWork.projectSet(projectRaw.wrappedValue), repos: GitHubWork.projectSet(repoRaw.wrappedValue), milestones: GitHubWork.projectSet(milestoneRaw.wrappedValue))
                LineTabs(tab: tab, counts: WorkList.counts(items, toDo: gitHub ? columns.reduce(0) { $0 + $1.items.count } : nil, upcoming: upcoming.count)) {
                    picked = $0
                }
                .contentShape(Rectangle())
                .padding(.bottom, 8)
                if gitHub && tab == .todo {
                    WorkFilters(columns: toDo, projects: projectRaw, repos: repoRaw, milestones: milestoneRaw)
                        .padding(.bottom, 8)
                }
                let cards = WorkList.items(ranked, in: tab)
                if tab == .todo {
                    GitHubToDo(kind: kind, work: feed.gitHubWork, columns: columns,
                               connect: connect == .signedOut ? ConnectGitHubCard(line: Self.connectLine, connect: onConnectGitHub) : nil,
                               loading: gitHub && feed.gitHubWork == nil && !feed.gitHubListed && !feed.down,
                               start: { try await feed.startGitHubWork($0.id) }, later: { feed.gitHubLater.insert($0.id) })
                }
                // A routine waiting for its next run says when (Sangam's tasks.ts).
                if tab == .running { ForEach(upcoming) { UpcomingRoutineCard(routine: $0) } }
                ForEach(cards) { item in
                    TaskCardView(item: item, model: model, state: state) { onOpenJob(item.job.job.id, item.job.local) }
                }
                if tab != .todo && cards.isEmpty && (tab == .done || upcoming.isEmpty) {
                    if feed.connection == .connecting && !feed.showingKept {
                        CardBones(rows: 2)
                    } else {
                        Text(tab == .done ? "Nothing completed yet" : "Nothing running")
                            .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.vertical, 8).padding(.horizontal, 4)
                    }
                }
                // Completed ones leave Home after a while (Archive completed, in Home's ⋮).
                if tab == .done {
                    // The row's full width, as the design's `.group-archived`: a click beside the words opens it too.
                    Button(action: onOpenArchive) { Text(Self.archivedLink).frame(maxWidth: .infinity).contentShape(Rectangle()) }
                        .buttonStyle(LinkTextStyle()).padding(.top, 8)
                }
            }
            .frame(maxWidth: Tokens.column, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.gutter).padding(.top, 16).padding(.bottom, 32)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .top)
            // Under the page's content, so only a click that lands on nothing else closes it (Sangam's GroupView).
            // A button, not a tap gesture: a tap gesture there never fires inside the scroll view.
            .background { Button(action: onClose) { Tokens.bg }.buttonStyle(.plain).accessibilityHidden(true) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .scrollIndicators(.never)
        // The tab it opens on stays put while you're on it, so a task arriving doesn't switch it.
        // On Review PR and Issues it waits for GitHub's list, so it doesn't settle on an empty Running first.
        .onAppear { if !gitHub || feed.gitHubWork != nil { picked = picked ?? WorkList.firstTab(items, toDo: opensOnToDo) } }
        .onChange(of: feed.gitHubWork == nil) { if picked == nil { picked = WorkList.firstTab(items, toDo: opensOnToDo) } }
        // Opening Review PR or Issues looks at GitHub again; the list arrives as an event.
        .task { if gitHub { await feed.refreshGitHubWork() } }
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

/// Archived (Sangam's ArchiveView): every done task that left Home, most recently done first, with
/// a search over them at the top. A row opens its page.
struct ArchivePane: View {
    let items: [WorkList.Item<SidebarSections.JobRow>]
    var loading = false
    let onOpenJob: (_ job: String, _ local: Bool) -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    /// The rows matching `query` in their name, kind of work or agent, any case.
    nonisolated static func matching(_ items: [WorkList.Item<SidebarSections.JobRow>], _ query: String) -> [WorkList.Item<SidebarSections.JobRow>] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return items.filter { q.isEmpty || "\($0.job.job.heading) \($0.type.label) \($0.job.job.agentName)".localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let shown = Self.matching(items, query)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Archived").font(Tokens.font(28, .semibold)).foregroundStyle(Tokens.ink)
                    .padding(.bottom, 16).accessibilityAddTraits(.isHeader)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(Tokens.font(14)).foregroundStyle(Tokens.muted)
                    TextField("Search archived tasks", text: $query).textFieldStyle(.plain)
                        .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.ink).focused($searching)
                }
                .padding(.horizontal, 14).frame(height: 40)
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(searching ? Tokens.lineFocus : Tokens.line) }
                VStack(spacing: 2) {
                    ForEach(shown) { item in ArchiveRow(item: item) { onOpenJob(item.job.job.id, item.job.local) } }
                }
                if shown.isEmpty {
                    if loading && query.trimmingCharacters(in: .whitespaces).isEmpty {
                        RowBones(rows: 4)
                    } else {
                        Text(items.isEmpty ? "Nothing archived yet" : "Nothing archived matches “\(query.trimmingCharacters(in: .whitespaces))”")
                            .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.vertical, 8).padding(.horizontal, 4)
                    }
                }
            }
            .frame(maxWidth: Tokens.column, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.gutter).padding(.top, 16).padding(.bottom, 32)
        }
        .scrollIndicators(.never)
    }
}

/// One archived task (Sangam's `.archive-row`): its agent's mark, its name, its kind and agent under
/// it, and how long ago it was done.
private struct ArchiveRow: View {
    let item: WorkList.Item<SidebarSections.JobRow>
    let action: () -> Void
    @State private var hovering = false

    private var job: Job { item.job.job }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AgentMark(agent: job.agent).font(Tokens.font(13, .semibold)).frame(width: 16).foregroundStyle(Tokens.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.heading).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.item).fadeOut()
                    Text("\(item.type.label) · \(job.agentName)").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(ConversationOrder.ago(job.finished ?? job.created)).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(hovering ? Tokens.hover : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Tokens.fade, value: hovering)
    }
}

/// Small muted words that light up hovered (Sangam's `.group-archived`).
private struct LinkTextStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label.font(Tokens.font(Tokens.textSm))
                .foregroundStyle(hovering ? Tokens.text : Tokens.muted)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Tokens.fade, value: hovering)
        }
    }
}
