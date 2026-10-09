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
        guard case .plan(let draft) = try Runner.decoder.decode(PlanResult.self, from: Data(plan.utf8)) else { Issue.record("not a plan"); return }
        #expect(draft.job.branch == "oby/review-33")

        let question = #"{"kind": "question", "said": "Review PR 12", "question": {"text": "Which repository?", "options": ["deskree-inc/oby"]}}"#
        #expect(try Runner.decoder.decode(PlanResult.self, from: Data(question.utf8))
                == .question(said: "Review PR 12", Question(text: "Which repository?", options: ["deskree-inc/oby"])))
        #expect(try Runner.decoder.decode(PlanResult.self, from: Data(#"{"kind": "reply", "text": "Oby can't merge."}"#.utf8)) == .reply("Oby can't merge."))
        #expect(try Runner.decoder.decode(PlanResult.self, from: Data(#"{"kind": "none"}"#.utf8)) == .none)
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
