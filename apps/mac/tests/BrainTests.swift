import Foundation
import Testing
@testable import Oby

struct BrainTests {
    let context = BrainContext(accounts: ["claude": ["default"]],
                               repos: ["deskree-inc/oby", "deskree-inc/tetrix-front-end", "deskree-inc/tetrix-frontend"])

    /// A plan exactly as `claude --json-schema` returned it on 2026-10-09.
    let review = Data(#"{"action": "dispatch", "reply": "Claude Code will review PR #482 in tetrix-front-end.", "dispatches": [{"agent": "claude", "account": "default", "repo": "deskree-inc/tetrix-front-end", "base_branch": null, "pr": 482, "issue": null, "epic": null, "kind": "review", "task": "Review pull request #482 in tetrix-front-end.", "inputs": [], "rounds": 1, "check": null, "complexity": "routine"}], "question": null}"#.utf8)

    @Test func realPlanDecodesAndPasses() throws {
        let plan = try Plan.decode(review)
        #expect(plan.action == .dispatch)
        #expect(plan.dispatches.first?.pr == 482)
        #expect(plan.problems(in: context, canary: "7f3a9c").isEmpty)
    }

    @Test func swiftRefusesWhatTheSchemaCantCatch() throws {
        var plan = try Plan.decode(review)
        plan.dispatches[0].repo = "evil/repo"
        plan.dispatches[0].account = "someone-else"
        plan.dispatches[0].baseBranch = "--upload-pack=sh"
        plan.dispatches[0].inputs = ["U9"]
        plan.reply = "ok 7f3a9c"
        let problems = plan.problems(in: context, canary: "7f3a9c")
        #expect(problems.count == 5)
    }

    @Test func actionAndObjectMustAgree() throws {
        var plan = try Plan.decode(review)
        plan.action = .replyOnly
        #expect(!plan.problems(in: context, canary: "7f3a9c").isEmpty)
        plan = Plan(action: .askUser, reply: "", dispatches: [], question: nil)
        #expect(!plan.problems(in: context, canary: "7f3a9c").isEmpty)
        plan = Plan(action: .ignore, reply: "", dispatches: [], question: nil)
        #expect(plan.problems(in: context, canary: "7f3a9c").isEmpty)
    }

    @Test func branchNames() {
        #expect(Job.branch(kind: .review, pr: 482, id: "abcdef12") == "oby/review-482")
        #expect(Job.branch(kind: .fix, pr: nil, id: "abcdef12") == "oby/fix-abcdef")
        for good in ["main", "dev", "feat/f2-dispatch", "release/1.2"] { #expect(Plan.isBranchName(good)) }
        for bad in ["-x", "a..b", "a.lock", "a/", "/a", ".a", "a//b", "a b", "a~1", "x@{1}", ""] { #expect(!Plan.isBranchName(bad), "\(bad)") }
    }

    @Test func rulesMatchWholeRepositoryNames() {
        let plan = Rules.plan("Review tetrix-front-end PR #482", context: context)
        #expect(plan.action == .dispatch)
        #expect(plan.dispatches.first?.repo == "deskree-inc/tetrix-front-end")
        #expect(plan.dispatches.first?.kind == .review)
        #expect(plan.dispatches.first?.pr == 482)
        #expect(plan.problems(in: context, canary: "7f3a9c").isEmpty)
    }

    @Test func rulesAskWhenTheyCantTell() {
        #expect(Rules.plan("fix the flaky login test", context: context).action == .askUser)
        #expect(Rules.plan("   ", context: context).action == .ignore)
        // Plans from rules are validated like any other.
        #expect(Rules.plan("fix the flaky login test", context: context).problems(in: context, canary: "7f3a9c").isEmpty)
    }

    @Test func plannerFallsBackToRulesWhenTheBrainFails() async {
        struct Broken: BrainAdapter {
            let name = "broken"
            func complete(system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data { Data("prose".utf8) }
        }
        let result = await Planner(adapters: [Broken()]).plan("review oby #7", context: context)
        #expect(result.by == "rules")
        #expect(result.plan.dispatches.first?.repo == "deskree-inc/oby")
    }

    @Test func plannerUsesCodexBeforeRulesWhenClaudeFails() async {
        struct BrokenClaude: BrainAdapter, SelfRetryingBrainAdapter {
            let name = "claude"
            func complete(system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data {
                throw Shell.Failure(message: "Claude account is at its limit")
            }
        }
        struct WorkingCodex: BrainAdapter {
            let name = "codex"
            let response: Data
            func complete(system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data { response }
        }
        let result = await Planner(adapters: [BrokenClaude(), WorkingCodex(response: review)]).plan("review oby #7", context: context)
        #expect(result.by == "codex")
        #expect(result.plan.dispatches.first?.repo == "deskree-inc/tetrix-front-end")
        #expect(result.refused.count == 1)
    }

    @Test func schemaListsOnlyWhatsConnected() throws {
        let schema = try #require(JSONSerialization.jsonObject(with: Plan.schema(for: context)) as? [String: Any])
        let actions = ((schema["properties"] as? [String: Any])?["action"] as? [String: Any])?["enum"] as? [String]
        // New actions are appended after these (#300): the first ten keep their order.
        #expect(actions?.prefix(10) == ["dispatch", "ask_user", "reply_only", "stop_agent", "move_job", "ignore", "answer_permission", "set_mode", "read_job", "set_setting"])
        #expect(String(decoding: Plan.schema(for: context), as: UTF8.self).contains("deskree-inc/tetrix-frontend"))
    }
}
