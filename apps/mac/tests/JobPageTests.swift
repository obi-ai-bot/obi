import Foundation
import SwiftUI
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

    /// Teammates' open pull requests on the job's files (obid only): one line under the head.
    @Test func teammatesPullRequestsReadAsOneLine() throws {
        let json = #"{"id": "j", "teammates": {"prs": [{"number": 812, "title": "Ignore this", "author": "alice", "branch": "feat/run","#
            + #" "url": "https://github.com/acme/shop/pull/812", "files": ["src/jobs.rs"], "clash": null},"#
            + #" {"number": 813, "title": "x", "author": "bob", "branch": "", "url": "", "files": ["src/jobs.rs", "src/lib.rs"], "clash": null}], "rechecked": false}}"#
        var teammates = try #require(try Runner.decoder.decode(RunnerJobExtras.self, from: Data(json.utf8)).teammates)
        #expect(teammates.line == "Also changed in @alice's #812 and @bob's #813 (src/jobs.rs, src/lib.rs)")
        teammates.prs[0].clash = ["`fn run(&self)` in src/jobs.rs"]
        #expect(teammates.line == "Same code changed in @alice's #812 and @bob's #813 (src/jobs.rs, src/lib.rs)")
        teammates.prs = []
        #expect(teammates.line == nil)
        #expect(try Runner.decoder.decode(RunnerJobExtras.self, from: Data(#"{"id": "j", "teammates": null}"#.utf8)).teammates == nil)
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
        #expect(bash.meta == nil && edit.meta == "+22 −6")
        #expect(TranscriptEntry(n: 5, kind: "tool", tool: "Bash", state: "failed", exit: 101).meta == "exit 101")
        // obid's `activity` decides a call's filter before its tool's name does.
        #expect(TranscriptEntry.Filter.of(TranscriptEntry(n: 6, kind: "tool", tool: "mcp__tetrix__impact", activity: "tetrix")) == .tetrix)
        #expect(TranscriptEntry.Filter.of(TranscriptEntry(n: 7, kind: "tool", tool: "Bash", activity: "test")) == .commands)
        #expect(TranscriptEntry.Filter.of(TranscriptEntry(n: 8, kind: "tool", tool: "Grep")) == .reads)
        #expect(!TranscriptEntry.Filter.all.takes(TranscriptEntry(n: 9, kind: "start")))
        #expect(TranscriptEntry.Filter.said.takes(TranscriptEntry(n: 10, kind: "thought", text: "…")))
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
    @MainActor @Test func theSessionLogReadsEveryPage() async throws {
        let most = LiveSession.most
        var asked: [Int?] = []
        let fresh = try await LiveSession.pages(after: nil) { after in
            asked.append(after)
            let from = (after ?? 0) + 1
            let to = min(from + 999, most + 500)
            return TranscriptPage(entries: (from...to).map { TranscriptEntry(n: $0, kind: "tool") }, next: to < most + 500 ? to : nil)
        }
        let (entries, trimmed) = LiveSession.kept([], adding: fresh)
        #expect(asked == [nil, 1000, 2000])
        #expect(trimmed && entries.count == most && entries.last?.n == most + 500 && entries.first?.n == 501)
        // A runner that keeps answering the same `next` is asked once more, never forever.
        var calls = 0
        _ = try await LiveSession.pages(after: 1) { _ in calls += 1; return TranscriptPage(entries: [], next: 1) }
        #expect(calls == 1)
    }

    /// The log keeps each line once, by its `n`, in order, and at most its latest `most` lines.
    @Test func theSessionLogKeepsTheLatestLines() {
        func lines(_ range: ClosedRange<Int>) -> [TranscriptEntry] { range.map { TranscriptEntry(n: $0, kind: "tool") } }
        let first = LiveSession.kept([], adding: lines(1...3))
        #expect(first.entries.map(\.n) == [1, 2, 3] && !first.trimmed)
        #expect(LiveSession.kept(first.entries, adding: lines(2...5)).entries.map(\.n) == [1, 2, 3, 4, 5])
        // obid sends a call again under its `n` when it ends: it takes the running one's place.
        let running = TranscriptEntry(n: 3, kind: "tool", tool: "Bash", summary: "cargo test", state: "running")
        let ended = TranscriptEntry(n: 3, kind: "tool", tool: "Bash", summary: "cargo test", state: "done", seconds: 41, exit: 0)
        let updated = LiveSession.kept(lines(1...2) + [running], adding: [ended, TranscriptEntry(n: 4, kind: "said")])
        #expect(updated.entries.map(\.n) == [1, 2, 3, 4])
        #expect(updated.entries[2] == ended)
        #expect(LiveSession.kept(lines(1...2), adding: lines(4...4) + lines(3...3)).entries.map(\.n) == [1, 2, 3, 4])
        let many = LiveSession.kept(lines(1...LiveSession.most), adding: lines(LiveSession.most + 1...LiveSession.most + 10))
        #expect(many.trimmed && many.entries.count == LiveSession.most && many.entries.first?.n == 11)
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

    /// The event stream's `transcript` (#755, #784): an entry, or more words for the one being written.
    @Test func aTranscriptEventReads() throws {
        let entry = try Runner.decoder.decode(TranscriptEvent.self, from: Data(#"{"job": "j", "entry": {"n": 3, "kind": "tool", "tool": "Bash", "state": "running"}}"#.utf8))
        #expect(entry.entry?.n == 3 && entry.entry?.running == true && entry.append == nil)
        let more = try Runner.decoder.decode(TranscriptEvent.self, from: Data(#"{"job": "j", "n": 2, "append": " and the tests"}"#.utf8))
        #expect(more == TranscriptEvent(job: "j", n: 2, append: " and the tests"))
        // An entry that can't be read is left out, never the event.
        #expect(try Runner.decoder.decode(TranscriptEvent.self, from: Data(#"{"job": "j", "entry": {"n": "x"}}"#.utf8)).entry == nil)
        var parser = EventParser()
        _ = parser.feed("event: transcript")
        _ = parser.feed(#"data: {"job": "j", "n": 2, "append": "!"}"#)
        #expect(parser.feed("") == .transcript(TranscriptEvent(job: "j", n: 2, append: "!")))
    }

    /// The live session puts each event in place, adds what the agent writes to its words, leaves
    /// another job's alone, and opens a row only once obid serves detail.
    @MainActor @Test func theLiveSessionFollowsItsEvents() async {
        let entries = [TranscriptEntry(n: 1, kind: "start", summary: "Started on Claude Code"),
                       TranscriptEntry(n: 2, kind: "said", text: "Reading"),
                       TranscriptEntry(n: 3, kind: "tool", tool: "Read", summary: "Reading scan.rs", state: "done", seconds: 0.2)]
        let served = LiveSession(job: "j", load: { _ in TranscriptPage(entries: entries) },
                                 loadDetail: { n in TranscriptDetail(output: .init(text: "line \(n)", lines: 1)) })
        await served.catchUp()
        #expect(served.entries.map(\.n) == [1, 2, 3] && served.detailServed == true)
        served.apply(TranscriptEvent(job: "j", n: 2, append: " the scan"))
        served.apply(TranscriptEvent(job: "other", n: 2, append: " never"))
        served.apply(TranscriptEvent(job: "j", entry: TranscriptEntry(n: 4, kind: "tool", tool: "Bash", state: "running")))
        #expect(served.entries[1].words == "Reading the scan")
        #expect(served.entries.map(\.n) == [1, 2, 3, 4])
        #expect(await served.detail(3)?.output?.text == "line 3")

        // Today's obid: the detail route answers 404, so no row opens and none is asked again.
        var asked = 0
        let unserved = LiveSession(job: "j", load: { _ in TranscriptPage(entries: entries) },
                                   loadDetail: { _ in asked += 1; throw RunnerError(message: "Not found", status: 404) })
        await unserved.catchUp()
        await unserved.catchUp()
        #expect(unserved.detailServed == false && asked == 1)
        #expect(await unserved.detail(3) == nil && asked == 1)

        // A job the runner keeps no session for is asked no more.
        let gone = LiveSession(job: "j", load: { _ in throw RunnerError(message: "Not found", status: 404) }, loadDetail: { _ in TranscriptDetail() })
        await gone.catchUp()
        #expect(gone.unavailable && gone.loaded)
    }

    @Test func anEntrysDetailReads() throws {
        let answer = #"{"n": 6, "kind": "tool", "detail": {"input": {"command": "cargo test", "timeout": 600000}, "output": {"text": "ok\nsigned with [vault: TEAM]", "lines": 1284, "truncated": true, "exit": 101}, "diff": [{"path": "scan.rs", "patch": "@@ -1 +1 @@\n-a\n+b"}]}}"#
        let detail = try TranscriptDetail.read(Data(answer.utf8))
        #expect(detail.command == "cargo test" && detail.given == ["timeout: 600000"])
        #expect(detail.output?.exit == 101 && detail.output?.lines == 1284 && detail.diff?.first?.path == "scan.rs")
        // A part that can't be read is left out.
        let odd = try TranscriptDetail.read(Data(#"{"detail": {"input": {"file_path": "a.swift"}, "output": "nope"}}"#.utf8))
        #expect(odd.output == nil && odd.given == ["file_path: a.swift"])
        #expect(try TranscriptDetail.read(Data(#"{"n": 1}"#.utf8)) == TranscriptDetail())
        // One file of the diff that can't be read is left out, never the others.
        let diff = try TranscriptDetail.read(Data(#"{"detail": {"diff": [{"path": "a.swift"}, {"path": "b.swift", "patch": "+b"}]}}"#.utf8))
        #expect(diff.diff == [TranscriptDetail.FileDiff(path: "b.swift", patch: "+b")])
    }

    /// A vault value or a redacted line shows as a chip with its name, never brackets or the value.
    @Test func maskedValuesAreChips() {
        let masked = SessionText.masked("Signing with team [vault: APPLE_TEAM_ID] and [redacted: aws-key].")
        #expect(String(masked.characters) == "Signing with team  vault: APPLE_TEAM_ID  and  redacted: aws-key .")
        #expect(masked.runs.count(where: { $0.backgroundColor != nil }) == 2)
        #expect(JobPageText.took(0.2) == "0.2s" && JobPageText.took(3) == "3s" && JobPageText.took(41.4) == "41s" && JobPageText.took(192) == "3m 12s")
    }

    /// What an agent writes never opens anything: every link is taken out of its words, whatever its scheme.
    @Test func theAgentsWordsHaveNoLinks() {
        let said = SessionText.said("See [the file](file:///etc/passwd), [run it](shortcuts://run-shortcut?name=x), [docs](https://example.com) and `code`.")
        #expect(said.runs.allSatisfy { $0.link == nil })
        #expect(String(said.characters).contains("the file") && String(said.characters).contains("code"))
    }

    /// A read merges into the entries as they are when it's back: an event that came meanwhile, and
    /// words appended to an entry the read sent again, stay.
    @MainActor @Test func aReadKeepsWhatCameWhileItWasAway() async {
        var session: LiveSession?
        var reads = 0
        session = LiveSession(job: "j", load: { @MainActor after in
            reads += 1
            if after == nil { return TranscriptPage(entries: [TranscriptEntry(n: 1, kind: "said", text: "Reading")]) }
            session?.apply(TranscriptEvent(job: "j", n: 1, append: " the scan"))
            session?.apply(TranscriptEvent(job: "j", entry: TranscriptEntry(n: 3, kind: "tool", tool: "Bash", state: "running")))
            return TranscriptPage(entries: [TranscriptEntry(n: 1, kind: "said", text: "Reading"), TranscriptEntry(n: 2, kind: "tool", tool: "Read", state: "done")])
        }, loadDetail: { _ in throw RunnerError(message: "Not found", status: 404) })
        guard let session else { return }
        await session.catchUp()
        await session.catchUp()
        #expect(reads == 2)
        #expect(session.entries.map(\.n) == [1, 2, 3])
        #expect(session.entries[0].words == "Reading the scan")
        #expect(session.arriving == 1)
        #expect(session.counts[.all] == 3 && session.counts[.said] == 1)
    }

    /// One field of the wrong type is nil, never the entry; a to-do item that can't be read is left out.
    @Test func aBadFieldDoesntDropAnEntry() throws {
        let page = try TranscriptPage.read(Data(#"{"next": null, "entries": [{"n": 1, "kind": "tool", "tool": "Bash", "seconds": "slow", "exit": "x", "state": "done"}, {"n": 2, "kind": "plan", "todos": [{"text": "Find it", "state": 3}, {"state": "done"}]}]}"#.utf8))
        #expect(page.entries.map(\.n) == [1, 2])
        #expect(page.entries[0].seconds == nil && page.entries[0].exit == nil && page.entries[0].state == "done")
        #expect(page.entries[1].todos == [TranscriptEntry.Todo(text: "Find it")])
    }

    /// A tool row's verb, then what it's on in code.
    @Test func aToolRowSaysItsVerbThenItsTarget() {
        let read = TranscriptEntry(n: 1, kind: "tool", tool: "Read", summary: "Reading scan.rs", activity: "read", file: "core/crates/obid/src/scan.rs")
        #expect(read.verbAndTarget.verb == "Reading" && read.verbAndTarget.target == "core/crates/obid/src/scan.rs")
        let run = TranscriptEntry(n: 2, kind: "tool", tool: "Bash", summary: "Running cargo test -p obid", activity: "command")
        #expect(run.verbAndTarget.verb == "Running" && run.verbAndTarget.target == "cargo test -p obid")
        let other = TranscriptEntry(n: 3, kind: "tool", tool: "Task", summary: "Asked a helper")
        #expect(other.verbAndTarget.verb == "Asked a helper" && other.verbAndTarget.target == nil)
    }
}
