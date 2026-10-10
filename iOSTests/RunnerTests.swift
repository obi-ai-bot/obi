import Foundation
import Testing
@testable import Oby

/// The examples in docs/runner-api.md, as the app reads them.
struct RunnerTests {
    let job = #"{"id": "9f08fd10", "request": "Review oby PR #33", "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/review-33", "base": "dev", "pr": 33, "kind": "review", "task": "Review pull request #33", "status": "running", "step": "Running pnpm test", "summary": "", "session": "e6a24229", "created": "2026-10-09T21:42:53Z", "started": "2026-10-09T21:42:55Z", "finished": null, "commits": null, "published": null}"#

    @Test func jobDecodesWithISODates() throws {
        let job = try Runner.decoder.decode(Job.self, from: Data(job.utf8))
        #expect(job.title == "Review oby #33")
        #expect(job.isActive)
        #expect(job.line == "Running pnpm test")
        #expect(job.created == ISO8601DateFormatter().date(from: "2026-10-09T21:42:53Z"))
        // And back, for POST /v1/jobs.
        let again = try Runner.decoder.decode(Job.self, from: Runner.encoder.encode(job))
        #expect(again == job)
    }

    @Test func planResults() throws {
        let plan = #"{"kind": "plan", "draft": {"said": "Review oby PR #33", "reply": "Oby will review PR #33 in oby.", "guessed": false, "job": \#(job)}}"#
        // An older runner: only `draft`, and a job without rounds, check or model.
        guard case .plan(let drafts) = try Runner.decoder.decode(PlanResult.self, from: Data(plan.utf8)) else { Issue.record("not a plan"); return }
        #expect(drafts.count == 1)
        #expect(drafts.first?.job.branch == "oby/review-33")
        #expect(drafts.first?.suggestedModel == nil)
        #expect(drafts.first?.job.extras == "")

        let question = #"{"kind": "question", "said": "Review PR 12", "question": {"text": "Which repository?", "options": ["deskree-inc/oby"]}}"#
        #expect(try Runner.decoder.decode(PlanResult.self, from: Data(question.utf8))
                == .question(said: "Review PR 12", Question(text: "Which repository?", options: ["deskree-inc/oby"])))
        #expect(try Runner.decoder.decode(PlanResult.self, from: Data(#"{"kind": "reply", "text": "Oby can't merge."}"#.utf8)) == .reply("Oby can't merge."))
        #expect(try Runner.decoder.decode(PlanResult.self, from: Data(#"{"kind": "none"}"#.utf8)) == .none)
    }

    /// Many jobs from one message, the stronger model, and what `POST /v1/jobs` sends back.
    @Test func plansWithManyDrafts() throws {
        func draft(_ issue: Int, _ suggested: String) -> String {
            let job = #"{"id": "j\#(issue)", "request": "work on oby #12 and #15", "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/fix-\#(issue)", "base": null, "pr": null, "kind": "fix", "task": "Fix it", "status": "queued", "step": "", "summary": "", "session": null, "created": "2026-10-09T21:42:53Z", "started": null, "finished": null, "commits": null, "published": null, "issue": \#(issue), "rounds": 3, "round": 1, "check": "swift test", "model": null}"#
            return #"{"said": "work on oby #12 and #15", "reply": "Two fixes.", "guessed": false, "job": \#(job), "suggestedModel": \#(suggested)}"#
        }
        let plan = #"{"kind": "plan", "drafts": [\#(draft(12, #""claude-fable-5-1""#)), \#(draft(15, "null"))], "draft": \#(draft(12, #""claude-fable-5-1""#))}"#
        guard case .plan(let drafts) = try Runner.decoder.decode(PlanResult.self, from: Data(plan.utf8)) else { Issue.record("not a plan"); return }
        #expect(drafts.map(\.job.title) == ["Fix oby #12", "Fix oby #15"])
        #expect(drafts[0].job.extras == "Round 1 of 3")
        #expect(drafts[0].strongerModel(for: "claude") == "claude-fable-5-1")
        // Another account's tool runs that tool's stronger model.
        #expect(drafts[0].strongerModel(for: "codex") == "gpt-6-astra")
        #expect(drafts[1].strongerModel(for: "claude") == nil)
        #expect(ModelChoice.name("gpt-6-astra") == "GPT-6-Astra")

        // A cleared check and the usual model go as null: left out, the runner keeps the plan's check.
        var job = drafts[1].job
        job.check = nil
        let body = try JSONSerialization.jsonObject(with: Runner.encoder.encode(DispatchedJob(job: job))) as? [String: Any]
        #expect(body?["check"] is NSNull)
        #expect(body?["model"] is NSNull)
        #expect(body?["rounds"] as? Int == 3)
        job.model = "claude-fable-5-1"
        job.check = "swift test"
        let chosen = try JSONSerialization.jsonObject(with: Runner.encoder.encode(DispatchedJob(job: job))) as? [String: Any]
        #expect(chosen?["model"] as? String == "claude-fable-5-1")
        #expect(chosen?["check"] as? String == "swift test")

        var running = drafts[0].job
        running.model = "claude-fable-5-1"
        running.round = 2
        #expect(running.extras == "Round 2 of 3 · Fable 5.1")
    }

    /// What the user told the agent: missing from older runners, null, or oldest first.
    @Test func notes() throws {
        #expect(try Runner.decoder.decode(Job.self, from: Data(job.utf8)).notes == nil)
        let told = job.replacingOccurrences(of: #""published": null}"#, with: #""published": null, "notes": ["Add a test.", "And docs."]}"#)
        #expect(try Runner.decoder.decode(Job.self, from: Data(told.utf8)).notes == ["Add a test.", "And docs."])
    }

    @Test func eventsAndPings() throws {
        var parser = EventParser()
        let account = #"[{"id": "default", "agent": "claude", "name": "Deskree", "label": "Team · w@deskree.com", "signedIn": true, "fiveHour": 0.1, "sevenDay": null, "running": 1}]"#
        var events: [RunnerEvent] = []
        for line in [": ping", "", "event: job", "data: \(job)", "", "event: accounts", "data: \(account)\r", "\r", "event: other", "data: {}", ""] {
            if let event = parser.feed(line) { events.append(event) }
        }
        #expect(events.count == 2)
        guard case .job(let decoded) = events.first, case .accounts(let accounts) = events.last else { Issue.record("wrong events"); return }
        #expect(decoded.id == "9f08fd10")
        #expect(accounts.first?.title == "Deskree · Claude Code")
    }

    /// The bytes the Face ID key signs must be exactly what the runner checks.
    @Test func approvalMessage() {
        let message = Approval.message(job: "abc", action: "Push oby/fix-1 to deskree-inc/oby and open a draft pull request into dev.", signedAt: "2026-10-09T22:01:07Z")
        #expect(String(decoding: message, as: UTF8.self)
                == "oby-publish\nabc\nPush oby/fix-1 to deskree-inc/oby and open a draft pull request into dev.\n2026-10-09T22:01:07Z")
    }

    @Test func publishOnlyWithCommits() throws {
        var job = try Runner.decoder.decode(Job.self, from: Data(job.utf8))
        job.status = .done
        #expect(!job.canPublish)
        job.commits = 2
        #expect(job.canPublish)
        job.published = "https://github.com/deskree-inc/oby/pull/40"
        #expect(!job.canPublish)
    }

    @Test func modelLabels() {
        #expect(ModelChoice(model: "claude-opus-5-5", effort: "xhigh").label == "Opus 5.5 · Extra high")
        #expect(ModelChoice(model: "gpt-6.1-sol", effort: "high").label == "gpt-6.1-sol · High")
    }
}
