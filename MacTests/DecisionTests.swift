import Foundation
import Testing
@testable import Oby

/// The Mac reads the runner's jobs into Engine's Job, which doesn't read the permission keys yet
/// (#134): RunnerJobExtras reads them from the same JSON, and a runner without them still decodes.
struct DecisionTests {
    let job = #"{"id": "9f08fd10", "request": "Fix it", "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/fix-12", "base": "dev", "pr": null, "kind": "fix", "task": "Fix it", "status": "running", "step": "Waiting for your OK", "summary": "", "session": "e6a24229", "created": "2026-10-09T21:42:53Z", "started": "2026-10-09T21:42:55Z", "finished": null, "commits": null, "published": null"#
    let keys = ###", "mode": "plan", "permission": {"id": "p1", "tool": "Bash", "title": "Run swift test", "detail": "swift test --filter SpeechTests", "rule": "Bash(swift test:*)", "always": "Yes, and don't ask again for swift test in deskree-inc/oby"}, "question": {"text": "Approve the plan?", "plan": "## Plan", "options": ["Approve: Accept edits", "Approve: Bypass", "Change it"], "recommended": 0}}"###

    @Test func extrasDecode() throws {
        let data = Data("[\(job + keys), \(job.replacingOccurrences(of: "9f08fd10", with: "older"))}]".utf8)
        // Engine's Job still reads the list, new keys and all.
        #expect(try Runner.decoder.decode([Job].self, from: data).map(\.id) == ["9f08fd10", "older"])
        let extras = RunnerJobExtras.of(data)
        let first = try #require(extras["9f08fd10"])
        #expect(RunnerMode(first.mode) == .plan)
        #expect(first.permission?.id == "p1" && first.permission?.detail == "swift test --filter SpeechTests")
        #expect(first.question?.recommendedOption == "Approve: Accept edits" && first.question?.plan == "## Plan")
        #expect(first.question?.cardOptions.first?.recommended == true)
        // An older runner's job: nothing extra.
        #expect(extras["older"] == RunnerJobExtras(id: "older"))
    }

    @Test func extrasNeverFailAJob() throws {
        // A permission without its title, or a mode that isn't a string, reads as none.
        let odd = job + #", "mode": 3, "permission": {"id": "p1"}, "question": null}"#
        let extras = try Runner.decoder.decode(RunnerJobExtras.self, from: Data(odd.utf8))
        #expect(extras == RunnerJobExtras(id: "9f08fd10"))
        #expect(RunnerJobExtras.of(Data("not json".utf8)).isEmpty)
    }

    @Test func jobEventsCarryExtras() {
        var parser = EventParser()
        var event: RunnerEvent?
        for line in ["event: job", "data: \(job + keys)", ""] { event = parser.feed(line) ?? event }
        guard case .job(let decoded, let extras) = event else { Issue.record("no job event"); return }
        #expect(decoded.id == "9f08fd10")
        #expect(extras?.permission?.title == "Run swift test")

        for line in ["event: job", "data: \(job)}", ""] { event = parser.feed(line) }
        guard case .job(_, let none) = event else { Issue.record("no job event"); return }
        #expect(none == RunnerJobExtras(id: "9f08fd10"))
    }

    /// Engine's InboxItem doesn't read Oby's plain words (#65): the Mac reads them beside it.
    @Test func inboxWords() throws {
        let item = #"{"id": "i1", "kind": "question", "job": "9f08fd10", "title": "Nothing committed status", "text": "Failed, or a new status?", "options": ["A new status", "Failed"], "created": "2026-10-10T09:12:00Z", "done": null, "later": null, "answer": null"#
        let words = #", "headline": "Failed or new status?", "happened": "The job ended without a commit.", "recommended": 1, "why": "It's what happens today."}"#
        let data = Data("[\(item + words), \(item.replacingOccurrences(of: "\"i1\"", with: "\"i2\""))}]".utf8)
        #expect(try Runner.decoder.decode([InboxItem].self, from: data).map(\.id) == ["i1", "i2"])
        let read = InboxWords.of(data)
        #expect(read["i1"] == InboxWords(headline: "Failed or new status?", happened: "The job ended without a commit.", recommended: 1, why: "It's what happens today."))
        #expect(read["i2"] == InboxWords())
        #expect(CardOption.inbox(["A new status", "Failed"], kind: "question", words: read["i1"]).map(\.label) == ["Failed", "A new status"])

        var parser = EventParser()
        var event: RunnerEvent?
        for line in ["event: inbox", "data: \(item + words)", ""] { event = parser.feed(line) ?? event }
        guard case .inbox(let decoded, let carried) = event else { Issue.record("no inbox event"); return }
        #expect(decoded.id == "i1" && carried?.headline == "Failed or new status?")
    }

    @Test func statusCarriesTheDefaultMode() throws {
        let status = #"{"runner": {"version": "0.2.0", "host": "tetrix-lab"}, "accounts": [], "models": {"claude": {"model": "claude-opus-5-5", "effort": "xhigh"}, "codex": {"model": "gpt-6-sol", "effort": "high"}}, "permissions": {"mode": "acceptEdits"}}"#
        #expect(RunnerMode(try Runner.decoder.decode(RunnerStatus.self, from: Data(status.utf8)).permissions?.mode) == .acceptEdits)
        let older = #"{"runner": {"version": "0.2.0", "host": "tetrix-lab"}, "accounts": [], "models": {"claude": {"model": "claude-opus-5-5", "effort": "xhigh"}, "codex": {"model": "gpt-6-sol", "effort": "high"}}}"#
        #expect(try Runner.decoder.decode(RunnerStatus.self, from: Data(older.utf8)).permissions == nil)
    }

    @Test func cardOrder() {
        #expect(CardOption.of(["A new status", "Failed"], recommended: 1).map(\.label) == ["Failed", "A new status"])
        #expect(CardOption.of(["A new status", "Failed"], recommended: 1).first?.recommended == true)
        #expect(CardOption.of(["A new status", "Failed"]).map(\.label) == ["A new status", "Failed"])
        #expect(CardOption.of(["a", "b", "c", "d"]).count == 3)
        // This Mac's own jobs' questions have no recommended option yet: their order stays.
        #expect(CardOption.inbox(["Yes", "No"], kind: "\(InboxItem.Kind.question)").map(\.label) == ["Yes", "No"])
    }
}
