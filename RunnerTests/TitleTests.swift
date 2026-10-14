import Foundation
import Testing
@testable import ObyEngine
@testable import ObyShared
@testable import oby_runner

/// The brain's short title for each job, and how the job screen says where it got to.
@MainActor
struct TitleTests {
    var titled: Job {
        var value = job
        value.title = "Job progress screen"
        return value
    }

    @Test func theBrainTitlesEveryDispatch() throws {
        let context = BrainContext(accounts: ["claude": ["default"]], repos: ["deskree-inc/oby"])
        let schema = try #require(try JSONSerialization.jsonObject(with: Plan.schema(for: context)) as? [String: Any])
        let dispatch = try #require(((schema["properties"] as? [String: Any])?["dispatches"] as? [String: Any])?["items"] as? [String: Any])
        #expect((dispatch["required"] as? [String])?.contains("title") == true)
        #expect(Planner.system(canary: "c4n4ry").contains("3 to 6 words"))

        let json = #"{"action":"dispatch","reply":"Oby will fix it.","question":null,"dispatches":[{"agent":"claude","account":"default","repo":"deskree-inc/oby","base_branch":null,"pr":null,"issue":null,"epic":null,"kind":"fix","title":"Mac runner notifications","task":"Fix the notifications","inputs":[],"rounds":1,"check":null,"complexity":"routine"}]}"#
        var plan = try Plan.decode(Data(json.utf8))
        #expect(plan.dispatches.first?.title == "Mac runner notifications")
        #expect(plan.problems(in: context, canary: "c4n4ry").isEmpty)
        plan.dispatches[0].title = "Two\nlines"
        #expect(plan.problems(in: context, canary: "c4n4ry") == ["title must be one line of 1 to 60 characters"])
        plan.dispatches[0].title = String(repeating: "x", count: 61)
        #expect(plan.problems(in: context, canary: "c4n4ry") == ["title must be one line of 1 to 60 characters"])
        // The rules have no model to write one.
        #expect(Rules.plan("fix oby", context: context).dispatches.first?.title == nil)
    }

    @Test func theJobKeepsItsTitleAndTheAPISendsIt() throws {
        let saved = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(titled))
        #expect(saved.title == "Job progress screen")
        let store = JobStore(url: try temporaryFolder().appending(path: "titles.sqlite"))
        store.save(titled)
        #expect(store.recent().first?.title == "Job progress screen")

        let decoded = object(try API.encode(JobJSON(job: titled)))
        #expect(decoded["title"] as? String == "Job progress screen")
        #expect(decoded.count == 65)
        #expect(decoded["report"] as? Bool == false)
        var done = titled
        done.status = .done
        #expect(titled.heading == "Job progress screen" && done.doneLine == "Done: Job progress screen")
        let state = Push.State(titled, working: 1)
        #expect(state.title == "Job progress screen")
        var failed = titled
        failed.status = .failed
        failed.summary = "The build broke."
        let alert = try #require(object(try Push.notification(.failed, for: failed))["aps"] as? [String: Any])
        #expect(alert["alert"] as? [String: String] == ["title": "Failed: Job progress screen", "body": "The build broke."])
    }

    @Test func jobsWithoutATitleFallBackToTheFirstLine() throws {
        var untitled = job
        untitled.pr = nil
        untitled.task = "Count the Swift files\nin Engine/"
        untitled.request = "In oby, count the Swift files"
        for title in [nil, "", "  \n"] {
            untitled.title = title
            #expect(object(try API.encode(JobJSON(job: untitled)))["title"] as? String == "Count the Swift files")
            #expect(untitled.heading == "In oby, count the Swift files")
            #expect(Push.State(untitled, working: 0).title == "In oby, count the Swift files")
        }
        // With a pull request or an issue, its number.
        #expect(object(try API.encode(JobJSON(job: job)))["title"] as? String == "Review oby #33")
        #expect(job.heading == "Review oby #33")
    }

    @Test func aPullRequestMergedWithNoDecisionSaysSo() {
        var merged = job
        merged.pr = nil
        merged.kind = .build
        merged.base = "dev"
        merged.status = .done
        merged.commits = 1
        merged.published = "https://github.com/deskree-inc/oby/pull/99"
        merged.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: .now, checkedAt: .now)
        let review = { merged.pipeline.stages.first { $0.id == .review } }
        #expect(review()?.state == .done && review()?.detail == "Merged without review")
        merged.pullRequest?.reviewDecision = .waiting
        #expect(review()?.detail == "Merged without review")
        merged.pullRequest?.reviewDecision = .approved
        #expect(review()?.detail == "Approved")
        // Still open with no decision, it waits.
        merged.pullRequest = PullRequestStatus(state: .open, base: "dev", checkedAt: .now)
        #expect(review()?.detail == "Waiting for review")
    }

    @Test func aFinishedJobSaysHowLongItTook() {
        let started = Date(timeIntervalSince1970: 1_791_582_173)
        #expect(Elapsed.line(started: started, finished: started + 505) == "Took 8m 25s")
        #expect(Elapsed.line(started: started, finished: started + 3_900) == "Took 1h 5m")
        #expect(Elapsed.line(started: started, finished: started + 7) == "Took 0m 7s")
        // While it runs, the time so far.
        #expect(Elapsed.line(started: started, finished: nil, now: started + 505) == "8m 25s elapsed")
        // A clock that's behind never shows a negative time.
        #expect(Elapsed.line(started: started, finished: started - 5) == "Took 0m 0s")
    }
}
