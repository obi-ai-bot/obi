import SwiftUI

/// One kind of work's page (#496, Sangam's GroupView): its name, Running and Completed tabs with
/// their counts, and a card per task under the open tab. Under Completed, where older ones go.
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

    private var tab: WorkList.Tab { picked ?? WorkList.firstTab(items) }
    private var ranked: [WorkList.Item<SidebarSections.JobRow>] { WorkList.ranked(items) }
    private var feed: RunnerFeed { model.feed }
    /// GitHub's part of the page: only Review PR and Issues have one.
    private var gitHub: Bool { kind == .review || kind == .issues }
    private var connect: GitHubWork.Connect { gitHub ? .init(feed.gitHubWork) : .unknown }
    /// Routines only: each routine's next run.
    private var upcoming: [RunnerRoutine] { kind == .routines ? RunnerRoutine.upcoming(feed.routines) : [] }
    private var waiting: [GitHubWork.Item] { gitHub ? feed.gitHubWork?.waiting(kind, later: feed.gitHubLater) ?? [] : [] }

    static let connectLine = "See the pull requests waiting for your review and the issues assigned to you here, and hand any of them to Oby in one click. Signing in uses GitHub's own page; GitHub's CLI keeps the login."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.label).font(Tokens.font(28, .semibold)).foregroundStyle(Tokens.ink)
                    .padding(.bottom, 16).accessibilityAddTraits(.isHeader)
                LineTabs(tab: tab, counts: Dictionary(uniqueKeysWithValues: WorkList.Tab.allCases.map {
                    ($0, WorkList.items(items, in: $0).count + ($0 == .running ? waiting.count + upcoming.count : 0))
                })) {
                    picked = $0
                }
                .padding(.bottom, 16)
                let cards = WorkList.items(ranked, in: tab)
                if tab == .running {
                    // A routine waiting for its next run says when (Sangam's tasks.ts).
                    ForEach(upcoming) { UpcomingRoutineCard(routine: $0) }
                    if connect == .signedOut {
                        ConnectGitHubCard(line: Self.connectLine, connect: onConnectGitHub)
                    }
                    ForEach(waiting) { item in
                        GitHubCard(item: item, start: { try await feed.startGitHubWork(item.id) },
                                   later: { feed.gitHubLater.insert(item.id) })
                    }
                    ForEach(feed.gitHubWork?.cut(kind) ?? [], id: \.self) { line in
                        Text(line).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.horizontal, 4)
                    }
                    if let problem = feed.gitHubWork?.error {
                        Text(verbatim: GitHubWork.plain(problem)).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.horizontal, 4)
                    }
                }
                ForEach(cards) { item in
                    TaskCardView(item: item, model: model) { onOpenJob(item.job.job.id, item.job.local) }
                }
                if cards.isEmpty && (tab == .done || waiting.isEmpty && upcoming.isEmpty && connect != .signedOut) {
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
        .onAppear { picked = picked ?? (waiting.isEmpty ? WorkList.firstTab(items) : .running) }
        // Opening Review PR or Issues looks at GitHub again; the list arrives as an event.
        .task { if gitHub { await feed.refreshGitHubWork() } }
    }
}
