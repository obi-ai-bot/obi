import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

/// Every job claims its files (#209): a plan's job about an issue claims what the issue names, a
/// client may claim them at dispatch, and the claim holds until the job's pull request is merged or
/// closed, or the user lets it go. A claim holds no job back (#237, RunnerTests/ParallelTests.swift):
/// a job that waited for a slot is brought up to date with dev before it starts.
@MainActor
struct ClaimTests {
    final class Made {
        var agents: [(job: Job, agent: CheckTests.Agent)] = []
        /// dev on GitHub, and what fetching it throws instead.
        var dev = ClaimTests.devBefore
        var fetchError: Error?
        var fetched: [String] = []
        /// Worktrees moved to a newer dev: the job, from, to. `moves` says whether they can.
        var moved: [(id: String, from: String, to: String)] = []
        var moves = true
    }

    nonisolated static let devBefore = String(repeating: "a", count: 40)
    nonisolated static let devMerged = String(repeating: "c", count: 40)

    let folder: URL
    let desk: Desk
    let brain: ConversationTests.FakeBrain
    let made = Made()
    let url = URL(string: "https://github.com/deskree-inc/oby/pull/200")!
    let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]

    /// A plan for #176 and #198 in deskree-inc/oby.
    static let twoIssues = #"{"action":"dispatch","reply":"Oby will fix #176 and #198.","question":null,"jobs":[],"dispatches":["#
        + [176, 198].map { #"{"agent":"auto","account":"auto","repo":"deskree-inc/oby","base_branch":null,"pr":null,"issue":\#($0),"epic":null,"kind":"fix","title":"Fix \#($0)","task":"Fix oby #\#($0)","inputs":[],"rounds":1,"check":null,"complexity":"routine"}"# }
            .joined(separator: ",") + "]}"

    /// What the issues say: both touch Engine/Review.swift.
    static let bodies = [
        176: "## How\n\nRoute reviews by weekly pace.\n\nFiles: `Engine/Accounts.swift`, `Engine/Review.swift`, `RunnerTests/`.",
        198: "## How\n\nReviews become check runs.\n\n**Files:** `Engine/Review.swift`, `Engine/CheckRuns.swift`.",
    ]

    init() throws {
        folder = try temporaryFolder()
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max · well@example.com", for: "default")
        desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        // As a worktree on dev: its work publishes.
        desk.prepare = { [made] job in
            var job = job
            job.base = job.base ?? "dev"
            job.startCommit = made.dev
            return job
        }
        desk.fetchBase = { [made] job, _ in
            made.fetched.append(job.id)
            if let error = made.fetchError { throw error }
            return made.dev
        }
        desk.moveWorktree = { [made] id, from, to in
            guard made.moves else { return false }
            made.moved.append((id, from, to))
            return true
        }
        desk.makeAgent = { [made] job, _, _ in
            let agent = CheckTests.Agent()
            made.agents.append((job, agent))
            return agent
        }
        desk.countCommits = { _, _ in 1 }
        desk.publishOnItsOwn = { [url] job, _, hooks in
            hooks.sent(Outgoing(action: .push, repo: job.repo, id: CheckTests.head, branch: job.branch))
            return url
        }
        desk.issueFiles = { _, issue in Claims.files(title: "Issue \(issue)", body: Self.bodies[issue] ?? "") }
        brain = ConversationTests.FakeBrain([Self.twoIssues])
        desk.makeBrain = { [brain] (_: String?, _: String?, _: Vault) in [brain] }
    }

    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: what))
    }

    /// A plan for one issue in deskree-inc/oby.
    static func oneIssue(_ issue: Int) -> String {
        #"{"action":"dispatch","reply":"","question":null,"jobs":[],"dispatches":[{"agent":"auto","account":"auto","repo":"deskree-inc/oby","base_branch":null,"pr":null,"issue":\#(issue),"epic":null,"kind":"fix","title":"Fix \#(issue)","task":"Fix oby #\#(issue)","inputs":[],"rounds":1,"check":null,"complexity":"routine"}]}"#
    }

    /// The jobs the words start as the plan is made (#269: nothing to dispatch), by issue, #176 first.
    func started(_ words: String = "fix oby #176 and #198") async throws -> [Job] {
        let talk = await desk.plan(words)
        guard case .reply = talk else { Issue.record("not a reply: \(talk)"); return [] }
        return desk.jobs.filter { $0.request == words }.sorted { ($0.issue ?? 0) < ($1.issue ?? 0) }
    }

    /// The agent of the job on `issue` ends its round done: it publishes, its pull request opens.
    func endDone(_ issue: Int) async throws {
        let agent = try #require(made.agents.first { $0.job.issue == issue }?.agent)
        agent.onEvent(.session("s\(issue)"))
        agent.onEvent(.turnEnded(summary: "fix(engine): #\(issue)", failed: false))
        agent.onEvent(.finished(summary: "fix(engine): #\(issue)", failed: false))
        try await until("#\(issue) ends") { desk.jobs.first { $0.issue == issue }?.status == .done }
    }

    // MARK: What an issue claims

    @Test func anIssuesFilesLineIsWhatItClaims() {
        #expect(Claims.files(title: "", body: Self.bodies[176]!) == ["Engine/Accounts.swift", "Engine/Review.swift", "RunnerTests/"])
        #expect(Claims.files(title: "", body: Self.bodies[198]!) == ["Engine/Review.swift", "Engine/CheckRuns.swift"])
        // #209's own line, with folders and a closing period.
        let line = "Files: `Engine/Brain.swift`, `Engine/Jobs.swift`, `Runner/API.swift`, `MCP/`, `docs/mcp.md`."
        #expect(Claims.files(title: "", body: "Text.\n\n" + line) == ["Engine/Brain.swift", "Engine/Jobs.swift", "Runner/API.swift", "MCP/", "docs/mcp.md"])
        // Without backticks, commas separate them.
        #expect(Claims.files(title: "", body: "Files: Engine/Desk.swift, Mac/ and docs/runner-api.md") == ["Engine/Desk.swift", "Mac/", "docs/runner-api.md"])
        // No Files: line: the paths the title and text name, in backticks or with a folder.
        let text = "Since `Engine/Checks.swift` and/or Engine/Failures.swift changed, see https://github.com/deskree-inc/oby/issues/159 and `Package.swift`. Not `swift test`, `mergeError`, `POST /v1/plans` or e.g. job.files."
        #expect(Claims.files(title: "Runner/API.swift answers 500", body: text) == ["Engine/Checks.swift", "Package.swift", "Runner/API.swift", "Engine/Failures.swift"])
        // A failure issue's "Files: not named" falls back to what the text names; nothing named, nothing claimed.
        #expect(Claims.files(title: "", body: "Files: not named\n\nIn `Engine/Publish.swift`.") == ["Engine/Publish.swift"])
        #expect(Claims.files(title: "Make it faster", body: "It's slow on the iPhone and/or the Mac.") == nil)
        #expect(Claims.files(issue: ["title": "x", "body": "Files: `Engine/`"]) == ["Engine/"])
    }

    /// A job nobody gave files claims the ones its issue names as its worktree gets ready; one with
    /// files (the Lead's, a client's) keeps them.
    @Test func aJobClaimsItsIssuesFilesWhenItsWorktreeIsReady() throws {
        let worktree = folder.appending(path: "work")
        var job = Job(id: "j1", request: "fix oby #198", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-198", base: "dev", pr: nil, kind: .fix, task: "Fix oby #198")
        job.issue = 198
        let issue = try JSONSerialization.data(withJSONObject: ["title": "Check runs", "body": Self.bodies[198]!])
        let vault = Vault(store: FileVault(folder: folder.appending(path: "vault")))
        #expect(try Workspace.inputs(job, pullRequest: nil, issue: issue, in: worktree, vault: vault).files
                == ["Engine/Review.swift", "Engine/CheckRuns.swift"])
        job.files = ["Mac/"]
        #expect(try Workspace.inputs(job, pullRequest: nil, issue: issue, in: worktree, vault: vault).files == ["Mac/"])
        job.files = []
        #expect(try Workspace.inputs(job, pullRequest: nil, issue: issue, in: worktree, vault: vault).files == [])
    }

    // MARK: A job that waited for a slot catches up

    /// With one slot, #198 waits for #176 to end, then starts on dev as GitHub has it now: its
    /// worktree was set up on dev before #176 ended, so it moves first and doesn't edit stale code.
    @Test func aJobThatWaitedForASlotStartsOnTheLatestDev() async throws {
        desk.maxRunning = 1
        let planned = try await started()
        #expect(planned.map(\.files) == [["Engine/Accounts.swift", "Engine/Review.swift", "RunnerTests/"], ["Engine/Review.swift", "Engine/CheckRuns.swift"]])
        try #require(planned.count == 2)
        let (first, second) = (planned[0], planned[1])
        try await until("#176 runs") { desk.job(first.id)?.status == .running }
        try await until("#198 waits") { desk.job(second.id)?.step.hasPrefix("Waiting for") == true }
        let waiting = try #require(desk.job(second.id))
        #expect(waiting.status == .queued && waiting.step == "Waiting for a free slot: 1 of 1 jobs running")
        #expect(waiting.waiting == .slot)
        #expect(made.agents.count == 1 && made.fetched.isEmpty && made.moved.isEmpty)

        // #176 publishes and ends: its slot is free while its pull request is in review.
        made.dev = Self.devMerged
        try await endDone(176)
        #expect(desk.job(first.id)?.holdsClaim == true)
        try await until("#198 runs") { desk.job(second.id)?.status == .running }
        #expect(made.agents.count == 2 && made.agents.last?.job.issue == 198 && desk.job(second.id)?.waiting == nil)
        #expect(made.fetched == [second.id] && made.moved.map { "\($0.id) \($0.from) \($0.to)" } == ["\(second.id) \(Self.devBefore) \(Self.devMerged)"])
        #expect(desk.job(second.id)?.startCommit == Self.devMerged && made.agents.last?.job.startCommit == Self.devMerged)
    }

    /// #176-like and #198-like jobs both touch Engine/Review.swift: they run side by side (#237).
    /// #198's agent is told about #176's branch, and #176's claim holds through its review until
    /// its pull request is merged.
    @Test func plansForIssuesOnTheSameFileRunSideBySide() async throws {
        let planned = try await started()
        try #require(planned.count == 2)
        let (first, second) = (planned[0], planned[1])
        try await until("#176 and #198 run") { desk.job(first.id)?.status == .running && desk.job(second.id)?.status == .running }
        let running = try #require(desk.job(second.id))
        #expect(running.status == .running && running.step == "Starting Claude Code")
        #expect(made.agents.count == 2)
        let prompt = try #require(made.agents.first { $0.job.issue == 198 }?.agent.prompt)
        #expect(prompt.contains("Fix 176 (job \(first.id)) on the branch oby/fix-176: both touch Engine/Review.swift"))

        // #176 publishes: its pull request is in review, and still claims the file.
        try await endDone(176)
        let published = try #require(desk.job(first.id))
        #expect(published.published == url.absoluteString && published.holdsClaim)
        // Publishing may now start a review on the author's account (#408). Count the
        // author jobs whose claims this test covers, independently of that reviewer.
        #expect(desk.job(second.id)?.status == .running && made.agents.filter { $0.job.kind == .fix }.count == 2)

        // Merged: its claim ends.
        desk.followed(first.id, published: url.absoluteString, pushed: published.pushed,
                      status: PullRequestStatus(state: .merged, base: "dev", mergedAt: .now, checkedAt: .now), error: nil)
        #expect(desk.job(first.id)?.holdsClaim == false)
    }

    /// Dismissing the job whose pull request holds the claim lets go of it: a job that starts after
    /// isn't told about it any more.
    @Test func dismissingTheClaimingJobLetsGoOfItsClaim() async throws {
        brain.plans = [Self.oneIssue(176), Self.oneIssue(198)]
        let first = try #require(try await started("fix oby #176").first)
        try await until("#176 runs") { desk.job(first.id)?.status == .running }
        try await endDone(176)
        // Its pull request needs a person (the review stopped): the user lets it go.
        var stuck = try #require(desk.job(first.id))
        stuck.status = .failed
        desk.replace(stuck)
        #expect(desk.job(first.id)?.holdsClaim == true)
        try desk.dismiss(first.id)
        #expect(desk.job(first.id)?.holdsClaim == false)
        let second = try #require(try await started("fix oby #198").first)
        try await until("#198 runs") { desk.job(second.id)?.status == .running }
        #expect(made.agents.last?.agent.prompt.contains("Other jobs are changing the same files") == false)
    }

    /// A waiting job that can't be brought up to date fails, saying why, rather than start on stale code.
    @Test func aWaitingJobThatCantCatchUpFails() async throws {
        desk.maxRunning = 1
        let planned = try await started()
        try #require(planned.count == 2)
        let (first, second) = (planned[0], planned[1])
        try await until("#198 waits") { desk.job(second.id)?.step.hasPrefix("Waiting for") == true }
        made.fetchError = Shell.Failure(message: "github.com unreachable")
        desk.stop(first.id)
        try await until("#198 fails") { desk.job(second.id)?.status == .failed }
        #expect(desk.job(second.id)?.summary.hasPrefix("Couldn't bring oby/fix-198 up to date with dev: github.com unreachable") == true)
        #expect(made.agents.count == 1)
    }

    /// A waiting job moved while it's brought up to date starts where it was moved, on the commit it
    /// caught up to: the job catch-up started with doesn't undo the move (#118).
    @Test func aJobMovedWhileItCatchesUpStartsWhereItWasMoved() async throws {
        desk.maxRunning = 1
        let gate = MoveJobTests.Gate()
        desk.fetchBase = { [made] _, _ in
            await gate.wait()
            return made.dev
        }
        let planned = try await started()
        try #require(planned.count == 2)
        let (first, second) = (planned[0], planned[1])
        try await until("#198 waits") { desk.job(second.id)?.step.hasPrefix("Waiting for") == true }
        // An account to move it to, signed in after both were routed.
        let codex = try desk.accounts.add(agent: "codex", name: "Deskree", payer: "Deskree")
        desk.accounts.setLabel("Plus · well@example.com", for: codex.id)
        made.dev = Self.devMerged
        desk.stop(first.id)
        try await until("#198 catches up") { desk.job(second.id)?.step.hasPrefix("Bringing") == true }
        let moved = try desk.move(second.id, to: MoveTarget(agent: "codex"))
        #expect(moved.status == .queued && moved.account == codex.id)
        gate.release()
        try await until("#198 runs") { desk.job(second.id)?.status == .running }
        let started = try #require(made.agents.last?.job)
        #expect(made.agents.count == 2 && started.id == second.id)
        #expect(started.agent == "codex" && started.account == codex.id && started.moves?.count == 1 && started.startCommit == Self.devMerged)
    }

    /// Bringing a job up to date moves only a worktree with no work of its own, and never a pull request's.
    @Test func catchingUpLeavesWorkAndPullRequestsAlone() async throws {
        var job = Job(id: "j1", request: "fix", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-1", base: "dev", pr: nil, kind: .fix, task: "Fix")
        job.startCommit = Self.devBefore
        made.dev = Self.devMerged
        #expect(try await desk.caughtUp(job).startCommit == Self.devMerged)
        // Its head moved on (or it has changes): it stays where it is.
        made.moves = false
        #expect(try await desk.caughtUp(job).startCommit == Self.devBefore)
        // dev hasn't moved: nothing to do.
        made.moves = true
        made.dev = Self.devBefore
        #expect(try await desk.caughtUp(job).startCommit == Self.devBefore && made.moved.count == 1)
        // A job on a pull request works on its branch: nothing is fetched.
        job.pr = 33
        let fetched = made.fetched.count
        #expect(try await desk.caughtUp(job) == job && made.fetched.count == fetched)
    }

    /// The claim lasts until the job is merged, closed or let go, not just while its agent runs.
    @Test func aClaimHoldsUntilMergedClosedOrLetGo() {
        var job = Job(id: "j1", request: "fix", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/fix-1", base: "dev", pr: nil, kind: .fix, task: "Fix")
        job.status = .running
        #expect(job.holdsClaim)
        job.status = .done
        job.commits = 1
        // Done with commits to publish (its publish failed): Publish by hand opens its pull request.
        #expect(job.canPublish && job.holdsClaim)
        job.published = url.absoluteString
        #expect(job.holdsClaim)
        job.pullRequest = PullRequestStatus(state: .open, base: "dev", checkedAt: .now)
        #expect(job.holdsClaim)
        // Failed in a later round, its pull request still open: still claimed, until dismissed.
        job.status = .failed
        #expect(job.holdsClaim)
        job.dismissed = .now
        #expect(!job.holdsClaim)
        job.dismissed = nil
        job.status = .stopped
        #expect(!job.holdsClaim)
        job.status = .done
        job.pullRequest = PullRequestStatus(state: .closed, base: "dev", checkedAt: .now)
        #expect(!job.holdsClaim)
        // Ended with nothing to publish.
        var nothing = job
        nothing.published = nil
        nothing.pullRequest = nil
        nothing.commits = 0
        #expect(!nothing.holdsClaim)
    }

    // MARK: The runner's API and oby-mcp

    /// A client's list is checked whole: a 31st path is refused, never dropped and left unclaimed.
    /// An issue's are all kept.
    @Test func everyPathIsCheckedAndKept() throws {
        let paths = (1...31).map { "Engine/File\($0).swift" }
        #expect(throws: Shell.Failure.self) { try Claims.validated(paths) }
        #expect((try? Claims.validated(paths)) == nil)
        #expect(try Claims.validated(Array(paths.prefix(30))) == Array(paths.prefix(30)))
        // The same path twice counts once.
        #expect(try Claims.validated(Array(paths.prefix(30)) + ["./Engine/File1.swift"]) == Array(paths.prefix(30)))
        // A bad path anywhere is refused, the 31st too.
        #expect((try? Claims.validated(Array(paths.prefix(29)) + ["Mac/", "/etc/passwd"])) == nil)
        #expect(Claims.files(title: "", body: "Files: " + paths.map { "`\($0)`" }.joined(separator: ", ")) == paths)
    }

    /// `POST /v1/plans` starts the jobs with their issues' `files` (#269); a whole job sent to
    /// `POST /v1/jobs` may claim its own, or its issue's when it names none, and a path outside
    /// the repository is refused.
    @Test func aClientMayClaimFilesAtDispatch() async throws {
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { [owner] client in
            let plan = try await client.execute(uri: "/v1/plans", method: .post, headers: owner, body: ByteBuffer(string: #"{"said": "fix oby #176 and #198"}"#)) { response in
                object(Data(response.body.readableBytesView))
            }
            #expect(plan["kind"] as? String == "reply" && (plan["drafts"] as? [Any])?.isEmpty == true)
            let jobs = try #require(plan["jobs"] as? [[String: Any]])
            #expect(jobs.map { $0["files"] as? [String] } == [["Engine/Accounts.swift", "Engine/Review.swift", "RunnerTests/"], ["Engine/Review.swift", "Engine/CheckRuns.swift"]])
            func dispatch(_ issue: Int, files: Any?) async throws -> (HTTPResponse.Status, [String: Any]) {
                var body: [String: Any] = ["repo": "deskree-inc/oby", "kind": "fix", "task": "Fix #\(issue)", "issue": issue]
                if let files { body["files"] = files }
                let data = try JSONSerialization.data(withJSONObject: ["job": body])
                return try await client.execute(uri: "/v1/jobs", method: .post, headers: owner, body: ByteBuffer(bytes: data)) { response in
                    (response.status, object(Data(response.body.readableBytesView)))
                }
            }
            let (refused, error) = try await dispatch(176, files: ["/etc/passwd"])
            #expect(refused == .unprocessableContent && (error["error"] as? String)?.contains("isn't a path inside the repository") == true)
            let (status, started) = try await dispatch(176, files: ["./Engine/Review.swift", "docs/"])
            #expect(status == .created && started["files"] as? [String] == ["Engine/Review.swift", "docs/"])
            // Left out, the issue's.
            let (_, kept) = try await dispatch(198, files: nil)
            #expect(kept["files"] as? [String] == ["Engine/Review.swift", "Engine/CheckRuns.swift"])
        }
        try await until("all four run side by side") { desk.jobs.filter { $0.status == .running }.count == 4 }
    }
}
