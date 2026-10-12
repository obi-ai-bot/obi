import Foundation
import Testing
@testable import ObyEngine
@testable import oby_runner

/// The Lead's first slice (#64, Engine/Lead.swift): Swift's skipped list from the board, the
/// context files, the typed plan Swift checks, jobs that start with no Dispatch tap and claim
/// their issue, overlapping jobs that run side by side, told about each other, and every turn logged.
@MainActor
struct LeadTests {
    /// An agent whose events the test sends.
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var prompt = ""
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
            self.prompt = prompt
            self.onEvent = onEvent
        }
        func send(_ text: String) {}
        func end() {}
        func stop() {}
        func kill() {}
    }

    /// A Lead that answers from a list of plans, one per call (the last one again when they run
    /// out), noting what it was asked and the context files Swift wrote for it.
    final class FakeLead: LeadAdapter, @unchecked Sendable {
        let name = "fake"
        var plans: [String]
        var calls: [(user: String, roadmap: String, jobs: String)] = []
        init(_ plans: [String]) { self.plans = plans }
        func turn(system: String, user: String, schema: Data, in directory: URL, timeout: TimeInterval) async throws -> Data {
            let read = { (file: String) in (try? String(contentsOf: directory.appending(path: ".oby/context/\(file)"), encoding: .utf8)) ?? "" }
            calls.append((user, read("roadmap.md"), read("jobs.md")))
            let plan = plans.count > 1 ? plans.removeFirst() : plans[0]
            return Data(plan.utf8)
        }
    }

    final class Made {
        var agents: [(job: Job, agent: Agent)] = []
        var claims: [Job] = []
    }

    let folder: URL
    let accounts: AccountStore
    let desk: Desk
    let made = Made()
    let personal: Account
    let work: Account

    init() throws {
        folder = try temporaryFolder()
        accounts = AccountStore(root: folder)
        personal = try accounts.add(agent: "claude", name: "Personal", payer: "")
        work = try accounts.add(agent: "codex", name: "Work", payer: "Deskree")
        accounts.setLabel("Max · well@example.com", for: "default")
        accounts.setLabel("Max · personal@example.com", for: personal.id)
        accounts.setLabel("Plus · work@example.com", for: work.id)
        desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        desk.leadRoot = folder.appending(path: "leads")
        desk.prepare = { $0 }
        desk.makeAgent = { [made] job, _, _ in
            let agent = Agent()
            made.agents.append((job, agent))
            return agent
        }
        desk.readBoard = { [board] _ in board }
        desk.issueSync.enabled = true
        desk.issueSync.auditURL = folder.appending(path: "issue-audit.json")
        desk.issueSync.scan = { _ in }
        desk.issueSync.gh = { [made, weak desk] args in
            if args.contains("--add-label"), args.contains("status:in-progress"), let number = Int(args[2]), let job = desk?.issueJobs.first(where: { $0.issue == number && $0.isActive }) { made.claims.append(job) }
            if args.prefix(2) == ["issue", "view"] { return "{\"labels\":[],\"body\":\"\"}" }
            if args.prefix(2) == ["project", "list"] { return "{\"projects\":[]}" }
            return ""
        }
    }

    // MARK: The board

    /// The spike's fixture board (spikes/lead-turn/fixture/context/roadmap.md), as Swift reads it.
    var board: Board {
        let item = { (number: Int, title: String, status: String, labels: [String], assignees: [String], prs: [Int]) in
            BoardItem(repo: "deskree-inc/oby", number: number, title: title, url: "https://github.com/deskree-inc/oby/issues/\(number)",
                      status: status, labels: labels, milestone: "F\(number)", assignees: assignees, openPullRequests: prs)
        }
        return Board(title: "Oby — Roadmap", number: 1, owner: "well-prado", items: [
            item(5, "F1 Oby lives in the notch", "Done", [], ["well-prado"], []),
            item(6, "F2 Type a task, an agent does it", "In review", ["status:needs-test"], ["well-prado"], [55]),
            item(36, "F2 follow-ups", "In review", ["status:needs-test"], ["well-prado"], []),
            item(41, "F15 Live Activity", "In review", ["status:needs-test"], ["well-prado"], []),
            item(7, "F3 Safe when nobody is watching", "Todo", ["feature"], [], []),
            item(8, "F4 Oby reads GitHub issues", "In progress", ["status:in-progress"], ["well-prado"], [70]),
            item(9, "F5 Tetrix memory", "Todo", ["status:blocked"], [], []),
            item(10, "F6 Gemini", "Todo", ["oby:skip"], [], []),
            item(11, "F7 Slack", "Todo", ["feature"], ["someone-else"], []),
            item(12, "F8 Oby on Apple Watch", "Todo", ["feature"], [], []),
            item(13, "F9 Voice: hold fn to talk", "Todo", ["feature"], [], []),
            item(14, "F10 Inputs from GitHub | Slack", "Todo", ["feature"], [], []),
            item(30, "Epic: Oby on Android", "Todo", ["epic"], [], []),
        ], user: "well-prado")
    }

    /// The running job on #14 from the fixture's jobs.md.
    var running: Job {
        var job = Job(id: "a41c9e02", request: "work on oby #14", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/build-14", base: "dev", kind: .build, task: "Work on #14")
        job.issue = 14
        job.status = .running
        job.rounds = 5
        job.round = 2
        return job
    }

    @Test func swiftBuildsTheSkippedListFromTheBoardAndTheJobs() {
        let skipped = Lead.skipped(board.items, jobs: [running], user: "well-prado")
        #expect(skipped.map(\.number) == [5, 6, 36, 41, 8, 9, 10, 11, 14])
        #expect(skipped.map(\.reason) == ["done", "in review", "in review", "in review", "PR #70 is open", "blocked", "oby:skip",
                                           "assigned to someone-else", "job a41c9e02 is running on it"])
        let workable = board.items.filter { item in !skipped.contains { $0.number == item.number } }.map(\.number)
        #expect(workable == [7, 12, 13, 30])
        // The label alone skips too, in a Todo column; and the user's own assignment doesn't.
        var mine = board.items[4]
        mine.assignees = ["well-prado"]
        #expect(Lead.reason(mine, jobs: [], user: "well-prado") == nil)
        mine.labels = ["status:needs-test"]
        #expect(Lead.reason(mine, jobs: [], user: "well-prado") == "status:needs-test: waiting for your test")
        mine.labels = ["status:in-review"]
        #expect(Lead.reason(mine, jobs: [], user: "well-prado") == "in review")
        // A queued job counts as running; a pull request Oby published counts as open until it's merged.
        var queued = running
        queued.status = .queued
        queued.issue = 7
        #expect(Lead.reason(board.items[4], jobs: [queued], user: "well-prado") == "job a41c9e02 is queued on it")
        var published = running
        published.status = .done
        published.issue = 7
        published.published = "https://github.com/deskree-inc/oby/pull/80"
        #expect(Lead.reason(board.items[4], jobs: [published], user: "well-prado") == "PR https://github.com/deskree-inc/oby/pull/80 is open")
        published.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: .now, checkedAt: .now)
        #expect(Lead.reason(board.items[4], jobs: [published], user: "well-prado") == nil)
    }

    @Test func theContextFilesShowTheBoardWithVerdictsAndTheJobs() throws {
        let skipped = Lead.skipped(board.items, jobs: [running], user: "well-prado")
        let roadmap = Lead.roadmap(board, skipped: skipped, checkouts: ["deskree-inc/oby": "/srv/oby/repos/deskree-inc/oby"],
                                   now: Date(timeIntervalSince1970: 1_791_582_173))
        #expect(roadmap.hasPrefix("# Roadmap: Oby — Roadmap\n"))
        #expect(roadmap.contains("as Oby read it at 2026-10-09 21:42:53 UTC"))
        #expect(roadmap.contains("deskree-inc/oby (read-only checkout at /srv/oby/repos/deskree-inc/oby"))
        #expect(roadmap.contains("| 1 | deskree-inc/oby#5 | F1 Oby lives in the notch | Done |  | F5 | well-prado |  | skipped: done |"))
        #expect(roadmap.contains("| 2 | deskree-inc/oby#6 | F2 Type a task, an agent does it | In review | status:needs-test | F6 | well-prado | #55 | skipped: in review |"))
        #expect(roadmap.contains("| 5 | deskree-inc/oby#7 | F3 Safe when nobody is watching | Todo | feature | F7 |  |  | workable |"))
        // A pipe in a title from GitHub can't break the table.
        #expect(roadmap.contains("| F10 Inputs from GitHub \\| Slack | Todo | feature | F14 |  |  | skipped: job a41c9e02 is running on it |"))

        let jobs = Lead.jobsList([running], now: Date(timeIntervalSince1970: 1_791_582_173))
        #expect(jobs.hasPrefix("# Oby's jobs\n"))
        #expect(jobs.contains("| a41c9e02 | deskree-inc/oby | issue #14 | Build oby #14 | Claude Code | running, round 2 of 5 |  |  |"))
        var done = running
        done.status = .done
        done.id = "93887146"
        done.issue = 6
        done.files = ["Engine/Desk.swift", "Runner/"]
        done.published = "https://github.com/deskree-inc/oby/pull/55"
        #expect(Lead.jobsList([done]).contains("| 93887146 | deskree-inc/oby | issue #6 | Build oby #6 | Claude Code | done | Engine/Desk.swift, Runner/ | PR https://github.com/deskree-inc/oby/pull/55 opened |"))

        let directory = folder.appending(path: "context-test")
        try Lead.writeContext(roadmap: roadmap, jobs: jobs, to: directory)
        #expect(try String(contentsOf: directory.appending(path: ".oby/context/roadmap.md"), encoding: .utf8) == roadmap)
        #expect(try String(contentsOf: directory.appending(path: ".oby/context/jobs.md"), encoding: .utf8) == jobs)
    }

    @Test func aPullRequestThatIsPartOfAnIssueStillShowsOnTheBoard() async throws {
        let board = try await Board.read(repos: ["deskree-inc/oby"], gh: { args in
            switch Array(args.dropFirst().prefix(2)) {
            case ["api", "user"]: return "well-prado"
            case ["project", "list"]: return #"{"projects": [{"title": "Oby — Roadmap", "number": 1}]}"#
            case ["project", "item-list"]:
                return #"{"items": [{"content": {"type": "Issue", "number": 116, "repository": "deskree-inc/oby"}, "status": "In progress"}, {"content": {"type": "Issue", "number": 20, "repository": "deskree-inc/oby"}, "status": "Todo"}]}"#
            case ["issue", "list"]:
                return #"[{"number": 116, "title": "Oby does it all itself", "url": "u116"}, {"number": 20, "title": "The Watch", "url": "u20"}]"#
            case ["pr", "list"]:
                // #142 says `Part of #116`; #121 closes #20 and its title names it too.
                return #"[{"number": 142, "title": "feat(runner): jobs carry on after any runner restart (#116)", "closingIssuesReferences": []}, {"number": 121, "title": "feat(watch): alone (#20)", "closingIssuesReferences": [{"number": 20}]}]"#
            default: throw Shell.Failure(message: "unexpected \(args)")
            }
        })
        #expect(board.items.first { $0.number == 116 }?.openPullRequests == [142])
        #expect(board.items.first { $0.number == 20 }?.openPullRequests == [121])
    }

    @Test func theBoardIsFoundByTitleHoweverItsDashIsSpelled() {
        #expect(Board.sameTitle("Oby — Roadmap", "Oby - roadmap") && Board.sameTitle("Oby – Roadmap", "oby —  Roadmap"))
        #expect(!Board.sameTitle("Oby — Roadmap", "Oby Roadmap"))
        #expect(Board.names([["name": "feature"], ["name": "epic"]], key: "name") == ["feature", "epic"])
        #expect(Board.names(["feature"], key: "name") == ["feature"] && Board.names(nil, key: "login").isEmpty)
    }

    // MARK: Validation

    let context = LeadContext(repos: ["deskree-inc/oby"], workable: ["deskree-inc/oby#7", "deskree-inc/oby#12", "deskree-inc/oby#13", "deskree-inc/oby#30"],
                              refused: ["deskree-inc/oby#14": "job a41c9e02 is running on it", "deskree-inc/oby#8": "PR #70 is open"])

    func brief(_ issue: Int, files: [String] = ["Engine/Lead.swift"], check: String = "swift test", title: String = "Lead context files", goal: String = "Write the files.") -> LeadPlan.Brief {
        LeadPlan.Brief(repo: "deskree-inc/oby", issue: issue, kind: .build, title: title, goal: goal, files: files, check: check, outOfScope: "The Mac app.")
    }

    @Test func swiftChecksEveryLeadPlan() {
        let good = LeadPlan(action: .startJobs, reply: "Starting #7 and #12.", jobs: [brief(7), brief(12, files: ["Watch/"])], question: nil)
        #expect(good.problems(in: context, canary: "abc12345").isEmpty)
        // Issues with a running job or an open pull request are refused, so the same request twice starts nothing new.
        let taken = LeadPlan(action: .startJobs, reply: "", jobs: [brief(14), brief(8)], question: nil)
        #expect(taken.problems(in: context, canary: "zq9") == ["deskree-inc/oby#14 is refused: job a41c9e02 is running on it", "deskree-inc/oby#8 is refused: PR #70 is open"])
        let twice = LeadPlan(action: .startJobs, reply: "", jobs: [brief(7), brief(7)], question: nil)
        #expect(twice.problems(in: context, canary: "zq9") == ["two jobs are about deskree-inc/oby#7"])
        // Only issues the board lists as workable: not a closed, made-up or off-board one, which Oby would claim on GitHub.
        #expect(LeadPlan.problems(of: brief(99), in: context) == ["deskree-inc/oby#99 isn't a workable issue on the board"])
        #expect(LeadPlan.problems(of: brief(5), in: context) == ["deskree-inc/oby#5 isn't a workable issue on the board"])
        // Every part of a brief is checked.
        var bad = brief(0, files: [], check: "echo ok\necho done", title: "", goal: " ")
        bad.repo = "deskree-inc/nowhere"
        bad.outOfScope = String(repeating: "x", count: 1001)
        #expect(LeadPlan.problems(of: bad, in: context) == [
            "deskree-inc/nowhere isn't a known repository", "issue must be a positive number", "deskree-inc/nowhere#0 isn't a workable issue on the board",
            "title must be one line of 1 to 60 characters",
            "goal is empty", "files must name at least one file or folder the job will touch", "check must be one line of 1 to 200 characters",
            "out_of_scope is longer than 1,000 characters",
        ])
        for path in ["/etc/passwd", "../other/file", "~/.ssh/id_rsa", "Engine/../../x", "", "a\nb"] {
            #expect(LeadPlan.problems(of: brief(7, files: [path]), in: context).contains { $0.hasSuffix("isn't a path inside the repository") }, Comment(rawValue: path))
        }
        #expect(LeadPlan.problems(of: brief(7, files: ["Engine/", "docs/runner-api.md", "./Runner/API.swift"]), in: context).isEmpty)
        #expect(LeadPlan.problems(of: brief(7, files: Array(repeating: "a.swift", count: 31)), in: context) == ["files holds at most 30 paths"])
        // The shape of each action.
        let empty = LeadPlan(action: .startJobs, reply: "", jobs: [], question: nil)
        #expect(empty.problems(in: context, canary: "zq9") == ["start_jobs needs at least one job in jobs"])
        let question = Plan.Question(text: "Which repository?", options: ["deskree-inc/oby"])
        let asks = LeadPlan(action: .askUser, reply: "", jobs: [brief(7)], question: nil)
        #expect(asks.problems(in: context, canary: "zq9") == ["ask_user needs its question object", "ask_user has no jobs"])
        let replies = LeadPlan(action: .reply, reply: "Nothing to start.", jobs: [brief(7)], question: question)
        #expect(replies.problems(in: context, canary: "zq9") == ["reply has no jobs or question object"])
        let canary = LeadPlan(action: .reply, reply: "canary abc12345", jobs: [], question: nil)
        #expect(canary.problems(in: context, canary: "abc12345") == ["the plan repeats the canary"])
        let long = LeadPlan(action: .reply, reply: String(repeating: "x", count: 281), jobs: [], question: nil)
        #expect(long.problems(in: context, canary: "zq9") == ["reply is longer than 280 characters"])
        // No push, merge or publish action exists, in the schema or the type.
        let schema = String(decoding: LeadPlan.schema(for: context), as: UTF8.self)
        #expect(schema.contains(#""action":{"enum":["start_jobs","reply","ask_user"]}"#))
        #expect(!schema.contains("push") && !schema.contains("merge") && !schema.contains("publish"))
        #expect(schema.contains(#""repo":{"enum":["deskree-inc/oby"]}"#) && schema.contains(#""out_of_scope""#))
        #expect(throws: (any Error).self) { try LeadPlan.decode(Data(#"{"action":"merge","reply":"","jobs":[],"question":null}"#.utf8)) }
    }

    @Test func aBriefBecomesAJobWithSwiftsTaskBranchAndLoop() {
        let account = Account(id: "p", agent: "claude", name: "Personal", payer: "", home: nil)
        let job = Lead.job(brief(7, files: ["Engine/Lead.swift", "docs/"]), said: "Work on the roadmap", goal: "g0a1", account: account)
        #expect(job.issue == 7 && job.pr == nil && job.repo == "deskree-inc/oby" && job.kind == .build && job.branch == "oby/build-7")
        #expect(job.agent == "claude" && job.account == "p" && job.request == "Work on the roadmap" && job.lead == "g0a1")
        #expect(job.title == "Lead context files" && job.heading == "Lead context files")
        #expect(job.check == "swift test" && job.rounds == Lead.rounds && job.loops && job.files == ["Engine/Lead.swift", "docs/"])
        #expect(job.task == "Write the files.\n\nFiles you're expected to touch: Engine/Lead.swift, docs/. Stay within them unless the work really needs more, and say so in your summary when you do.\n\nOut of scope: The Mac app.")
        let prompt = Prompts.agent(job)
        #expect(prompt.contains("What the user asked for: Write the files.") && prompt.contains("`swift test` succeeds"))
    }

    // MARK: Routing

    @Test func vagueRequestsGoToTheLeadAndNamedWorkToTheBrain() {
        for said in ["Work on the roadmap", "work on the ROADMAP", "get some roadmap issues from OB and work on them", "Obi, next issue",
                     "pick the next open issues", "what's next?", "work on the board", "Clear the backlog"] {
            #expect(Lead.leads(said), Comment(rawValue: said))
        }
        // Stopping stays with the brain, which stops the jobs: the Lead has no stop action.
        for said in ["Review oby PR #33", "Work on oby #12 and #13 until the tests pass", "Stop", "Merge it", "Work on epic #30", "fix the keyboard",
                     "Stop working on the roadmap", "cancel the roadmap jobs", "Obi, stop the next issue"] {
            #expect(!Lead.leads(said), Comment(rawValue: said))
        }
    }

    // MARK: Turns on the desk

    let startJobs = #"{"action":"start_jobs","reply":"Starting #7 and #12.","question":null,"jobs":[{"repo":"deskree-inc/oby","issue":7,"kind":"build","title":"Safe when nobody watches","goal":"Implement F3.","files":["Engine/Desk.swift","Engine/Lead.swift"],"check":"swift test","out_of_scope":"The Mac UI."},{"repo":"deskree-inc/oby","issue":12,"kind":"build","title":"Watch first slice","goal":"Implement F8.","files":["Watch/"],"check":"swift test","out_of_scope":"The iPhone app."}]}"#

    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: what))
    }

    @Test func theLeadStartsJobsRightAwayClaimsEachIssueAndIsLogged() async throws {
        let lead = FakeLead([startJobs])
        desk.makeLead = { _ in [lead] }
        let talk = await desk.plan("Work on the roadmap")
        guard case .reply(let text) = talk else { Issue.record("not a reply: \(talk)"); return }
        #expect(text == "Started 2 jobs: Safe when nobody watches (#7), Watch first slice (#12). Skipped 8 on the board.")
        // No Dispatch tap: both run, each on its own account with room (Accounts.pick spreads them).
        try await until("both jobs run") { desk.jobs.count == 2 && desk.jobs.allSatisfy { $0.status == .running } }
        let seven = try #require(desk.jobs.first { $0.issue == 7 })
        let twelve = try #require(desk.jobs.first { $0.issue == 12 })
        #expect(seven.branch == "oby/build-7" && seven.files == ["Engine/Desk.swift", "Engine/Lead.swift"] && seven.lead != nil && seven.check == "swift test")
        #expect(seven.account != twelve.account && seven.lead == twelve.lead)
        #expect(made.agents.count == 2 && made.agents.first?.agent.prompt.contains("Out of scope: The Mac UI.") == true)
        // The Lead read what Swift wrote: the board with verdicts, and the jobs (none yet).
        let call = try #require(lead.calls.first)
        #expect(call.user == "The user said:\nWork on the roadmap")
        #expect(call.roadmap.contains("| deskree-inc/oby#7 | F3 Safe when nobody is watching | Todo | feature | F7 |  |  | workable |"))
        #expect(call.roadmap.contains("| deskree-inc/oby#11 | F7 Slack | Todo | feature | F11 | someone-else |  | skipped: assigned to someone-else |"))
        #expect(call.jobs.contains("No jobs yet."))
        // Each issue is claimed when its job starts, and the job says so.
        try await until("both issues are claimed") { made.claims.count == 2 && desk.jobs.allSatisfy { $0.claim != nil } }
        #expect(Set(made.claims.map(\.issue)) == [7, 12] && made.claims.allSatisfy { $0.branch.hasPrefix("oby/build-") })
        #expect(desk.job(seven.id)?.claim == "Claimed: labeled status:in-progress.")
        // The turn is in the turns table, with the skipped list and what it started.
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        let turn = try #require(store.leadTurns().first)
        #expect(turn.said == "Work on the roadmap" && turn.by == "fake" && turn.plan?.action == .startJobs && turn.goal == seven.lead)
        #expect(Set(turn.started) == Set([seven.id, twelve.id]) && turn.skipped.map(\.number) == [5, 6, 36, 41, 8, 9, 10, 11])
        #expect(turn.line.contains("\"Work on the roadmap\" → start_jobs by fake") && turn.line.contains("build deskree-inc/oby #7 (Engine/Desk.swift, Engine/Lead.swift), check `swift test`"))
        #expect(store.turns().isEmpty)
        // The API shows the Lead's fields.
        let json = object(try API.encode(JobJSON(job: try #require(desk.job(seven.id)))))
        #expect(json["files"] as? [String] == ["Engine/Desk.swift", "Engine/Lead.swift"] && json["lead"] as? String == seven.lead)
        #expect((json["claim"] as? String)?.hasPrefix("Claimed:") == true)
        let brainJob = object(try API.encode(JobJSON(job: job)))
        #expect(brainJob["files"] is NSNull && brainJob["lead"] is NSNull && brainJob["claim"] is NSNull)
    }

    @Test func theSameRequestTwiceStartsNothingNew() async throws {
        let lead = FakeLead([startJobs])
        desk.makeLead = { _ in [lead] }
        _ = await desk.plan("Work on the roadmap")
        try await until("both jobs run") { desk.jobs.count == 2 && desk.jobs.allSatisfy { $0.status == .running } }
        // The Lead insists on #7 and #12 again, then gives in: Swift refuses the first plan, the retry answers.
        lead.plans = [startJobs, #"{"action":"reply","reply":"Everything workable is taken.","question":null,"jobs":[]}"#]
        let talk = await desk.plan("Work on the roadmap")
        guard case .reply(let text) = talk else { Issue.record("not a reply: \(talk)"); return }
        #expect(text == "Everything workable is taken.")
        #expect(desk.jobs.count == 2 && lead.calls.count == 3)
        #expect(lead.calls[2].user.contains("Your last plan was refused: deskree-inc/oby#7 is refused: job"))
        #expect(lead.calls[1].roadmap.contains("skipped: job \(desk.jobs.first { $0.issue == 7 }?.id ?? "?") is running on it"))
        #expect(lead.calls[1].jobs.contains("| issue #7 | Safe when nobody watches | "))
        let turns = JobStore(url: folder.appending(path: "oby.sqlite")).leadTurns()
        #expect(turns.count == 2 && turns.first?.plan?.action == .reply && turns.first?.refused.count == 1 && turns.first?.started.isEmpty == true)
        // A Lead that never gives a plan Swift accepts leaves the user a reason, and starts nothing.
        lead.plans = [startJobs]
        let stuck = await desk.plan("Work on the roadmap")
        guard case .reply(let why) = stuck else { Issue.record("not a reply: \(stuck)"); return }
        #expect(why.hasPrefix("The Lead couldn't plan that (fake plan refused (deskree-inc/oby#7 is refused: job ") && why.hasSuffix(")). Try saying it another way."))
        #expect(desk.jobs.count == 2 && !why.contains("{"))
    }

    @Test func jobsThatTouchTheSameFilesRunSideBySide() async throws {
        let three = #"{"action":"start_jobs","reply":"","question":null,"jobs":[{"repo":"deskree-inc/oby","issue":7,"kind":"build","title":"Safe when nobody watches","goal":"Implement F3.","files":["Engine/Desk.swift"],"check":"swift test","out_of_scope":""},{"repo":"deskree-inc/oby","issue":12,"kind":"build","title":"Watch first slice","goal":"Implement F8.","files":["Engine/"],"check":"swift test","out_of_scope":""},{"repo":"deskree-inc/oby","issue":13,"kind":"build","title":"Voice hold fn","goal":"Implement F9.","files":["Mac/Voice.swift"],"check":"swift test","out_of_scope":""}]}"#
        desk.maxRunning = 6
        desk.makeLead = { _ in [FakeLead([three])] }
        _ = await desk.plan("Work on the roadmap")
        try await until("all three run") { desk.jobs.filter { $0.status == .running }.count == 3 }
        let seven = try #require(desk.jobs.first { $0.issue == 7 })
        let twelve = try #require(desk.jobs.first { $0.issue == 12 })
        #expect(seven.status == .running && desk.job(13)?.status == .running)
        // #12 names Engine/, which holds #7's file: it runs all the same, with nothing waiting.
        #expect(twelve.status == .running && !twelve.step.hasPrefix("Waiting for"))
        #expect(made.agents.count == 3 && made.agents.contains { $0.job.issue == 12 })
        #expect(Desk.overlap(twelve, seven) == ["Engine/"] && Desk.overlap(seven, twelve) == ["Engine/Desk.swift"])
        // #12 names Engine/, which holds #7's file: its agent is told about #7, and #13's about nothing.
        let prompt = { (issue: Int) in made.agents.first { $0.job.issue == issue }?.agent.prompt ?? "" }
        #expect(prompt(12).contains("Safe when nobody watches (job \(seven.id)) on the branch \(seven.branch): both touch Engine/"))
        #expect(!prompt(13).contains("Other jobs are changing the same files"))
        try await until("all three are claimed") { made.claims.count == 3 }
        #expect(made.claims.contains { $0.issue == 12 })
        // #7 ends: #12 carries on.
        desk.stop(seven.id)
        try await until("#7 stops") { desk.jobs.first { $0.issue == 7 }?.status == .stopped }
        #expect(desk.jobs.first { $0.issue == 12 }?.status == .running && made.agents.count == 3)
        #expect(desk.jobs.first { $0.issue == 12 }?.pipeline.stages.first { $0.id == .work }?.state == .current)
    }

    @Test func overlapIsBySharedPathsInTheSameRepository() {
        var a = job
        a.files = ["Engine/Desk.swift", "docs/runner-api.md", "./Runner/API.swift"]
        var b = job
        b.files = ["Engine/", "Runner/API.swift"]
        #expect(Desk.overlap(a, b) == ["Engine/Desk.swift", "./Runner/API.swift"])
        b.files = ["Mac/"]
        #expect(Desk.overlap(a, b).isEmpty)
        b.files = ["Engine/Desk.swift"]
        b.repo = "deskree-inc/other"
        #expect(Desk.overlap(a, b).isEmpty)
        // A job without a list never blocks or waits.
        b.repo = a.repo
        b.files = nil
        #expect(Desk.overlap(a, b).isEmpty)
        #expect(Lead.same("Engine/", "Engine/Lead.swift") && Lead.same("Engine/Lead.swift", "./Engine//Lead.swift") && !Lead.same("Engine", "Engine/Lead.swift"))
    }

    @Test func aBoardThatCantBeReadIsSaidAndLogged() async throws {
        desk.readBoard = { _ in throw Shell.Failure(message: "gh: not logged in") }
        desk.makeLead = { _ in [FakeLead([startJobs])] }
        let talk = await desk.plan("Work on the roadmap")
        #expect(talk == .reply("Oby couldn't read the roadmap: gh: not logged in") && desk.jobs.isEmpty)
        let turn = try #require(JobStore(url: folder.appending(path: "oby.sqlite")).leadTurns().first)
        #expect(turn.plan == nil && turn.refused == ["the board couldn't be read: gh: not logged in"])
        // The Lead's question reaches the user as the brain's would.
        desk.readBoard = { [board] _ in board }
        desk.makeLead = { _ in [FakeLead([#"{"action":"ask_user","reply":"","question":{"text":"Which repository?","options":["deskree-inc/oby"]},"jobs":[]}"#])] }
        let asked = await desk.plan("Work on the roadmap")
        #expect(asked == .question(said: "Work on the roadmap", Plan.Question(text: "Which repository?", options: ["deskree-inc/oby"])))
    }

    @Test func leadTurnsAndBrainTurnsShareTheTableAndStayApart() throws {
        let store = JobStore(url: folder.appending(path: "turns.sqlite"))
        store.save(BrainTurn(said: "review oby #7", by: "claude", plan: Plan(action: .ignore, reply: "", dispatches: [], question: nil)))
        store.save(LeadTurn(goal: "g0a1", said: "work on the roadmap", by: "claude Fable 5.1",
                            plan: LeadPlan(action: .startJobs, reply: "Starting #7.", jobs: [brief(7)], question: nil),
                            skipped: [Skipped(repo: "deskree-inc/oby", number: 5, reason: "done")], started: ["ab12cd34"]))
        #expect(store.turns().map(\.said) == ["review oby #7"])
        let lead = try #require(store.leadTurns().first)
        #expect(store.leadTurns().count == 1 && lead.goal == "g0a1" && lead.started == ["ab12cd34"] && lead.skipped.first?.reason == "done")
        #expect(lead.line == "\"work on the roadmap\" → start_jobs by claude Fable 5.1 (lead g0a1); reply \"Starting #7.\"; build deskree-inc/oby #7 (Engine/Lead.swift), check `swift test`; started ab12cd34; skipped #5 done")
    }

    @Test func theClaudeLeadRunsBoxedWithOnlyReadToolsAndItsDirectory() throws {
        let directory = folder.appending(path: "leads/g0a1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let argv = Agents.sandboxed(["claude", "-p"], in: nil, own: "\(Agents.home)/.claude", reading: [directory.path, "/nowhere/at/all"], bubblewrap: true)
        #expect(argv.contains(["--ro-bind", directory.path, directory.path]))
        #expect(!argv.contains("/nowhere/at/all"))
        // The model the spike proved (6 to 20 s a turn), on the account given.
        #expect(Lead.adapters(home: "/h").map(\.name) == ["claude Sonnet 5.5"])
        #expect((Lead.adapters(home: "/h").first as? ClaudeLead)?.home == "/h")
    }

    /// The same request from the Mac and the iPhone at once, or repeated after the app gave up
    /// waiting: the briefs are checked against the live jobs right before each starts.
    @Test func twoTurnsAtOnceStartOneJobOnAnIssue() async throws {
        let one = #"{"action":"start_jobs","reply":"","question":null,"jobs":[{"repo":"deskree-inc/oby","issue":7,"kind":"build","title":"Safe when nobody watches","goal":"Implement F3.","files":["Engine/Desk.swift"],"check":"swift test","out_of_scope":""}]}"#
        /// Takes a moment to answer, as a real turn does, so both turns read the board before either starts a job.
        final class SlowLead: LeadAdapter, @unchecked Sendable {
            let name = "slow"
            let plan: String
            init(_ plan: String) { self.plan = plan }
            func turn(system: String, user: String, schema: Data, in directory: URL, timeout: TimeInterval) async throws -> Data {
                try await Task.sleep(for: .milliseconds(100))
                return Data(plan.utf8)
            }
        }
        desk.makeLead = { _ in [SlowLead(one)] }
        async let mac = desk.plan("Work on the roadmap")
        async let phone = desk.plan("work on the roadmap")
        let replies = await [mac, phone]
        #expect(replies.contains(.reply("Started 1 job: Safe when nobody watches (#7). Skipped 8 on the board.")))
        #expect(replies.contains(.reply("Nothing new to start: #7 already has a job.")))
        try await until("the job runs") { desk.jobs.count == 1 && desk.jobs.first?.status == .running }
        try await Task.sleep(for: .milliseconds(50))
        #expect(desk.jobs.count == 1 && made.agents.count == 1 && made.claims.count == 1)
        let turns = JobStore(url: folder.appending(path: "oby.sqlite")).leadTurns()
        #expect(turns.count == 2 && turns.map(\.started.count).sorted() == [0, 1])
        #expect(turns.contains { $0.refused.contains { $0.hasPrefix("#7 not started: job ") && $0.hasSuffix(" on it already") } })
        // Older goals' context folders are pruned, the newest kept.
        for n in 0..<25 { try FileManager.default.createDirectory(at: desk.leadRoot.appending(path: "old-\(n)"), withIntermediateDirectories: true) }
        Lead.prune(desk.leadRoot, keep: 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: desk.leadRoot.path).count == 3)
    }
}

private extension Desk {
    func job(_ issue: Int) -> Job? { jobs.first { $0.issue == issue } }
}

private extension Array where Element == String {
    /// Whether `sequence` appears in order, one after another.
    func contains(_ sequence: [String]) -> Bool {
        guard sequence.count <= count else { return false }
        return indices.dropLast(sequence.count - 1).contains { Array(self[$0..<($0 + sequence.count)]) == sequence }
    }
}
