import Foundation
import Testing
@testable import Oby

/// The job page's facts and words (obi-ai-bot/obi#737, #739; apps/shared/JobPage.swift): what obid
/// serves is read into the Mac's job extras without ever failing the job, a part it doesn't serve
/// stays nil, and the page says times, counts and the finish as the canvas does.
struct JobPageTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    func facts(_ fixture: JobPageFixture, bare: Bool = false) throws -> (Job, JobFacts?) {
        let data = fixture.json(now: now, bare: bare)
        return (try Runner.decoder.decode(Job.self, from: data), try Runner.decoder.decode(RunnerJobExtras.self, from: data).facts)
    }

    @Test func everyStateReadsWithItsFacts() throws {
        for fixture in JobPageFixture.allCases {
            let (job, facts) = try facts(fixture)
            #expect(job.title == "Give the scan's first block a fix round")
            #expect(facts?.estimate != nil && facts?.usage?.tokens != nil && facts?.windowShare?.fiveHour != nil, "\(fixture)")
            #expect(facts?.stages["prepare"]?.finished != nil, "\(fixture)")
            // Today's obid sends none of them: nothing is made up.
            #expect(try self.facts(fixture, bare: true).1 == nil, "\(fixture)")
        }
        let (_, working) = try facts(.working)
        #expect(working?.activity?.groups?.count == 4)
        #expect(working?.activity?.groups?.last?.tools?.last?.running == true)
        #expect(working?.context?.hasPrefix("It made a blocked first push") == true)
        let (_, failed) = try facts(.failed)
        #expect(failed?.checks?.last?.failing?.map(\.test) == ["publish_api::scan_blocks_first_push", "publish_api::second_block_ends_job"])
        #expect(failed?.scan?.ran == false)
    }

    /// A part obid sends in a shape this app can't read is left out; the rest, and the job, still read.
    @Test func aPartThatCantBeReadIsLeftOut() throws {
        let odd = #"{"id": "j", "usage": "lots", "checks": {"round": 1}, "context": "Reading the publish step", "estimate": {"low": 60, "high": 120},"#
            + #" "pipeline": {"stages": [{"id": "work", "started": "nope"}, {"id": "check", "estimate": {"low": 10, "high": 20}}]}}"#
        let facts = try #require(try Runner.decoder.decode(RunnerJobExtras.self, from: Data(odd.utf8)).facts)
        #expect(facts.usage == nil && facts.checks == nil)
        #expect(facts.context == "Reading the publish step")
        #expect(facts.estimate == JobEstimate(low: 60, high: 120))
        // One stage's bad date drops the pipeline's times, never the job.
        #expect(facts.stages.isEmpty)
    }

    @Test func timesCountsAndMoneyReadAsTheCanvasSaysThem() {
        #expect(JobPageText.seconds(18) == "18s")
        #expect(JobPageText.seconds(199) == "3m 19s")
        #expect(JobPageText.seconds(180) == "3m")
        #expect(JobPageText.seconds(660) == "11m")
        #expect(JobPageText.seconds(3900) == "1h 5m")
        #expect(JobPageText.seconds(522) == "9m")
        #expect(JobPageText.minutes(241) == "4m")
        #expect(JobPageText.minutes(40) == "40s")
        #expect(JobPageText.range(720, 1200) == "12–20m")
        #expect(JobPageText.range(180, 420) == "3–7m")
        #expect(JobPageText.range(30, 50) == "30–50s")
        #expect(JobPageText.range(600, 600) == "10m")
        #expect(JobPageText.tokens(1_900_000) == "1.9M")
        #expect(JobPageText.tokens(214_000) == "214k")
        #expect(JobPageText.tokens(950) == "950")
        #expect(JobPageText.dollars(2.7) == "$2.70")
        #expect(JobPageText.percent(0.4) == "<1%")
        #expect(JobPageText.percent(11) == "11%")
        #expect(ToolCounts(read: 23, search: 9, edit: 1, test: 1, tetrix: 0).line == "23 read · 9 searches · 1 edit · 1 test run")
        #expect(ToolCounts().line == nil)
    }

    /// The Timeline's note and track: the finish as a range of what's left, paused on you with
    /// your wait not counted, the usual range while it plans, and no track without an estimate.
    @Test func theClockSaysWhenItShouldBeDone() throws {
        let (working, workingFacts) = try facts(.working)
        let clock = JobClock.of(working, facts: workingFacts, mode: "acceptEdits", needs: false, now: now)
        #expect(clock.aside(compact: false) == "9m in · done in about 3–7m")
        #expect(clock.aside(compact: true) == "Done in about 3–7m")
        let track = try #require(clock.track)
        #expect(!track.paused && !track.unknown && track.done < track.rangeStart && track.rangeStart < track.rangeEnd)

        let (planning, planningFacts) = try facts(.planning)
        let plans = JobClock.of(planning, facts: planningFacts, mode: "plan", needs: false, now: now)
        #expect(plans.aside(compact: false) == "2m in · jobs like this take 12–20m")
        #expect(plans.track?.unknown == true)

        let (needs, needsFacts) = try facts(.needs)
        let paused = JobClock.of(needs, facts: needsFacts, mode: "plan", needs: true, now: now)
        #expect(paused.aside(compact: false) == "4m in · paused · then about 9–13m")
        #expect(paused.track?.paused == true)

        let (failed, failedFacts) = try facts(.failed)
        let ended = JobClock.of(failed, facts: failedFacts, mode: nil, needs: false, now: now)
        #expect(ended.aside(compact: false) == "Ran 22m · jobs like this: 12–20m")
        #expect(ended.track == nil)

        let (done, doneFacts) = try facts(.done)
        #expect(JobClock.of(done, facts: doneFacts, mode: nil, needs: false, now: now).took == "Took 19m · estimated 12–20m")

        // Today's obid: how long it's worked, and no track.
        let (bare, none) = try facts(.working, bare: true)
        let plain = JobClock.of(bare, facts: none, mode: nil, needs: false, now: now)
        #expect(plain.aside(compact: false) == "9m in")
        #expect(plain.aside(compact: true) == nil)
        #expect(plain.track == nil)
        #expect(JobClock.of(bare, facts: none, mode: nil, needs: false, now: now + 3600).took == "Took 1h 9m")
    }

    @Test func aCheckSaysWhatItCameTo() {
        #expect(CheckStep(command: "cargo fmt --check", passed: true).result == "passed")
        #expect(CheckStep(command: "t", passed: false, tests: TestCount(passed: 791, failed: 2, total: 793)).result == "791 passed, 2 failed")
        let running = CheckStep(command: "t", running: true, tests: TestCount(passed: 412, total: 793))
        #expect(running.result == "412 of 793")
        #expect(running.progress.map { ($0 * 100).rounded() } == 52)
        #expect(CheckStep(command: "t", running: true).result == nil)
        #expect(CheckStep(command: "t").result == nil)
    }

    @Test func theSessionsTabsSortItsLines() {
        let said = TranscriptEntry(n: 1, kind: "said", summary: "Builds. Running the publish tests.")
        let read = TranscriptEntry(n: 2, kind: "tool", tool: "Read", summary: "publish_api.rs")
        let bash = TranscriptEntry(n: 3, kind: "tool", tool: "Bash", summary: "cargo build -p obid", seconds: 22, exit: 0)
        let edit = TranscriptEntry(n: 4, kind: "tool", tool: "Edit", summary: "jobs.rs", added: 22, removed: 6)
        #expect([said, read, bash, edit].filter(TranscriptEntry.Filter.said.takes) == [said])
        #expect([said, read, bash, edit].filter(TranscriptEntry.Filter.commands.takes) == [bash])
        #expect(bash.text == "cargo build -p obid · exit 0 · 22s")
        #expect(edit.text == "jobs.rs · +22 −6")
        #expect(edit.tag == "Edit" && said.tag == "said")
    }

    /// The iPhone's and the Watch's Job hold each new part as `Lenient`: one they can't read is nil,
    /// and the job, and the list it's in, still read.
    @Test func aLenientPartNeverFailsWhatItsIn() throws {
        struct Wire: Codable, Equatable { var id: String; var estimate: Lenient<JobEstimate>?; var checks: Lenient<[CheckRound]>?; var at: Lenient<Date>? }
        let list = #"[{"id": "a", "estimate": {"low": 60}, "checks": "x", "at": "nope"}, {"id": "b", "estimate": {"low": 60, "high": 120}, "at": "2026-10-19T09:41:00Z"}]"#
        let wires = try Runner.decoder.decode([Wire].self, from: Data(list.utf8))
        #expect(wires.map(\.id) == ["a", "b"])
        #expect(wires[0].estimate?.value == nil && wires[0].checks?.value == nil && wires[0].at?.value == nil)
        #expect(wires[1].estimate?.value == JobEstimate(low: 60, high: 120))
        #expect(wires[1].at?.value == ISO8601DateFormatter().date(from: "2026-10-19T09:41:00Z"))
        #expect(try Runner.decoder.decode(Wire.self, from: Runner.encoder.encode(wires[1])) == wires[1])
    }

    /// A transcript line that can't be read is skipped, never the whole answer.
    @Test func aBadSessionLineIsSkipped() throws {
        let list = #"[{"n": 1, "kind": "said", "summary": "Builds."}, {"n": "two"}, {"n": 3, "kind": "tool", "tool": "Bash"}]"#
        #expect(try TranscriptPage.read(Data(list.utf8)) == TranscriptPage(entries: [TranscriptEntry(n: 1, kind: "said", summary: "Builds."),
                                                                                  TranscriptEntry(n: 3, kind: "tool", tool: "Bash")]))
        let page = try TranscriptPage.read(Data(#"{"next": 9, "entries": [{"n": 4, "kind": "you"}, 5]}"#.utf8))
        #expect(page.entries.map(\.n) == [4] && page.next == 9)
    }

    /// A long session comes in pages (#755): the log follows `next` until there's no more, then
    /// keeps the latest `most` lines and says older ones were dropped.
    @Test func theSessionLogReadsEveryPage() async throws {
        let most = SessionLog.most
        var asked: [Int?] = []
        let (entries, trimmed) = try await SessionLog.read([]) { after in
            asked.append(after)
            let from = (after ?? 0) + 1
            let to = min(from + 999, most + 500)
            return TranscriptPage(entries: (from...to).map { TranscriptEntry(n: $0, kind: "tool") }, next: to < most + 500 ? to : nil)
        }
        #expect(asked == [nil, 1000, 2000])
        #expect(trimmed && entries.count == most && entries.last?.n == most + 500 && entries.first?.n == 501)
        // A runner that keeps answering the same `next` is asked once more, never forever.
        var calls = 0
        _ = try await SessionLog.read([TranscriptEntry(n: 1, kind: "said")]) { _ in calls += 1; return TranscriptPage(entries: [], next: 1) }
        #expect(calls == 1)
    }

    /// The log keeps each line once, by its `n`, in order, and at most its latest `most` lines.
    @Test func theSessionLogKeepsTheLatestLines() {
        func lines(_ range: ClosedRange<Int>) -> [TranscriptEntry] { range.map { TranscriptEntry(n: $0, kind: "tool") } }
        let first = SessionLog.kept([], adding: lines(1...3))
        #expect(first.entries.map(\.n) == [1, 2, 3] && !first.trimmed)
        #expect(SessionLog.kept(first.entries, adding: lines(2...5)).entries.map(\.n) == [1, 2, 3, 4, 5])
        // obid sends a call again under its `n` when it ends: it takes the running one's place.
        let running = TranscriptEntry(n: 3, kind: "tool", tool: "Bash", summary: "cargo test", state: "running")
        let ended = TranscriptEntry(n: 3, kind: "tool", tool: "Bash", summary: "cargo test", state: "done", seconds: 41, exit: 0)
        let updated = SessionLog.kept(lines(1...2) + [running], adding: [ended, TranscriptEntry(n: 4, kind: "said")])
        #expect(updated.entries.map(\.n) == [1, 2, 3, 4])
        #expect(updated.entries[2] == ended)
        #expect(SessionLog.kept(lines(1...2), adding: lines(4...4) + lines(3...3)).entries.map(\.n) == [1, 2, 3, 4])
        let many = SessionLog.kept(lines(1...SessionLog.most), adding: lines(SessionLog.most + 1...SessionLog.most + 10))
        #expect(many.trimmed && many.entries.count == SessionLog.most && many.entries.first?.n == 11)
    }

    @Test func aFailedJobOffersAnotherRoundFirst() {
        #expect(FailedChoice.options(session: true).map(\.label) == ["Give it another round", "Open the session", "Stop here"])
        #expect(FailedChoice.options(session: false).map(\.label) == ["Give it another round", "Stop here"])
        #expect(CardOption.defaultOption(FailedChoice.options(session: true))?.answer == FailedChoice.round.rawValue)
    }

    /// Only a GitHub page over https opens from a job's published address.
    @Test func onlyAGitHubPageOpens() {
        #expect(PublishedLink.url("https://github.com/obi-ai-bot/obi/pull/722")?.host() == "github.com")
        #expect(PublishedLink.url("http://github.com/obi-ai-bot/obi/pull/722") == nil)
        #expect(PublishedLink.url("https://github.com.evil.example/pull/1") == nil)
        #expect(PublishedLink.url("file:///etc/passwd") == nil)
        #expect(PublishedLink.url(nil) == nil)
    }
}
