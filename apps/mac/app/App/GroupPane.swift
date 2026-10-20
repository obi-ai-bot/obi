import SwiftUI

/// One kind of work's page (#496, Sangam's GroupView): its name, Running and Completed tabs with
/// their counts (Review PR and Issues have To do first, for GitHub's items no job works on yet),
/// and a card per task under the open tab. Under Completed, where older ones go.
struct GroupPane: View {
    let model: IslandModel
    let kind: WorkType
    /// The kind's tasks, in Home's order (`WorkList.ranked`).
    let items: [WorkList.Item<SidebarSections.JobRow>]
    let onOpenJob: (_ job: String, _ local: Bool) -> Void
    /// Connect GitHub: Settings › Connectors, where GitHub's row signs obid's gh in with GitHub's
    /// own device sign-in (#690).
    let onConnectGitHub: () -> Void
    /// The tab picked, or nil for the one it opens on (`WorkList.firstTab`).
    @State private var picked: WorkList.Tab?

    /// Archived (#280) isn't on the Mac yet: until it is, Clear done takes finished jobs off the list.
    static let archivedLine = "Older ones will be in Archived, which isn't on the Mac yet. Until then, Clear done (in Home's ⋮) takes them off this list."

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

    static let connectLine = "See the pull requests waiting for your review and the issues assigned to you here, and hand any of them to Oby in one click. Signing in uses GitHub's own page; GitHub's CLI keeps the login."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.label).font(Tokens.font(28, .semibold)).foregroundStyle(Tokens.ink)
                    .padding(.bottom, 16).accessibilityAddTraits(.isHeader)
                let columns = toDo
                LineTabs(tab: tab, counts: WorkList.counts(items, toDo: gitHub ? columns.reduce(0) { $0 + $1.items.count } : nil, upcoming: upcoming.count)) {
                    picked = $0
                }
                .padding(.bottom, 16)
                let cards = WorkList.items(ranked, in: tab)
                if tab == .todo {
                    GitHubToDo(kind: kind, work: feed.gitHubWork, columns: columns,
                               connect: connect == .signedOut ? ConnectGitHubCard(line: Self.connectLine, connect: onConnectGitHub) : nil,
                               start: { try await feed.startGitHubWork($0.id) }, later: { feed.gitHubLater.insert($0.id) })
                }
                // A routine waiting for its next run says when (Sangam's tasks.ts).
                if tab == .running { ForEach(upcoming) { UpcomingRoutineCard(routine: $0) } }
                ForEach(cards) { item in
                    TaskCardView(item: item, model: model) { onOpenJob(item.job.job.id, item.job.local) }
                }
                if tab != .todo && cards.isEmpty && (tab == .done || upcoming.isEmpty) {
                    Text(tab == .done ? "Nothing completed yet" : "Nothing running")
                        .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.vertical, 8).padding(.horizontal, 4)
                }
                if tab == .done {
                    Text(Self.archivedLine).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                        .padding(.top, 8).padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: Tokens.column, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.gutter).padding(.top, 16).padding(.bottom, 32)
        }
        .scrollIndicators(.never)
        // The tab it opens on stays put while you're on it, so a task arriving doesn't switch it.
        // On Review PR and Issues it waits for GitHub's list, so it doesn't settle on an empty Running first.
        .onAppear { if !gitHub || feed.gitHubWork != nil { picked = picked ?? WorkList.firstTab(items, toDo: opensOnToDo) } }
        .onChange(of: feed.gitHubWork == nil) { if picked == nil { picked = WorkList.firstTab(items, toDo: opensOnToDo) } }
        // Opening Review PR or Issues looks at GitHub again; the list arrives as an event.
        .task { if gitHub { await feed.refreshGitHubWork() } }
    }
}
