import Foundation
import Testing
@testable import Oby

/// Work grouped by kind (#496, apps/shared/JobList.swift and apps/mac/app/App/Sidebar.swift):
/// reviews, issues, a teammate's requests and your tasks each in their group, the switch to status,
/// what a group shows and its page's tabs, as Sangam's design has them (design/app, tasks.ts).
struct WorkGroupsTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    func job(_ id: String, kind: Plan.Kind = .build, issue: Int? = nil, status: Job.Status = .running, created: TimeInterval = 0) -> Job {
        var job = Job(id: id, request: "work on oby", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/\(id)", base: "dev", pr: nil, kind: kind, task: "Work", created: now - created)
        job.status = status
        job.issue = issue
        job.title = "Job \(id)"
        return job
    }

    func item(_ id: String, _ type: WorkType = .tasks, _ status: WorkStatus = .running, queued: Bool = false, fresh: Bool = false) -> WorkList.Item<String> {
        WorkList.Item(id: id, job: id, type: type, status: status, queued: queued, fresh: fresh)
    }

    /// A pull request to review, an issue's fix and a task asked in Oby are three kinds of work; a
    /// request from a teammate's Oby goes under that teammate, whatever it asks for.
    @Test func eachJobBelongsToOneKindOfWork() {
        #expect(WorkType.of(review: true, issue: nil, requester: nil) == .review)
        #expect(WorkType.of(review: true, issue: 12, requester: nil) == .review)
        #expect(WorkType.of(review: false, issue: 12, requester: nil) == .issues)
        #expect(WorkType.of(review: false, issue: nil, requester: nil) == .tasks)
        #expect(WorkType.of(review: true, issue: nil, requester: "Wellington") == .teammate("Wellington"))
        #expect(WorkType.of(review: false, issue: nil, requester: " ") == .tasks)
        // A routine's run goes under Routines, whatever it does (#395, Sangam's tasks.ts).
        #expect(WorkType.of(review: true, issue: 12, requester: nil, routine: true) == .routines)
        #expect(WorkType.routines.label == "Routines")
        #expect([WorkType.review, .issues, .teammate("Wellington"), .tasks].map(\.label) == ["Review PR", "Issues", "Wellington", "Tasks"])
    }

    /// The Mac's own and the runner's jobs: a review, an issue fix and a typed task land in three
    /// groups (the issue's first test), and grouping by status puts them by where they stand.
    @Test func aReviewAnIssueAndATaskLandInThreeGroupsThenRegroupByStatus() {
        let review = job("rv", kind: .review, status: .running, created: 30)
        let fix = job("fx", kind: .fix, issue: 251, status: .failed, created: 20)
        let typed = job("tk", status: .done, created: 10)
        let items = SidebarSections.work(local: [fix, typed], runner: [review], since: now - 3600, seen: [])
        let byType = WorkList.groups(items, by: .type)
        #expect(byType.map(\.label) == ["Review PR", "Issues", "Tasks"])
        #expect(byType.map { $0.items.map(\.id) } == [["runner/rv"], ["mac/fx"], ["mac/tk"]])
        let byStatus = WorkList.groups(items, by: .status)
        #expect(byStatus.map(\.label) == ["Needs you", "Running", "Completed"])
        #expect(byStatus.map { $0.items.map(\.id) } == [["mac/fx"], ["runner/rv"], ["mac/tk"]])
    }

    /// The runner this Mac talks to says nothing of who asked for a job (only obid's jobs carry
    /// `obi.fromOwner`, docs/runner-api.md), so the Mac shows no teammate group rather than
    /// inventing one.
    @Test func theMacShowsNoTeammateGroupWhileItsRunnerNamesNoRequester() {
        let items = SidebarSections.work(local: [job("a"), job("b", kind: .review)], runner: [], since: now, seen: [])
        #expect(!items.contains { if case .teammate = $0.type { true } else { false } })
    }

    /// One mark per row: new until opened, needs you, working, queued, done. A job needs you when it
    /// failed, waits for Publish, or waits for an answer; queued counts as running.
    @Test func eachRowHasOneStatusMark() {
        var asking = job("ask", status: .running)
        asking.question = Plan.Question(text: "Which branch?", options: [])
        let rows = [job("w", status: .running, created: 50), job("q", status: .queued, created: 40),
                    job("f", status: .failed, created: 30), asking, job("d", status: .done, created: 20)]
        let items = SidebarSections.work(local: rows, runner: [], since: .distantFuture, seen: [])
        let marks = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.mark) })
        #expect(marks == ["mac/w": .working, "mac/q": .queued, "mac/f": .needs, "mac/ask": .needs, "mac/d": .done])
        #expect(items.first { $0.id == "mac/q" }?.status == .running)
        // New: arrived after the window's Oby started, and not opened yet; whatever its state.
        let fresh = SidebarSections.work(local: [job("n", status: .failed, created: 5), job("o", created: 7200)], runner: [], since: now - 60, seen: [])
        #expect(fresh.map(\.mark) == [.new, .working])
        #expect(SidebarSections.work(local: [job("n", created: 5)], runner: [], since: now - 60, seen: ["mac/n"]).map(\.mark) == [.working])
        #expect([WorkMark.new, .needs, .working, .queued, .done].map(\.rawValue) == ["New", "Needs you", "Working", "Queued", "Done"])
    }

    /// "The latest done" are the last to finish: a long job that just finished comes before quick
    /// ones started after it, so Show more doesn't hide it.
    @Test func theLatestDoneAreTheLastToFinish() {
        var long = job("long", status: .done, created: 7200)
        long.finished = now - 10
        var quick = job("quick", status: .done, created: 600)
        quick.finished = now - 300
        let running = job("run", status: .running, created: 60)
        let items = SidebarSections.work(local: [quick, running, long], runner: [], since: .distantFuture, seen: [])
        #expect(items.map(\.id) == ["mac/long", "mac/run", "mac/quick"])
    }

    /// Kinds in their order, teammates by name between Issues and Tasks; empty kinds left out. Each
    /// counts its open tasks (running or needing you) and how many need you, and says when one's new.
    @Test func groupsByTypeCountWhatIsOpen() {
        let items = [item("t1", .tasks, .done), item("w1", .teammate("Wellington"), .needs), item("r1", .review, .running, fresh: true),
                     item("d1", .teammate("Dima")), item("t2", .tasks, .needs), item("t3", .tasks, .running, queued: true)]
        let groups = WorkList.groups(items, by: .type)
        #expect(groups.map(\.id) == ["review", "teammate:Dima", "teammate:Wellington", "tasks"])
        #expect(groups.map(\.type) == [.review, .teammate("Dima"), .teammate("Wellington"), .tasks])
        #expect(groups.map(\.count) == [1, 1, 1, 2])
        #expect(groups.map(\.countLabel) == ["open", "open", "open", "open"])
        #expect(groups.map(\.needs) == [0, 0, 1, 1])
        #expect(groups.map(\.fresh) == [true, false, false, false])
        // Fresh first, then what needs you, then what waits to start; the rest as they came.
        #expect(groups[3].items.map(\.id) == ["t2", "t3", "t1"])
    }

    /// By status: Needs you, Running, Completed, each counting all it holds.
    @Test func groupsByStatusCountEverything() {
        let items = [item("a", .tasks, .done), item("b", .review, .running), item("c", .issues, .done), item("d", .tasks, .needs)]
        let groups = WorkList.groups(items, by: .status)
        #expect(groups.map(\.id) == ["status:needs", "status:running", "status:done"])
        #expect(groups.map(\.count) == [1, 1, 2])
        #expect(groups.map(\.countLabel) == ["tasks", "tasks", "tasks"])
        #expect(groups.map(\.needs) == [1, 0, 0])
        #expect(WorkList.groups([item("b", .review, .running)], by: .status).map(\.id) == ["status:running"])
    }

    /// A group shows everything still open and its latest 3 done (5 under Completed), then Show more.
    @Test func aGroupShowsItsLatestThreeDoneThenShowMore() {
        let done = (1...6).map { item("d\($0)", .tasks, .done) }
        let group = WorkList.groups([item("o1")] + done + [item("o2", .tasks, .needs)], by: .type)[0]
        let shown = WorkList.shown(group, more: false)
        #expect(shown.rows.map(\.id) == ["o2", "o1", "d1", "d2", "d3"])
        #expect(shown.hidden == 3)
        #expect(WorkList.shown(group, more: true).rows.count == 8)
        let completed = WorkList.groups(done, by: .status)[0]
        #expect(WorkList.shown(completed, more: false).rows.map(\.id) == ["d1", "d2", "d3", "d4", "d5"])
        #expect(WorkList.shown(completed, more: false).hidden == 1)
        #expect(WorkList.shown(WorkList.groups([item("o1")], by: .type)[0], more: false).hidden == 0)
    }

    /// A kind's page: Running holds everything not done, what needs you included; Completed the
    /// rest. It opens where the new task is, else on Running while anything's open, else Completed.
    @Test func aGroupPageHasRunningAndCompletedTabs() {
        let items = [item("n", .tasks, .needs), item("r", .tasks, .running), item("d", .tasks, .done)]
        #expect(WorkList.Tab.allCases.map(\.rawValue) == ["To do", "Running", "Completed"])
        #expect(WorkList.items(items, in: .todo).isEmpty)
        #expect(WorkList.items(items, in: .running).map(\.id) == ["n", "r"])
        #expect(WorkList.items(items, in: .done).map(\.id) == ["d"])
        #expect(WorkList.firstTab(items) == .running)
        #expect(WorkList.firstTab([item("d", .tasks, .done)]) == .done)
        #expect(WorkList.firstTab([item("r"), item("d", .tasks, .done, fresh: true)]) == .done)
        #expect(WorkList.firstTab([WorkList.Item<String>]()) == .running)
    }

    /// Review PR and Issues: GitHub's items no job works on count under To do alone, never under
    /// Running; the page opens on Running while a job runs or needs you, else on To do.
    @Test func gitHubItemsAreToDoNeverRunning() {
        let done = [item("d", .issues, .done)]
        #expect(WorkList.counts(done, toDo: 57) == [.todo: 57, .running: 0, .done: 1])
        #expect(WorkList.counts(done, toDo: nil, upcoming: 2) == [.running: 2, .done: 1])
        #expect(WorkList.firstTab(done, toDo: true) == .todo)
        // With nothing to do (and GitHub connected), it never opens on an empty To do.
        #expect(WorkList.firstTab(done, toDo: false) == .done)
        #expect(WorkList.firstTab([WorkList.Item<String>](), toDo: false) == .running)
        #expect(WorkList.firstTab(done + [item("n", .issues, .needs)], toDo: true) == .running)
        #expect(WorkList.firstTab(done + [item("r", .issues, .running)], toDo: true) == .running)
    }

    /// Group by Type or Status, remembered under one key.
    @Test func groupByIsTypeUnlessStatusWasPicked() {
        #expect(GroupBy.allCases.map(\.label) == ["Type", "Status"])
        #expect(GroupBy(rawValue: "status") == .status && GroupBy(rawValue: "type") == .type)
        #expect(GroupBy.key == "ObyGroupBy")
    }

    /// Home's chips: every kind with work in it, a blue dot for a new task and an orange one when
    /// something in it needs you; both can show.
    @Test func chipsShowABlueDotForNewAndAnOrangeOneForNeedsYou() {
        let chips = WorkList.groups([item("a", .review, .running, fresh: true), item("b", .issues, .needs),
                                     item("c", .tasks, .needs, fresh: true), item("d", .tasks, .done)], by: .type)
        #expect(chips.map(\.fresh) == [true, false, true])
        #expect(chips.map { $0.needs > 0 } == [false, true, true])
    }
}
