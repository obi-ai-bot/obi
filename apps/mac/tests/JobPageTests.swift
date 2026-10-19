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
}
