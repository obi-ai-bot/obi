import Foundation
import Testing
@testable import ObyEngine
@testable import oby_runner

/// A pull request that conflicts with dev is rebased by its own agent, and the rebased branch
/// goes out with --force-with-lease over the commit Oby pushed (#159).
extension CheckTests {
    nonisolated static let onto = "dddd0000dddd0000dddd0000dddd0000dddd0000"

    /// A round rebased the published branch: the same number of commits, a new head. Until it's
    /// pushed, every rewritten commit counts as unpublished; once it is, the pushed count and head follow.
    @Test func aRebasedBranchWithTheSameCountIsPublished() async throws {
        _ = try await approved()
        #expect(desk.job("author")?.pushed == 2 && desk.job("author")?.pushedHead == Self.head)
        // Nothing of the old head is in the rebased branch.
        desk.countUnpushed = { _, _, pushed in pushed == CheckTests.head ? 2 : 0 }
        let failure = "Couldn't push oby/fix-75: the remote hung up."
        final class Asked { var jobs: [Job] = [] }
        let asked = Asked()
        desk.publishOnItsOwn = { job, _, _ in
            asked.jobs.append(job)
            throw Shell.Failure(message: failure)
        }
        try desk.message("author", "rebase onto dev")
        try await until("the author runs again") { desk.job("author")?.status == .running }
        try await endRound(try #require(made.agents.last?.agent), "refactor: rebase onto dev")
        // It tried to publish the rebase, and the failure leaves all of it unpublished, for Publish by hand.
        #expect(asked.jobs.count == 1 && asked.jobs.first?.commits == 2 && asked.jobs.first?.unpublished == 2)
        var author = try #require(desk.job("author"))
        #expect(author.commits == 2 && author.pushed == 0 && author.unpublished == 2 && author.canPublish)
        #expect(author.publishError == failure)

        // Published by hand: the new head is the pull request's, with both commits on it.
        desk.publishByHand = { [url] job, _, _, hooks in
            hooks.sent(Outgoing(action: .push, repo: job.repo, id: CheckTests.next, branch: job.branch))
            return url
        }
        try await desk.publish("author") { _ in }
        author = try #require(desk.job("author"))
        #expect(author.pushedHead == Self.next && author.pushed == 2 && author.unpublished == 0 && !author.canPublish)
    }

    /// The same, publishing by itself as the round ends.
    @Test func aRebaseRoundPublishesByItself() async throws {
        _ = try await approved()
        desk.countUnpushed = { _, _, pushed in pushed == CheckTests.head ? 2 : 0 }
        made.pushes = [Self.next]
        try desk.message("author", "rebase onto dev")
        try await until("the author runs again") { desk.job("author")?.status == .running }
        try await endRound(try #require(made.agents.last?.agent), "refactor: rebase onto dev")
        let author = try #require(desk.job("author"))
        #expect(author.pushedHead == Self.next && author.pushed == 2 && author.unpublished == 0)
        #expect(author.outgoing?.filter { $0.action == .push }.map(\.id) == [Self.head, Self.next])
    }

    /// GitHub says the pull request conflicts with dev: the merge isn't tried again, and the author's
    /// agent gets one rebase round onto dev as Oby fetched it. Oby handles that by itself: no merge
    /// error, nothing in the inbox and no failure (#209). The rebase publishes, is reviewed, checked
    /// and merged again; the same conflict with the same dev again needs you, and is a failure.
    @Test func aConflictStartsOneRebaseRoundPerDevHead() async throws {
        final class Fetched { var count = 0; var onto = CheckTests.onto }
        let fetched = Fetched()
        desk.fetchBase = { _, base in
            #expect(base == "dev")
            fetched.count += 1
            return fetched.onto
        }
        let check = try await approved()
        _ = desk.nextMacCheck(mac: "Studio")
        made.mergeError = MacCheck.Conflict(base: "dev")
        try desk.macCheckEnded(check.id, MacCheck.Report(passed: true, steps: steps, failures: []))
        try await until("the author rebases") { desk.job("author")?.status == .running && made.agents.count == 3 }
        var author = try #require(desk.job("author"))
        #expect(author.mergeError == nil && !author.needsYou && desk.inbox.allSatisfy { $0.job != "author" || !$0.isOpen })
        #expect(!Failures.found(in: author).contains { $0.trigger == .mergeError })
        #expect(author.rebasedOnto == Self.onto && author.rebases?.count == 1 && author.step == "Rebasing onto dev" && fetched.count == 1)
        let round = try #require(made.agents.last)
        #expect(round.job.id == "author" && round.resume == "e6a24229")
        #expect(round.agent.prompt.contains("origin/dev is at \(Self.onto)") && round.agent.prompt.contains("`git rebase \(Self.onto)`"))
        #expect(round.agent.prompt.contains("Never merge dev into this branch."))

        // The rebased branch goes out, and the merge error with the old head.
        desk.countUnpushed = { _, _, pushed in pushed == CheckTests.head ? 2 : 0 }
        made.pushes = [Self.next]
        try await endRound(round.agent, "refactor: rebase onto dev")
        author = try #require(desk.job("author"))
        #expect(author.pushedHead == Self.next && author.unpublished == 0 && author.mergeError == nil)
        try await approve()
        try await until("the rebase is checked") { desk.job("author")?.macCheck?.head == Self.next }

        // Still conflicting with the same dev: no second round, and it needs you.
        let second = try #require(desk.nextMacCheck(mac: "Studio"))
        try desk.macCheckEnded(second.id, MacCheck.Report(passed: true, steps: steps, failures: []))
        try await until("the merge stops") { desk.job("author")?.mergeError != nil && fetched.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        author = try #require(desk.job("author"))
        #expect(made.agents.count == 4 && !author.isActive && made.merged.isEmpty)
        #expect(author.mergeError == "Not merged: it conflicts with dev. Oby rebased it onto dddd0000dddd already, and it still conflicts."
                && author.mergeNeedsYou && author.macCheck?.transient == false)
        #expect(Failures.found(in: author).map(\.trigger) == [.mergeError])
        // Nothing retries it by itself.
        desk.resumeChecks()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fetched.count == 2 && made.agents.count == 4)

        // dev moved on: trying again rebases once more.
        fetched.onto = "eeee0000eeee0000eeee0000eeee0000eeee0000"
        try desk.retryMerge("author")
        try await until("the author rebases again") { made.agents.count == 5 && desk.job("author")?.status == .running }
        #expect(desk.job("author")?.rebasedOnto == fetched.onto)
    }

    /// Oby rebases a pull request 6 times a day at most (#237): a 7th conflict needs you, and is a failure.
    @Test func aSeventhConflictInADayIsntRebased() async throws {
        final class Fetched { var count = 0 }
        let fetched = Fetched()
        desk.fetchBase = { _, _ in
            fetched.count += 1
            return "ffff\(fetched.count)"
        }
        let check = try await approved()
        var author = try #require(desk.job("author"))
        // Rebased 6 times today (and once yesterday, which no longer counts).
        author.rebases = [Date.now.addingTimeInterval(-90_000)] + (1...6).map { Date.now.addingTimeInterval(TimeInterval(-3600 * $0)) }
        desk.replace(author)
        _ = desk.nextMacCheck(mac: "Studio")
        made.mergeError = MacCheck.Conflict(base: "dev")
        try desk.macCheckEnded(check.id, MacCheck.Report(passed: true, steps: steps, failures: []))
        try await until("the merge stops") { desk.job("author")?.mergeError != nil }
        author = try #require(desk.job("author"))
        #expect(author.mergeError == "Not merged: it conflicts with dev. Oby rebased it 6 times today already: a person takes it from here.")
        #expect(fetched.count == 0 && !author.isActive && author.mergeNeedsYou && made.agents.count == 2)
        #expect(Failures.found(in: author).map(\.trigger) == [.mergeError])
    }

    /// A conflict Oby can't rebase (the job has no session) is a merge error and a failure.
    @Test func aConflictWithNoSessionToRebaseIsAFailure() async throws {
        let check = try await approved()
        var author = try #require(desk.job("author"))
        author.session = nil
        desk.replace(author)
        _ = desk.nextMacCheck(mac: "Studio")
        made.mergeError = MacCheck.Conflict(base: "dev")
        try desk.macCheckEnded(check.id, MacCheck.Report(passed: true, steps: steps, failures: []))
        try await until("the merge stops") { desk.job("author")?.mergeError != nil }
        author = try #require(desk.job("author"))
        #expect(author.mergeError == "Not merged: it conflicts with dev. The job has no session to rebase it.")
        #expect(Failures.found(in: author).map(\.trigger) == [.mergeError])
    }

    @Test func gitHubsConflictIsReadFromThePullRequest() {
        #expect(MacCheck.conflicted(Data(#"{"mergeable": false, "mergeable_state": "dirty"}"#.utf8)))
        #expect(MacCheck.conflicted(Data(#"{"mergeable": null, "mergeable_state": "dirty"}"#.utf8)))
        #expect(!MacCheck.conflicted(Data(#"{"mergeable": null, "mergeable_state": "unknown"}"#.utf8)))
        #expect(!MacCheck.conflicted(Data(#"{"mergeable": true, "mergeable_state": "blocked"}"#.utf8)))
        #expect(MacCheck.Conflict(base: "dev").localizedDescription == "it conflicts with dev.")
    }
}

/// Publish against a real remote: a branch Oby pushed, rebased, goes out with --force-with-lease
/// on the commit Oby pushed; anything else on it is someone else's, and stays.
struct LeaseTests {
    let folder: URL
    let remote: URL
    let work: URL
    var fix: Job

    init() async throws {
        folder = try temporaryFolder()
        remote = folder.appending(path: "remote.git")
        work = folder.appending(path: "work")
        try await Shell.ok(["git", "init", "--quiet", "--bare", "-b", "dev", remote.path])
        try await Shell.ok(["git", "init", "--quiet", "-b", "dev", work.path])
        try await AlreadyOnBaseTests.commit("README.md", in: work)
        try await AlreadyOnBaseTests.git(["switch", "--quiet", "-c", "oby/fix-1"], in: work)
        try await AlreadyOnBaseTests.commit("a.txt", in: work)
        fix = job
        fix.kind = .fix
        fix.branch = "oby/fix-1"
        fix.base = "dev"
    }

    func head() async throws -> String { try await AlreadyOnBaseTests.git(["rev-parse", "HEAD"], in: work) }

    /// Pushes the branch as Publish does, noting the push on the job.
    mutating func publish() async throws {
        let head = try await head()
        let lease = try await Publish.lease(for: head, of: fix, from: work, remote: remote.path)
        try await Publish.push(head, of: fix, from: work, over: lease, to: remote.path)
        fix.outgoing = (fix.outgoing ?? []) + [Outgoing(action: .push, repo: fix.repo, id: head, branch: fix.branch)]
    }

    func there() async throws -> String? { try await Publish.remoteHead(of: fix, from: work, remote: remote.path) }

    /// dev moves on, and the branch is rebased onto it: one commit, rewritten.
    func rebase() async throws {
        try await AlreadyOnBaseTests.git(["switch", "--quiet", "dev"], in: work)
        try await AlreadyOnBaseTests.commit("dev.txt", in: work)
        try await AlreadyOnBaseTests.git(["switch", "--quiet", "oby/fix-1"], in: work)
        try await AlreadyOnBaseTests.git(["rebase", "--quiet", "dev"], in: work)
    }

    @Test mutating func aRebasedBranchReplacesWhatObyPushed() async throws {
        #expect(try await there() == nil)
        try await publish()
        let first = try await head()
        #expect(try await there() == first)
        // A new commit on top only adds: no lease.
        try await AlreadyOnBaseTests.commit("b.txt", in: work)
        #expect(try await Publish.lease(for: try await head(), of: fix, from: work, remote: remote.path) == nil)
        try await publish()
        let second = try await head()

        try await rebase()
        let rebased = try await head()
        #expect(rebased != second)
        #expect(try await Publish.lease(for: rebased, of: fix, from: work, remote: remote.path) == second)
        try await publish()
        #expect(try await there() == rebased && fix.pushedHead == rebased)
        // The same commit again pushes nothing new.
        #expect(try await Publish.lease(for: rebased, of: fix, from: work, remote: remote.path) == nil)
    }

    @Test mutating func someoneElsesPushIsNeverOverwritten() async throws {
        try await publish()
        let ours = try await head()
        // Someone else pushes to the branch.
        try await AlreadyOnBaseTests.git(["switch", "--quiet", "-c", "theirs"], in: work)
        try await AlreadyOnBaseTests.commit("theirs.txt", in: work)
        let theirs = try await head()
        try await AlreadyOnBaseTests.git(["push", "--quiet", remote.path, "theirs:refs/heads/oby/fix-1"], in: work)
        try await AlreadyOnBaseTests.git(["switch", "--quiet", "oby/fix-1"], in: work)
        try await rebase()
        let rebased = try await head()
        let fix = fix
        let work = work, remote = remote
        let refused = await #expect(throws: Shell.Failure.self) { try await Publish.lease(for: rebased, of: fix, from: work, remote: remote.path) }
        #expect(refused?.message == Publish.overwritten(fix, theirs))
        #expect(refused?.message.hasPrefix("Not published: oby/fix-1 on GitHub is at \(theirs.prefix(12)), not the commit Oby pushed") == true)
        // The branch moved after Oby read it: the lease on what Oby pushed doesn't hold.
        let moved = await #expect(throws: Shell.Failure.self) { try await Publish.push(rebased, of: fix, from: work, over: ours, to: remote.path) }
        #expect(moved?.message == "Not published: oby/fix-1 moved on GitHub while Oby pushed the rebase, so it would overwrite someone else's work.")
        #expect(try await there() == theirs)
    }

    @Test func noForcePushToABranchObyDidntMake() async throws {
        var other = fix
        other.branch = "feature/login"
        let head = try await head()
        let work = work, remote = remote
        let refused = await #expect(throws: Shell.Failure.self) { try await Publish.push(head, of: other, from: work, over: head, to: remote.path) }
        #expect(refused?.message == "Oby never force-pushes feature/login: only the oby/ branches it made.")
        // And Publish refuses it, and main and dev, before anything else.
        #expect(Publish.refusal(other, base: "dev", defaultBranch: "main") == "Oby only publishes its own oby/ branches, not feature/login.")
        other.branch = "dev"
        #expect(Publish.refusal(other, base: "dev", defaultBranch: "main") != nil)
        #expect(try await Publish.remoteHead(of: other, from: work, remote: remote.path) == nil)
    }
}
