import Foundation
import Testing
@testable import ObyEngine

/// Any restart of the runner (a crash, a reboot, systemd, a manual deploy): the jobs it went down
/// with carry on in their own sessions, with the message each was about to get (Engine/Restarts.swift).
@MainActor
struct RestartTests {
    /// Every agent a desk made, with the session it picks up.
    final class Made { var agents: [(agent: CutOffTests.Agent, resume: String?)] = [] }

    let folder: URL
    let made = Made()
    let desk: Desk

    init() throws {
        folder = try temporaryFolder()
        desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")),
                    restarts: Restarts(file: folder.appending(path: "restarts.json")))
        set(desk)
    }

    func set(_ desk: Desk) {
        desk.makeAgent = { [made] _, _, resume in
            let agent = CutOffTests.Agent()
            made.agents.append((agent, resume))
            return agent
        }
        desk.prepare = { $0 }
    }

    /// The runner starting again on the same folder, after it went down with no warning: nothing
    /// of the last one ran its quit.
    func restart(restarts: Bool = true) -> Desk {
        let restarted = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")),
                             restarts: restarts ? Restarts(file: folder.appending(path: "restarts.json")) : nil)
        set(restarted)
        restarted.resumeAfterRestart()
        return restarted
    }

    /// Dispatches a job on `desk`, and waits for its agent, which gets its session.
    @discardableResult
    func start(_ id: String, rounds: Int? = nil, on desk: Desk? = nil) async throws -> CutOffTests.Agent {
        var work = job
        work.id = id
        work.rounds = rounds
        let before = made.agents.count
        (desk ?? self.desk).dispatch(Desk.Draft(said: "review", reply: "", job: work, guessed: false))
        for _ in 0..<500 where made.agents.count == before { try await Task.sleep(for: .milliseconds(10)) }
        let agent = try #require(made.agents.last?.agent)
        agent.onEvent(.session("\(id)-session"))
        return agent
    }

    @Test func aCrashResumesARunningJobWithItsPendingMessage() async throws {
        let agent = try await start("looping", rounds: 3)
        // Its turn ends and Oby sends the next round's message: then the runner crashes.
        agent.onEvent(.turnEnded(summary: "GOAL NOT MET: the docs", failed: false))
        for _ in 0..<500 where desk.job("looping")?.currentRound != 2 { try await Task.sleep(for: .milliseconds(10)) }
        let restarted = restart()
        #expect(made.agents.count == 2 && made.agents.last?.resume == "looping-session")
        #expect(made.agents.last?.agent.prompt == Restarts.noticeWithMessage + "\n\nKeep going: the docs")
        let job = try #require(restarted.job("looping"))
        #expect(job.status == .running && job.currentRound == 2 && job.step == "Picking up after the runner restarted")
        #expect(restarted.inbox.filter(\.isOpen).isEmpty)
        // The next round's message takes the place of the one its session has now.
        made.agents.last?.agent.onEvent(.turnEnded(summary: "GOAL NOT MET: the tests", failed: false))
        for _ in 0..<500 where restarted.job("looping")?.currentRound != 3 { try await Task.sleep(for: .milliseconds(10)) }
        _ = restart()
        #expect(made.agents.last?.agent.prompt == Restarts.noticeWithMessage + "\n\nKeep going: the tests")
    }

    @Test func aTurnThatEndedLeavesOnlyTheNotice() async throws {
        let agent = try await start("one-turn")
        // Its one turn ended: the agent is finishing (pushing, say) when the runner goes down.
        agent.onEvent(.turnEnded(summary: "Reviewed", failed: false))
        #expect(desk.restarts?.message("one-turn") == nil)
        _ = restart()
        #expect(made.agents.count == 2 && made.agents.last?.resume == "one-turn-session")
        #expect(made.agents.last?.agent.prompt == Restarts.notice)
    }

    @Test func aJobThatEndsLeavesNothingToPickUp() async throws {
        let agent = try await start("ending")
        agent.onEvent(.finished(summary: "Reviewed", failed: false))
        for _ in 0..<500 where desk.job("ending")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(desk.restarts?.message("ending") == nil)
        let restarted = restart()
        #expect(made.agents.count == 1 && restarted.job("ending")?.status == .done)
    }

    @Test func aStoppedJobAndAJobWithAQuestionStayInterrupted() async throws {
        try await start("stopped")
        desk.stop("stopped")
        let asking = try await start("asking")
        asking.onEvent(.turnEnded(summary: "QUESTION: Which option?\nOPTIONS: One | Two", failed: false))
        let restarted = restart()
        #expect(made.agents.count == 2)
        #expect(restarted.job("stopped")?.status == .stopped)
        #expect(restarted.job("asking")?.status == .interrupted && restarted.job("asking")?.question?.text == "Which option?")
        #expect(restarted.inbox.contains { $0.job == "asking" && $0.kind == .question && $0.isOpen })
        // The answer picks its session up.
        try restarted.message("asking", "One")
        #expect(made.agents.count == 3 && made.agents.last?.resume == "asking-session" && made.agents.last?.agent.prompt == "One")
    }

    @Test func aCrashLoopStopsAfterTwoResumes() async throws {
        try await start("looping")
        _ = restart()
        _ = restart()
        #expect(made.agents.count == 3)
        let third = restart()
        #expect(made.agents.count == 3)
        let job = try #require(third.job("looping"))
        #expect(job.status == .interrupted && job.summary.hasPrefix(Restarts.looping))
        #expect(third.inbox.filter { $0.job == "looping" && $0.isOpen }.count == 1)
        // It stays put after that, with the same one item.
        let fourth = restart()
        #expect(made.agents.count == 3 && fourth.job("looping")?.status == .interrupted)
        #expect(fourth.inbox.filter { $0.job == "looping" }.count == 1)
        // Telling it something carries on in its session, with the message it was about to get first.
        let pending = try #require(fourth.restarts?.message("looping"))
        try fourth.message("looping", "Go on")
        #expect(made.agents.count == 4 && made.agents.last?.resume == "looping-session")
        #expect(made.agents.last?.agent.prompt == pending + "\n\nGo on")
    }

    @Test func aQueuedJobStartsAfterTheRestart() async throws {
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        var queued = job
        queued.id = "queued"
        queued.status = .queued
        queued.startCommit = String(repeating: "a", count: 40)
        store.save(queued)
        let restarted = restart()
        #expect(made.agents.count == 1 && made.agents[0].resume == nil)
        #expect(made.agents[0].agent.prompt.contains(queued.task))
        #expect(restarted.job("queued")?.status == .running)
    }

    @Test func quittingTheRunnerLeavesItsJobsToCarryOn() async throws {
        try await start("quit")
        desk.quit()
        let restarted = restart()
        #expect(made.agents.count == 2 && made.agents.last?.resume == "quit-session")
        #expect(restarted.job("quit")?.status == .running)
    }

    @Test func quittingOnTheMacLeavesJobsInterrupted() async throws {
        let mac = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        set(mac)
        try await start("mac", on: mac)
        mac.quit()
        let again = restart(restarts: false)
        #expect(made.agents.count == 1 && again.job("mac")?.status == .interrupted)
    }
}
