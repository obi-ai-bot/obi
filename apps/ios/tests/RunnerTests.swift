import Foundation
import Testing
@testable import Oby

/// The examples in docs/runner-api.md, as the app reads them.
struct RunnerTests {
    let job = #"{"id": "9f08fd10", "request": "Review oby PR #33", "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/review-33", "base": "dev", "pr": 33, "kind": "review", "task": "Review pull request #33", "status": "running", "step": "Running pnpm test", "summary": "", "session": "e6a24229", "created": "2026-10-09T21:42:53Z", "started": "2026-10-09T21:42:55Z", "finished": null, "commits": null, "published": null}"#

    @Test func jobDecodesWithISODates() throws {
        let job = try Runner.decoder.decode(Job.self, from: Data(job.utf8))
        #expect(job.heading == "Review oby #33")
        #expect(job.isActive)
        #expect(job.line == "Running pnpm test")
        #expect(job.created == ISO8601DateFormatter().date(from: "2026-10-09T21:42:53Z"))
        // And back, for POST /v1/jobs.
        let again = try Runner.decoder.decode(Job.self, from: Runner.encoder.encode(job))
        #expect(again == job)
    }

    @Test func planResults() throws {
        // A reply with the job it started (#269), as the runner answers `POST /v1/plans`.
        let started = #"{"kind": "reply", "text": "On it. Claude Code is reviewing oby PR #33 on Personal.", "jobs": [\#(job)], "drafts": []}"#
        guard case .reply(let text, let jobs) = try Runner.decoder.decode(PlanResult.self, from: Data(started.utf8)) else { Issue.record("not a reply"); return }
        #expect(text == "On it. Claude Code is reviewing oby PR #33 on Personal.")
        #expect(jobs.count == 1)
        #expect(jobs.first?.branch == "oby/review-33")
        #expect(jobs.first?.extras == "")
        #expect(jobs.first?.heading == "Review oby #33")
        #expect(jobs.first?.isActive == true)
        // A reply that started nothing, and one from a runner without `jobs`.
        #expect(try Runner.decoder.decode(PlanResult.self, from: Data(#"{"kind": "reply", "text": "Fine.", "jobs": [], "drafts": []}"#.utf8)) == .reply("Fine.", started: []))
        // An older runner's plan, with its drafts: a reply that started nothing here.
        let old = #"{"kind": "plan", "drafts": [], "draft": {"said": "Review oby PR #33", "reply": "Oby will review PR #33 in oby.", "guessed": false, "job": \#(job)}}"#
        #expect(try Runner.decoder.decode(PlanResult.self, from: Data(old.utf8)) == .reply("", started: []))
        #expect(try Runner.decoder.decode(PlanResult.self, from: Data(#"{"kind": "plan"}"#.utf8)) == .reply("", started: []))

        let question = #"{"kind": "question", "said": "Review PR 12", "question": {"text": "Which repository?", "options": ["deskree-inc/oby"]}}"#
        #expect(try Runner.decoder.decode(PlanResult.self, from: Data(question.utf8))
                == .question(said: "Review PR 12", Question(text: "Which repository?", options: ["deskree-inc/oby"])))
        #expect(try Runner.decoder.decode(PlanResult.self, from: Data(#"{"kind": "reply", "text": "Oby can't merge."}"#.utf8)) == .reply("Oby can't merge.", started: []))
        #expect(try Runner.decoder.decode(PlanResult.self, from: Data(#"{"kind": "none"}"#.utf8)) == .none)
    }

    /// Many jobs from one message, and a job's extras with a model of its own.
    @Test func repliesWithManyJobs() throws {
        func started(_ issue: Int) -> String {
            #"{"id": "j\#(issue)", "request": "work on oby #12 and #15", "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/fix-\#(issue)", "base": null, "pr": null, "kind": "fix", "task": "Fix it", "status": "queued", "step": "", "summary": "", "session": null, "created": "2026-10-09T21:42:53Z", "started": null, "finished": null, "commits": null, "published": null, "issue": \#(issue), "rounds": 3, "round": 1, "check": "swift test", "model": null}"#
        }
        let reply = #"{"kind": "reply", "text": "On it.", "jobs": [\#(started(12)), \#(started(15))], "drafts": []}"#
        guard case .reply(_, let jobs) = try Runner.decoder.decode(PlanResult.self, from: Data(reply.utf8)) else { Issue.record("not a reply"); return }
        #expect(jobs.count == 2)
        #expect(jobs.map(\.heading) == ["Fix oby #12", "Fix oby #15"])
        #expect(jobs.map(\.issue) == [12, 15])
        #expect(jobs.map(\.branch) == ["oby/fix-12", "oby/fix-15"])
        #expect(jobs[0].extras == "Round 1 of 3")
        #expect(jobs[1].extras == "Round 1 of 3")
        #expect(jobs[0].check == "swift test" && jobs[0].rounds == 3)
        #expect(jobs[1].model == nil)
        #expect(ModelChoice.name("gpt-6-astra") == "GPT-6-Astra")
        #expect(ModelChoice.name("claude-fable-5-1") == "Fable 5.1")

        var running = jobs[0]
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

    /// A follow-up names the job it follows up (obid, the owner's decision of 2026-10-18); older
    /// runners leave it out, and the page lists a task's follow-ups oldest first.
    @Test func followUps() throws {
        let first = try Runner.decoder.decode(Job.self, from: Data(job.utf8))
        #expect(first.followUpOf == nil)
        let next = job.replacingOccurrences(of: #""published": null}"#, with: #""published": null, "followUpOf": "\#(first.id)"}"#)
        var follow = try Runner.decoder.decode(Job.self, from: Data(next.utf8))
        #expect(follow.followUpOf == first.id)
        follow.id = "f1"
        #expect(ThreadTaskLine.followUps(of: first.id, in: [first, follow]).map(\.id) == ["f1"])
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

    /// obid sends `label: null` until a tool reports one (#626): its `signedIn` decides, so the usage
    /// card doesn't say "Signed out" for an account obid signed in (docs/mac-design.md C1).
    @Test func obidsSignedInAccountWithNoLabel() throws {
        let json = #"{"id": "personal", "agent": "claude", "name": "Personal", "label": null, "signedIn": true, "fiveHour": null, "sevenDay": null, "running": 0}"#
        let account = try Runner.decoder.decode(Account.self, from: Data(json.utf8))
        #expect(account.usage.signedIn)
        #expect(Usage.notice(account.usage) != "Signed out")
    }

    /// An inbox item as the runner sends it (docs/runner-api.md), in its event and in the list.
    @Test func inboxItems() throws {
        let item = #"{"id": "ab12cd34-question-0", "kind": "question", "job": "ab12cd34", "title": "Nothing committed status", "text": "Failed, or a new status?", "options": ["Failed", "A new status"], "created": "2026-10-10T09:12:00Z", "done": null, "later": null, "answer": null, "state": "open"}"#
        var parser = EventParser()
        var events: [RunnerEvent] = []
        for line in ["event: inbox", "data: \(item)", ""] {
            if let event = parser.feed(line) { events.append(event) }
        }
        guard case .inbox(let decoded) = events.first else { Issue.record("no inbox event"); return }
        #expect(decoded.kind == "question" && decoded.options == ["Failed", "A new status"] && decoded.isOpen)
        let created = decoded.created
        #expect(decoded.line(now: created + 190) == "Question · Nothing committed status · waiting 3m")
        #expect(InboxItem.waiting([decoded], now: created).map(\.id) == ["ab12cd34-question-0"])
    }

    /// A runner's error keeps its status: a 404 on `GET /v1/inbox` means a runner older than the
    /// inbox (none to show), anything else a failure to try again.
    @Test func errorsKeepTheirStatus() throws {
        let url = URL(string: "https://runner.example/v1/inbox")!
        for status in [404, 502] {
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            let error = #expect(throws: RunnerError.self) { try Runner.check(response, Data(#"{"error": "No."}"#.utf8)) }
            #expect(error?.status == status && error?.message == "No.")
        }
    }

    /// The bytes the Face ID key signs must be exactly what the runner checks.
    @Test func approvalMessage() {
        let message = Approval.message(job: "abc", action: "Push oby/fix-1 to deskree-inc/oby and open a pull request into dev.", signedAt: "2026-10-09T22:01:07Z")
        #expect(String(decoding: message, as: UTF8.self)
                == "oby-publish\nabc\nPush oby/fix-1 to deskree-inc/oby and open a pull request into dev.\n2026-10-09T22:01:07Z")
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
