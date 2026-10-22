import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The one line Home's header on the iPhone and the window's menu bar on the
/// Mac all say about the jobs: who's working, who waits, and what needs you. Foundation only: the
/// runner's tests build it too.
nonisolated enum Summary {
    static let quiet = "All quiet."

    /// "2 agents are working. 1 job failed.", "1 agent is working, 14 waiting. Nothing needs you.",
    /// "3 jobs are waiting.", "1 job is ready to publish." or "All quiet." Only working jobs count
    /// as agents working; jobs queued behind something are `waiting` (#238). `needs` is
    /// `NeedsYou.line` over the jobs shown, without its full stop.
    static func line(working: Int, waiting: Int = 0, needs: String?) -> String {
        let needs = needs.map { "\($0)." }
        if working == 0 && waiting == 0 { return needs ?? quiet }
        let agents = switch (working, waiting) {
        case (0, 1): "1 job is waiting."
        case (0, _): "\(waiting) jobs are waiting."
        case (1, 0): "1 agent is working."
        case (_, 0): "\(working) agents are working."
        case (1, _): "1 agent is working, \(waiting) waiting."
        default: "\(working) agents are working, \(waiting) waiting."
        }
        return "\(agents) \(needs ?? "Nothing needs you.")"
    }

    /// "14 waiting", or nil when none: the line under Live's working jobs on the Mac, and the
    /// Watch's, that opens the Waiting list.
    static func waitingLine(_ waiting: Int) -> String? { waiting == 0 ? nil : "\(waiting) waiting" }
}

/// The groups the job list shows, in this order, on the iPhone and the Mac. The raw value is the
/// heading. Working holds running jobs and ones getting ready; Waiting the ones queued behind
/// something, each saying what for (#238).
nonisolated enum JobGroup: String, CaseIterable, Hashable, Sendable {
    case working = "Working"
    case waiting = "Waiting"
    case needsYou = "Needs you"
    case inReview = "In review"
    case done = "Done"
}

/// The status pill on a job's row and screen: its words, and the colour both apps give them.
nonisolated struct JobBadge: Equatable, Sendable {
    enum Tone: Sendable { case blue, green, orange, red, gray }
    var text: String
    var tone: Tone

    /// A job queued behind something (#238), in gray: what it waits for goes on its row.
    static let waiting = JobBadge(text: "Waiting", tone: .gray)
}

/// The job list as both apps show it: the same groups in the same order, and the same jobs hidden
/// after Clear done.
nonisolated enum JobList {
    /// One group of the list, with its jobs in the list's own order.
    nonisolated struct Section<J>: Identifiable {
        var group: JobGroup
        var jobs: [J]
        var id: JobGroup { group }
    }

    /// `jobs` in their groups, in the groups' order, each keeping the order they came in (newest
    /// first); empty groups are left out.
    static func groups<J>(_ jobs: [J], by group: (J) -> JobGroup) -> [Section<J>] {
        let grouped = Dictionary(grouping: jobs, by: group)
        return JobGroup.allCases.compactMap { group in grouped[group].map { Section(group: group, jobs: $0) } }
    }

    /// Whether a job is settled, so Clear done may take it (#280): nothing more is to happen for it.
    /// Never while it's queued, running or waiting (`active`), or needs the user (ready to publish,
    /// failed, interrupted, out of review rounds: only Dismiss lets those go). Then always once the
    /// user dismissed or stopped it (`letGo`); else not while its pull request is open (in review,
    /// waiting for its checks or an account, about to merge), and, for a review job, not while the
    /// job it reviews isn't settled (`author`, nil when it's no review or its author isn't listed).
    /// So it's settled once its pull request was merged or closed, or it ended with nothing to publish.
    ///
    /// Changed 2026-10-13: a done job whose pull request is still open (in review, checking, about
    /// to merge) clears too, and its review with it. Oby carries it to the merge by itself, and the
    /// moment it needs you it isn't settled any more and comes back. Keeping them made Clear done
    /// look broken: it took nothing while every finished job waited on a review or a check.
    static func settled(active: Bool, needsYou: Bool, letGo: Bool, openPullRequest: Bool, author: Bool? = nil) -> Bool {
        !(active || needsYou)
    }

    /// Whether a job stays in the list after Clear done: it isn't `settled`, or `shows` keeps it
    /// by its finish time. The runner keeps only the clear's time; every app applies this rule.
    static func lists(settled: Bool, finished: Date?, clearedAt: Date?) -> Bool {
        !settled || shows(finished: finished, clearedAt: clearedAt)
    }

    /// Whether Clear done would take the job from the list: it's settled. While no listed job
    /// would go, neither the iPhone's Home nor the Mac's window offers Clear done.
    static func clears(settled: Bool) -> Bool { settled }

    /// Clear done by time alone: the job hasn't finished, nothing was ever cleared, or it finished
    /// after the last clear. A job that finished at the clear's second or before is hidden on
    /// every app, since the runner keeps the clear's time. `lists` is the whole rule.
    static func shows(finished: Date?, clearedAt: Date?) -> Bool {
        guard let finished, let clearedAt else { return true }
        return finished > clearedAt
    }

    /// A new list from the runner (its latest 50), keeping the jobs whose screens are open even
    /// when they're older than those: the list, newest first, and the ids it doesn't have, to
    /// fetch again so they're current (`GET /v1/jobs/{id}`).
    static func keeping<J>(_ fresh: [J], old: [J], onScreen: Set<String>, id: (J) -> String, created: (J) -> Date) -> (jobs: [J], refetch: [String]) {
        let missing = onScreen.subtracting(fresh.map(id))
        var list = fresh
        for job in old where missing.contains(id(job)) { list = placed(job, in: list, id: id, created: created) }
        return (list, missing.sorted())
    }

    /// The list after the runner answered `status` about the job `gone`: a 404 says it has no such
    /// job (#223), so the job leaves the list instead of staying under Needs you with a Dismiss that
    /// can't work. Any other answer leaves the list as it is.
    static func answered<J>(_ status: Int?, about gone: String, in list: [J], id: (J) -> String) -> [J] {
        status == 404 ? list.filter { id($0) != gone } : list
    }

    /// `job` in the list: in place of the one with its id, else where its age puts it (newest first).
    static func placed<J>(_ job: J, in list: [J], id: (J) -> String, created: (J) -> Date) -> [J] {
        var list = list
        if let index = list.firstIndex(where: { id($0) == id(job) }) {
            list[index] = job
        } else {
            list.insert(job, at: list.firstIndex { created($0) < created(job) } ?? list.count)
        }
        return list
    }
}

/// How Home groups the work (#496): by kind of work, the default, or by status. Remembered on
/// each app under `key`.
nonisolated enum GroupBy: String, CaseIterable, Sendable {
    case type, status
    static let key = "ObyGroupBy"

    var label: String { self == .type ? "Type" : "Status" }
}

/// When done tasks leave Home for Archived (Sangam's Archive completed, in Home's ⋮, tasks.ts
/// `ARCHIVE_AFTER`): how long after they finished. Remembered on each app under `key`; 3 days
/// unless changed, so Friday's work is still on Home on Monday.
nonisolated enum ArchiveAfter: String, CaseIterable, Sendable {
    case day = "1d", threeDays = "3d", week = "1w", never
    static let key = "ObyArchiveAfter"

    var label: String {
        switch self {
        case .day: "After a day"
        case .threeDays: "After 3 days"
        case .week: "After a week"
        case .never: "Never"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .day: 86_400
        case .threeDays: 3 * 86_400
        case .week: 7 * 86_400
        case .never: nil
        }
    }

    /// Whether a job is under Archived rather than on Home (tasks.ts `isArchived`): it's settled
    /// (`JobList.settled`), and it was archived by hand (obid's `archived`), a Clear done took it
    /// (#280, `JobList.shows`), or it finished longer ago than this says.
    func archives(settled: Bool, finished: Date?, archived: Date?, clearedAt: Date?, now: Date) -> Bool {
        guard settled else { return false }
        if archived != nil || !JobList.shows(finished: finished, clearedAt: clearedAt) { return true }
        guard let finished, let interval else { return false }
        return now.timeIntervalSince(finished) > interval
    }
}

/// Where a task stands on Home (#496): running (queued too: it starts by itself, with nothing for
/// you to do), needs you (whatever its agent is doing), or done.
nonisolated enum WorkStatus: Sendable { case running, needs, done }

/// A task's one mark wherever it's listed (#496): new until it's opened, then needs you, working,
/// queued or done. The raw value is what VoiceOver reads.
nonisolated enum WorkMark: String, Sendable {
    case new = "New", needs = "Needs you", working = "Working", queued = "Queued", done = "Done"
}

/// A kind of work (#496), in Home's order: pull requests to review, issues' work, a group per
/// teammate whose Oby asked for something, the tasks asked in Oby, and the routines' runs (#395).
nonisolated enum WorkType: Hashable, Sendable {
    case review, issues, teammate(String), tasks, routines

    /// A request from a teammate's Oby goes under them, whatever it asks for; then a routine's
    /// run, whatever it does (Sangam's tasks.ts); then a review, then work on an issue; anything
    /// else is a task asked in Oby.
    static func of(review: Bool, issue: Int?, requester: String?, routine: Bool = false) -> WorkType {
        if let name = requester?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return .teammate(name) }
        if routine { return .routines }
        if review { return .review }
        return issue == nil ? .tasks : .issues
    }

    var id: String {
        switch self {
        case .review: "review"
        case .issues: "issues"
        case .teammate(let name): "teammate:\(name)"
        case .tasks: "tasks"
        case .routines: "routines"
        }
    }

    var label: String {
        switch self {
        case .review: "Review PR"
        case .issues: "Issues"
        case .teammate(let name): name
        case .tasks: "Tasks"
        case .routines: "Routines"
        }
    }

    /// Home's order, teammates by name.
    fileprivate var order: (Int, String) {
        switch self {
        case .review: (0, "")
        case .issues: (1, "")
        case .teammate(let name): (2, name)
        case .tasks: (3, "")
        case .routines: (4, "")
        }
    }
}

/// The work as Home groups it (#496, Sangam's design: design/app's tasks.ts), on every app: by kind
/// of work or by status, what each group shows, and a kind's page with its Running and Completed tabs.
nonisolated enum WorkList {
    /// One task: its job, its kind, where it stands, whether it waits to start (`queued`), and
    /// whether it's new (`fresh`: arrived since the app opened, and not opened yet).
    struct Item<J>: Identifiable {
        var id: String
        var job: J
        var type: WorkType
        var status: WorkStatus
        var queued: Bool
        var fresh: Bool

        var mark: WorkMark {
            if fresh { return .new }
            switch status {
            case .needs: return .needs
            case .done: return .done
            case .running: return queued ? .queued : .working
            }
        }
    }

    /// One group of Home's list: a kind of work (`type`) or a status, its tasks in order (`ranked`),
    /// the count by its name (a kind's open tasks, a status's all), how many need you, and whether one's new.
    struct Group<J>: Identifiable {
        var id: String
        var type: WorkType?
        var label: String
        var items: [Item<J>]
        var count: Int
        var countLabel: String
        var needs: Int
        var fresh: Bool
    }

    /// A kind's page: To do holds GitHub's items no job works on yet (Review PR and Issues only);
    /// Running every job not done, what needs you included; Completed the rest.
    enum Tab: String, CaseIterable, Sendable { case todo = "To do", running = "Running", done = "Completed" }

    /// The side panel's list. By kind, with nothing typed in search, every kind is there even when it
    /// holds no job, so Issues and Review PR open onto GitHub's list (Sangam's Sidebar.tsx). A search,
    /// or grouping by status, leaves out the empty ones.
    static func panel<J>(_ items: [Item<J>], by: GroupBy, searching: Bool) -> [Group<J>] {
        by == .type && !searching ? kinds(items) : groups(items, by: by)
    }

    /// `items` (newest first) in their groups, empty ones left out.
    static func groups<J>(_ items: [Item<J>], by: GroupBy) -> [Group<J>] {
        switch by {
        case .type:
            let kinds = Set(items.map(\.type)).sorted { $0.order < $1.order }
            return kinds.map { kind in
                let list = ranked(items.filter { $0.type == kind })
                return Group(id: kind.id, type: kind, label: kind.label, items: list, count: list.count { $0.status != .done },
                             countLabel: "open", needs: list.count { $0.status == .needs }, fresh: list.contains(where: \.fresh))
            }
        case .status:
            let statuses: [(WorkStatus, String, String)] = [(.needs, "needs", "Needs you"), (.running, "running", "Running"), (.done, "done", "Completed")]
            return statuses.compactMap { status, id, label in
                let list = ranked(items.filter { $0.status == status })
                if list.isEmpty { return nil }
                return Group(id: "status:\(id)", type: nil, label: label, items: list, count: list.count, countLabel: "tasks",
                             needs: status == .needs ? list.count : 0, fresh: list.contains(where: \.fresh))
            }
        }
    }

    /// Home's chips (Sangam's Home.tsx, docs/oby-ux.md row 3): every kind of work, always, in Home's
    /// order, whatever's in it; a teammate's once their Oby has asked for something.
    static func kinds<J>(_ items: [Item<J>]) -> [Group<J>] {
        let held = groups(items, by: .type)
        let always: [WorkType] = [.review, .issues, .tasks, .routines]
        let kinds = Set(always + held.compactMap(\.type)).sorted { $0.order < $1.order }
        return kinds.map { kind in
            held.first { $0.type == kind }
                ?? Group(id: kind.id, type: kind, label: kind.label, items: [], count: 0, countLabel: "open", needs: 0, fresh: false)
        }
    }

    /// Top of each list: new tasks, then what needs you, then what waits to start; the rest as
    /// they came (newest first).
    static func ranked<J>(_ items: [Item<J>]) -> [Item<J>] {
        func rank(_ item: Item<J>) -> Int { item.fresh ? 0 : item.status == .needs ? 1 : item.queued ? 2 : 3 }
        return items.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// What a group shows: everything still open, and its latest 3 done (5 under Completed), the
    /// rest behind Show more (`more`); `hidden` is how many that holds back.
    static func shown<J>(_ group: Group<J>, more: Bool) -> (rows: [Item<J>], hidden: Int) {
        let keep = group.id == "status:done" ? 5 : 3
        let done = group.items.filter { $0.status == .done }
        let hidden = max(0, done.count - keep)
        if more { return (group.items, hidden) }
        return (group.items.filter { $0.status != .done } + done.prefix(keep), hidden)
    }

    /// "Needs you", counted one way wherever it shows (docs/oby-ux.md row 5): the tasks with an open
    /// decision, plus the decisions that have no task (`loose`).
    static func needsYou<J>(_ items: [Item<J>], loose: Int) -> Int { items.count { $0.status == .needs } + loose }

    /// A kind's tasks under one tab of its page: To do holds no task, only GitHub's items.
    static func items<J>(_ items: [Item<J>], in tab: Tab) -> [Item<J>] {
        tab == .todo ? [] : items.filter { ($0.status == .done) == (tab == .done) }
    }

    /// Each tab's count on a kind's page: Running and Completed count jobs alone (and Running a
    /// routine's next run, `upcoming`); To do, on a page that has it, GitHub's items no job works on.
    static func counts<J>(_ items: [Item<J>], toDo: Int?, upcoming: Int = 0) -> [Tab: Int] {
        var counts = [Tab.running: Self.items(items, in: .running).count + upcoming, .done: Self.items(items, in: .done).count]
        counts[.todo] = toDo
        return counts
    }

    /// The tab a kind's page opens on: where its new task is, else Running while anything's open
    /// (what needs you included), else To do on a page that has it (`toDo`), else Completed when
    /// anything's done, else Running.
    static func firstTab<J>(_ items: [Item<J>], toDo: Bool = false) -> Tab {
        if let fresh = items.first(where: \.fresh) { return fresh.status == .done ? .done : .running }
        if items.contains(where: { $0.status != .done }) { return .running }
        if toDo { return .todo }
        return items.isEmpty ? .running : .done
    }
}

#if canImport(SwiftUI)
extension JobBadge.Tone {
    /// The same colours on the iPhone and the Mac.
    var color: Color {
        switch self {
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .gray: .gray
        }
    }
}
#endif
