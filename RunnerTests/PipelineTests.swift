import Foundation
import Testing
@testable import ObyEngine
@testable import oby_runner

struct PipelineTests {
    var work: Job {
        var value = job
        value.pr = nil
        value.kind = .build
        value.base = "dev"
        return value
    }

    func stage(_ id: JobStage.ID, in job: Job) -> JobStage? { job.pipeline.stages.first { $0.id == id } }

    @Test func preparationWorkAndOptionalCheck() {
        var value = work
        #expect(value.pipeline.stages.map(\.id) == [.prepare, .work, .publish, .review, .merged])
        #expect(value.pipeline.number == 1 && value.pipeline.total == 5)
        value.status = .running
        value.phase = .work
        value.round = 2
        value.rounds = 5
        value.step = "Reading Engine/Desk.swift"
        value.check = "swift test"
        #expect(value.pipeline.label == "Stage 2 of 6")
        #expect(stage(.prepare, in: value)?.state == .done)
        #expect(stage(.work, in: value)?.detail == "Round 2 of 5 · Reading Engine/Desk.swift")
        #expect(stage(.check, in: value)?.state == .upcoming)
        value.phase = .check
        #expect(value.pipeline.number == 3)
        #expect(stage(.work, in: value)?.state == .done)
        #expect(stage(.check, in: value)?.detail == "swift test")
        #expect(stage(.check, in: value)?.state == .current)
    }

    @Test(arguments: [JobStage.ID.prepare, .work, .check, .publish])
    func failuresStayInTheirActualStage(_ phase: JobStage.ID) {
        var value = work
        value.phase = phase
        value.check = "swift test"
        value.status = .failed
        value.summary = "A specific reason."
        #expect(stage(phase, in: value)?.state == .failed)
        #expect(stage(phase, in: value)?.reason == value.summary)
        #expect(value.pipeline.stages.filter { $0.state == .failed }.count == 1)
        #expect(stage(.merged, in: value)?.state == .skipped)
    }

    @Test(arguments: [Job.Status.stopped, .interrupted])
    func stoppedOrInterruptedWorkIsntComplete(_ status: Job.Status) {
        var value = work
        value.phase = .work
        value.status = status
        #expect(stage(.work, in: value)?.state == .failed)
        #expect(stage(.work, in: value)?.reason == status.rawValue.capitalized)
        #expect(stage(.publish, in: value)?.state == .skipped)
    }

    @Test func publishingShowsItsStepsAndRetryReason() {
        var value = work
        value.status = .running
        value.phase = .publish
        for step in [PublishStep.scan, .push, .pullRequest] {
            value.publishStep = step
            #expect(stage(.publish, in: value)?.detail == step.detail)
            #expect(stage(.publish, in: value)?.state == .current)
        }
        value.status = .done
        value.commits = 2
        value.publishError = "Push failed."
        #expect(stage(.publish, in: value)?.state == .failed)
        #expect(stage(.publish, in: value)?.reason == "Push failed.")
        #expect(stage(.review, in: value)?.state == .upcoming)
    }

    @Test func noCommitsSkipsPublishingAndCompletesThePipeline() {
        var value = work
        value.kind = .investigate
        value.status = .done
        value.commits = 0
        #expect(value.pipeline.label == "Stage 5 of 5")
        #expect(stage(.publish, in: value)?.state == .skipped)
        #expect(stage(.review, in: value)?.state == .skipped)
        #expect(stage(.merged, in: value)?.state == .skipped)
    }

    @Test func reviewsProceedToTheActualMergeBase() {
        var value = work
        value.status = .done
        value.commits = 1
        value.published = "https://github.com/deskree-inc/oby/pull/99"
        #expect(stage(.publish, in: value)?.state == .done)
        #expect(stage(.review, in: value)?.state == .current)
        value.pullRequest = PullRequestStatus(state: .open, base: "dev", checkedAt: .now)
        #expect(stage(.review, in: value)?.detail == "Waiting for review")
        value.pullRequest?.reviewDecision = .changesRequested
        #expect(stage(.review, in: value)?.state == .failed)
        #expect(stage(.review, in: value)?.reason != nil)
        value.pullRequest?.reviewDecision = .approved
        #expect(stage(.review, in: value)?.state == .done)
        #expect(stage(.merged, in: value)?.state == .current)
        value.pullRequest?.state = .merged
        value.pullRequest?.mergedAt = .now
        #expect(value.pipeline.stages.allSatisfy { $0.state == .done })
        #expect(value.pipeline.label == "Stage 5 of 5")
        #expect(stage(.merged, in: value)?.title == "Merged into dev")
        value.pullRequest?.base = "release"
        #expect(stage(.merged, in: value)?.title == "Merged into release")
        value.pullRequest?.state = .closed
        #expect(stage(.review, in: value)?.state == .failed)
        #expect(stage(.merged, in: value)?.state == .skipped)
    }

    @Test func resumedPublishedJobsShowNewWorkBeforeOldReview() {
        var value = work
        value.status = .done
        value.commits = 1
        value.published = "https://github.com/deskree-inc/oby/pull/99"
        value.pullRequest = PullRequestStatus(state: .open, reviewDecision: .approved, base: "dev", checkedAt: .now)
        value = Desk.resumed(value, "Fix the tests")
        #expect(stage(.work, in: value)?.state == .current)
        #expect(stage(.publish, in: value)?.state == .upcoming)
        #expect(value.pipeline.label == "Stage 2 of 5")
        value.status = .done
        value.commits = 2
        value.publishError = "Push failed."
        #expect(stage(.publish, in: value)?.state == .failed)
        #expect(stage(.review, in: value)?.state == .upcoming)
    }

    @Test func oldJobsDecodeAndAPISendsDerivedStages() throws {
        var value = work
        value.status = .running
        value.started = .now
        let old = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(Job.self, from: old).pipeline.number == 2)
        let json = object(try API.encode(JobJSON(job: value)))
        let pipeline = try #require(json["pipeline"] as? [String: Any])
        #expect(pipeline["number"] as? Int == 2)
        #expect(pipeline["total"] as? Int == 5)
        #expect((pipeline["stages"] as? [[String: Any]])?.count == 5)
        #expect(json["pullRequest"] is NSNull)
    }

    @Test func titlesUseTheIssueOrFirstTaskLine() {
        var value = work
        value.issue = 64
        #expect(value.shortTitle == "Build oby #64")
        value.issue = nil
        value.task = "Short task\nLong instructions"
        value.request = "Raw multi-job request"
        #expect(value.shortTitle == "Short task")
    }
}
