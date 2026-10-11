import Foundation
import Testing
@testable import Oby

/// Decision cards (#138) and the permission keys they read (#134, docs/runner-api.md): every key
/// is new, so a runner that doesn't send them still decodes.
struct DecisionTests {
    let job = #"{"id": "9f08fd10", "request": "Fix it", "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/fix-12", "base": "dev", "pr": null, "kind": "fix", "task": "Fix it", "status": "running", "step": "Waiting for your OK", "summary": "", "session": "e6a24229", "created": "2026-10-09T21:42:53Z", "started": "2026-10-09T21:42:55Z", "finished": null, "commits": null, "published": null"#

    @Test func modeAndPermissionDecode() throws {
        let sent = job + #", "mode": "ask", "permission": {"id": "p1", "tool": "Bash", "title": "Run swift test", "detail": "swift test --filter SpeechTests", "rule": "Bash(swift test:*)", "always": "Yes, and don't ask again for swift test in deskree-inc/oby"}}"#
        let decoded = try Runner.decoder.decode(Job.self, from: Data(sent.utf8))
        #expect(RunnerMode(decoded.mode) == .ask)
        #expect(decoded.permission == RunnerPermission(id: "p1", tool: "Bash", title: "Run swift test", detail: "swift test --filter SpeechTests",
                                                       rule: "Bash(swift test:*)", always: "Yes, and don't ask again for swift test in deskree-inc/oby"))
        #expect(decoded.waitsForPermission)
        // And back, as the phone hands jobs to the watch.
        #expect(try Runner.decoder.decode(Job.self, from: Runner.encoder.encode(decoded)) == decoded)
    }

    @Test func olderRunnersSendNone() throws {
        let decoded = try Runner.decoder.decode(Job.self, from: Data((job + "}").utf8))
        #expect(decoded.mode == nil && decoded.permission == nil && !decoded.waitsForPermission)
        let nulls = try Runner.decoder.decode(Job.self, from: Data((job + #", "mode": null, "permission": null}"#).utf8))
        #expect(nulls.mode == nil && nulls.permission == nil)
        // A mode this app doesn't know yet still decodes, as no mode.
        let newer = try Runner.decoder.decode(Job.self, from: Data((job + #", "mode": "dontAsk"}"#).utf8))
        #expect(newer.mode == "dontAsk" && RunnerMode(newer.mode) == nil)
    }

    @Test func questionsCarryRecommendedAndPlan() throws {
        let plan = #"{"text": "Approve the plan?", "plan": "## Plan\n- Add the card", "options": ["Approve: Accept edits", "Approve: Bypass", "Change it"], "recommended": 0}"#
        let question = try Runner.decoder.decode(Question.self, from: Data(plan.utf8))
        #expect(question.recommended == 0 && question.plan == "## Plan\n- Add the card")
        #expect(question.recommendedOption == "Approve: Accept edits")

        let older = try Runner.decoder.decode(Question.self, from: Data(#"{"text": "Which one?", "options": ["A", "B"]}"#.utf8))
        #expect(older == Question(text: "Which one?", options: ["A", "B"]))
        #expect(older.recommended == nil && older.plan == nil && older.recommendedOption == nil)

        // The brain's question gains them too.
        let brain = #"{"kind": "question", "said": "Review PR 12", "question": {"text": "Which repository?", "options": ["deskree-inc/oby", "deskree-inc/blok"], "recommended": 1, "plan": null}}"#
        guard case .question(_, let asked) = try Runner.decoder.decode(PlanResult.self, from: Data(brain.utf8)) else { Issue.record("not a question"); return }
        #expect(asked.cardOptions.map(\.label) == ["deskree-inc/blok", "deskree-inc/oby"])
    }

    @Test func statusAndRules() throws {
        let status = #"{"runner": {"version": "0.2.0", "host": "tetrix-lab"}, "accounts": [], "models": {"claude": {"model": "claude-opus-5-5", "effort": "xhigh"}, "codex": {"model": "gpt-6-sol", "effort": "high"}}, "permissions": {"mode": "bypass"}}"#
        #expect(RunnerMode(try Runner.decoder.decode(RunnerStatus.self, from: Data(status.utf8)).permissions?.mode) == .bypass)
        let older = #"{"runner": {"version": "0.2.0", "host": "tetrix-lab"}, "accounts": [], "models": {"claude": {"model": "claude-opus-5-5", "effort": "xhigh"}, "codex": {"model": "gpt-6-sol", "effort": "high"}}}"#
        #expect(try Runner.decoder.decode(RunnerStatus.self, from: Data(older.utf8)).permissions == nil)

        let rules = #"[{"id": "r1", "rule": "Bash(swift test:*)", "repo": "deskree-inc/oby", "decision": "allow", "created": "2026-10-11T09:00:00Z"}, {"id": "r2", "rule": "Edit(.env)", "decision": "deny"}]"#
        let decoded = try Runner.decoder.decode([RunnerRule].self, from: Data(rules.utf8))
        #expect(decoded.map(\.id) == ["r1", "r2"])
        #expect(decoded[0].created == ISO8601DateFormatter().date(from: "2026-10-11T09:00:00Z"))
        #expect(decoded[1].repo == nil && decoded[1].created == nil)
    }

    /// A dispatch that picked a mode says it on the job and beside it; one that didn't leaves it out.
    @Test func dispatchCarriesTheMode() throws {
        var job = try Runner.decoder.decode(Job.self, from: Data((job + "}").utf8))
        #expect((try JSONSerialization.jsonObject(with: Runner.encoder.encode(DispatchedJob(job: job))) as? [String: Any])?["mode"] == nil)
        job.mode = RunnerMode.plan.rawValue
        let body = try JSONSerialization.jsonObject(with: Runner.encoder.encode(DispatchedJob(job: job))) as? [String: Any]
        #expect(body?["mode"] as? String == "plan")
        #expect(Runner.mode(of: job) == "plan")
    }

    @Test func recommendedComesFirst() {
        let options = CardOption.of(["A new status", "Failed", "Keep it done"], recommended: 1)
        #expect(options.map(\.label) == ["Failed", "A new status", "Keep it done"])
        #expect(options.map(\.recommended) == [true, false, false])
        #expect(options.map(\.answer) == options.map(\.label))
    }

    @Test func withoutRecommendedTheOrderStays() {
        #expect(CardOption.of(["Failed", "A new status"]).map(\.label) == ["Failed", "A new status"])
        #expect(CardOption.of(["Failed", "A new status"]).allSatisfy { !$0.recommended })
        // An index out of range recommends nothing.
        #expect(CardOption.of(["Failed", "A new status"], recommended: 5).allSatisfy { !$0.recommended })
        #expect(CardOption.of([]).isEmpty)
    }

    @Test func atMostThree() {
        #expect(CardOption.of(["a", "b", "c", "d", "e"]).map(\.label) == ["a", "b", "c"])
        // A recommended one past the third still comes, first.
        #expect(CardOption.of(["a", "b", "c", "d", "e"], recommended: 4).map(\.label) == ["e", "a", "b"])
    }

    @Test func permissionOptions() {
        let permission = RunnerPermission(id: "p1", tool: "Bash", title: "Run swift test", detail: "swift test", rule: "Bash(swift test:*)",
                                          always: "Yes, and don't ask again for swift test in deskree-inc/oby")
        let options = CardOption.permission(permission)
        #expect(options.map(\.label) == ["Allow", "Always allow", "Deny"])
        #expect(options.map(\.answer) == ["allow", "always", "deny"])
        #expect(options[1].detail == "Yes, and don't ask again for swift test in deskree-inc/oby")
        #expect(options[2].role == .destructive)
        // Without `always`, the rule is spelled out; with neither, there's nothing to save.
        #expect(CardOption.permission(RunnerPermission(id: "p2", title: "Edit", rule: "Edit(README.md)"))[1].detail == "Don't ask again for Edit(README.md)")
        #expect(CardOption.permission(RunnerPermission(id: "p3", title: "Edit")).map(\.label) == ["Allow", "Deny"])
    }

    @Test func inboxItems() {
        let question = Question(text: "Failed, or a new status?", options: ["A new status", "Failed"], recommended: 1)
        #expect(CardOption.inbox(["A new status", "Failed"], kind: "question", question: question).map(\.label) == ["Failed", "A new status"])
        // Other kinds keep their order.
        #expect(CardOption.inbox(["Try again", "Dismiss"], kind: "failed", question: question).map(\.label) == ["Try again", "Dismiss"])
        let permission = RunnerPermission(id: "p1", title: "Run swift test", always: "Yes, and don't ask again")
        let options = CardOption.inbox(["Allow", "Always allow", "Deny"], kind: "permission", permission: permission)
        #expect(options[1].detail == "Yes, and don't ask again")
        #expect(options[2].role == .destructive && options[0].role == .plain)
    }

    @Test func planMarkdown() {
        let blocks = PlanBlock.blocks("# Plan\n\nAdd the **card**\nin Shared.\n\n- one\n* two\n2. three\n```\nswift test\n```")
        #expect(blocks == [.heading("Plan"), .text("Add the **card** in Shared."), .item("•", "one"), .item("•", "two"),
                           .item("2.", "three"), .code("swift test")])
    }
}
