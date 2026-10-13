import Foundation
import Testing
@testable import ObyEngine

/// "Finish #19 from PR #124" (#219) is dispatched as one fix job of the issue that starts from the
/// pull request's head, keeps `dev` as its base and publishes a pull request of its own.
@MainActor
struct FinishFromPRTests {
    let context = BrainContext(accounts: ["auto": ["auto"], "claude": ["auto"]], repos: ["deskree-inc/oby"])

    func dispatch(_ kind: Plan.Kind, issue: Int? = 19, pr: Int? = 124) -> Plan.Dispatch {
        Plan.Dispatch(agent: "auto", account: "auto", repo: "deskree-inc/oby", baseBranch: nil, pr: pr, issue: issue, epic: nil,
                      kind: kind, title: "Finish the stale work", task: "Finish #19 from PR #124", inputs: [], rounds: 1, check: nil,
                      complexity: .routine)
    }

    func plan(_ dispatches: [Plan.Dispatch]) -> Plan {
        Plan(action: .dispatch, reply: "Oby will finish #19 from PR #124.", dispatches: dispatches, question: nil)
    }

    @Test func finishingAnIssueFromAPullRequestIsAValidFixBuildOrTest() {
        for kind in [Plan.Kind.fix, .build, .test] {
            #expect(plan([dispatch(kind)]).problems(in: context, canary: "zq9").isEmpty, "\(kind)")
        }
        // A review or an investigation is still about one or the other.
        #expect(plan([dispatch(.review)]).problems(in: context, canary: "zq9")
                == ["a job is about a pr or an issue, not both, unless it's a fix, build or test of the issue that starts from the pr"])
        #expect(!plan([dispatch(.investigate)]).problems(in: context, canary: "zq9").isEmpty)
    }

    @Test func theBrainIsToldToDispatchFromThePullRequestsHead() {
        let system = Planner.system(canary: "zq9")
        #expect(system.contains("finish #19 from PR #124") && !system.contains("(never both)"))
    }

    @Test func theBrainsPlanIsDispatchedFromThePullRequestsHead() async {
        struct Brain: BrainAdapter {
            let name = "brain"
            func complete(system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data {
                Data(#"{"action":"dispatch","reply":"Oby will finish #19 from PR #124.","question":null,"jobs":[],"all":false,"move":null,"dispatches":[{"agent":"auto","account":"auto","repo":"deskree-inc/oby","base_branch":null,"pr":124,"issue":19,"epic":null,"kind":"fix","title":"Finish stale work","task":"Finish #19 from PR #124","inputs":[],"rounds":1,"check":null,"complexity":"routine"}]}"#.utf8)
            }
        }
        let result = await Planner(adapters: [Brain()]).plan("finish oby #19 from PR #124", context: context)
        // The brain answers the same every time: its plan is the one dispatched, not the rules'.
        #expect(result.by == "brain")
        #expect(result.plan.dispatches.map { "\($0.issue ?? 0)/\($0.pr ?? 0)" } == ["19/124"])
        let turn = BrainTurn(said: "finish oby #19 from PR #124", by: result.by, plan: result.plan)
        #expect(turn.line.contains("fix deskree-inc/oby #19 from PR #124"))
    }

    @Test func rulesDispatchTheIssueFromThePullRequestsHead() {
        for said in ["finish oby #19 from PR #124", "finish issue 19 in oby from pull request 124", "build oby #19 from pr 124"] {
            let plan = Rules.plan(said, context: context)
            #expect(plan.dispatches.map { "\($0.kind.rawValue) \($0.issue ?? 0)/\($0.pr ?? 0)" } == [said.hasPrefix("build") ? "build 19/124" : "fix 19/124"], "\(said)")
            #expect(plan.problems(in: context, canary: "zq9").isEmpty, "\(said)")
        }
        // A review or an investigation stays one: it never becomes work that commits.
        let review = Rules.plan("review oby issue 19 from PR 124", context: context)
        #expect(review.dispatches.map { "\($0.kind.rawValue) \($0.issue ?? 0)/\($0.pr ?? 0)" } == ["review 0/124"])
        let investigate = Rules.plan("investigate oby #19 from PR #124", context: context)
        #expect(investigate.dispatches.map { "\($0.kind.rawValue) \($0.issue ?? 0)/\($0.pr ?? 0)" } == ["investigate 19/0"])
        #expect(review.problems(in: context, canary: "zq9").isEmpty && investigate.problems(in: context, canary: "zq9").isEmpty)
        // Several issues are still one job each.
        #expect(Rules.plan("fix oby #12, #15 and #18", context: context).dispatches.map(\.issue) == [12, 15, 18])
    }

    @Test func theJobStartsFromThePullRequestsHead() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max", for: "default")
        let desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.prepare = { $0 }
        desk.makeAgent = { _, _, _ in ConversationTests.IdleAgent() }
        // The plan starts the job (#269): it's the newest on the desk.
        guard case .reply = await desk.card(for: Planner.Result(plan: plan([dispatch(.fix)]), by: "claude"),
                                            said: "finish oby #19 from PR #124") else {
            Issue.record("expected a reply")
            return
        }
        let job = try #require(desk.jobs.first)
        #expect(job.issue == 19 && job.fromPR == 124 && job.pr == nil && job.base == nil)
        #expect(job.branch == "oby/fix-19" && job.heading == "Finish the stale work")
        // On a pull request alone, it's still that pull request's job.
        guard case .reply = await desk.card(for: Planner.Result(plan: plan([dispatch(.review, issue: nil)]), by: "claude"),
                                            said: "review oby PR #124") else {
            Issue.record("expected a reply")
            return
        }
        #expect(desk.jobs.first.map { "\($0.pr ?? 0) \($0.fromPR == nil) \($0.branch)" } == "124 true oby/review-124")
    }

    @Test func itsBaseStaysDevAndThePullRequestIsQuoted() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = Vault(store: FileVault(folder: folder.appending(path: "vault")))
        let worktree = folder.appending(path: "worktree")
        var job = Job(id: "ab12cd34", request: "finish oby #19 from PR #124", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-19", base: "dev", kind: .fix, task: "Finish #19 from PR #124")
        job.issue = 19
        job.fromPR = 124
        let pullRequest = try JSONSerialization.data(withJSONObject: [
            "title": "Stale work", "body": "Half done.", "author": ["login": "someone"], "baseRefName": "main",
            "url": "https://github.com/deskree-inc/oby/pull/124",
        ])
        let issue = try JSONSerialization.data(withJSONObject: ["title": "The bug", "body": "It breaks.", "url": "https://github.com/deskree-inc/oby/issues/19"])
        let prepared = try Workspace.inputs(job, pullRequest: pullRequest, issue: issue, in: worktree, vault: vault)
        #expect(prepared.base == "dev")
        let quoted = try String(contentsOf: worktree.appending(path: ".oby/inputs/pr-124.md"), encoding: .utf8)
        #expect(quoted.hasPrefix("# Pull request #124, quoted") && quoted.contains("Half done."))
        #expect(FileManager.default.fileExists(atPath: worktree.appending(path: ".oby/inputs/issue-19.md").path))

        let prompt = Prompts.agent(prepared)
        #expect(prompt.contains("started from the head of pull request #124") && prompt.contains(".oby/inputs/pr-124.md"))
        #expect(prompt.contains("into origin/dev") && prompt.contains(".oby/inputs/issue-19.md"))
        #expect(!prompt.contains("Work on pull request #124"))
    }
}
