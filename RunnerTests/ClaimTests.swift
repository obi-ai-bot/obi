import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

/// Every job claims its files (#209): a plan's job about an issue claims what the issue names, a
/// client may claim them at dispatch, and the claim holds until the job's pull request is merged or
/// closed, or the user lets it go, so jobs on the same code run one after another.
@MainActor
struct ClaimTests {
    final class Made {
        var agents: [(job: Job, agent: CheckTests.Agent)] = []
    }

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
        desk.prepare = { job in
            var job = job
            job.base = job.base ?? "dev"
            return job
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
        desk.makeBrain = { [brain] _, _ in [brain] }
    }

    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: what))
    }

    func drafts() async throws -> [Desk.Draft] {
        let talk = await desk.plan("fix oby #176 and #198")
        guard case .plan(let drafts) = talk else { Issue.record("not a plan: \(talk)"); return [] }
        return drafts
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

    // MARK: Jobs on the same files run in turn

    /// #176-like and #198-like jobs both touch Engine/Review.swift: the second waits for the first,
    /// through its review, and starts once its pull request is merged.
    @Test func plansForIssuesOnTheSameFileRunOneAfterTheOther() async throws {
        let drafts = try await drafts()
        #expect(drafts.map(\.job.files) == [["Engine/Accounts.swift", "Engine/Review.swift", "RunnerTests/"], ["Engine/Review.swift", "Engine/CheckRuns.swift"]])
        let first = desk.dispatch(drafts[0])
        let second = desk.dispatch(drafts[1])
        try await until("#176 runs") { desk.job(first.id)?.status == .running }
        try await until("#198 waits") { desk.job(second.id)?.step.hasPrefix("Waiting for") == true }
        var waiting = try #require(desk.job(second.id))
        #expect(waiting.status == .queued && waiting.step == "Waiting for Fix 176 (\(first.id)): both touch Engine/Review.swift")
        #expect(made.agents.count == 1)

        // #176 publishes: its pull request is in review, and still claims the file.
        try await endDone(176)
        let published = try #require(desk.job(first.id))
        #expect(published.published == url.absoluteString && published.holdsClaim)
        try await Task.sleep(for: .milliseconds(50))
        waiting = try #require(desk.job(second.id))
        #expect(waiting.status == .queued && made.agents.count == 1)

        // Merged: #198 starts, on top of it.
        desk.followed(first.id, published: url.absoluteString, pushed: published.pushed,
                      status: PullRequestStatus(state: .merged, base: "dev", mergedAt: .now, checkedAt: .now), error: nil)
        try await until("#198 runs") { desk.job(second.id)?.status == .running }
        #expect(made.agents.count == 2 && made.agents.last?.job.issue == 198)
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

    /// Dismissing the job whose pull request holds the claim lets the next one start.
    @Test func dismissingTheClaimingJobLetsTheNextStart() async throws {
        let drafts = try await drafts()
        let first = desk.dispatch(drafts[0])
        let second = desk.dispatch(drafts[1])
        try await until("#176 runs") { desk.job(first.id)?.status == .running }
        try await endDone(176)
        // Its pull request needs a person (the review stopped): the user lets it go.
        var stuck = try #require(desk.job(first.id))
        stuck.status = .failed
        desk.replace(stuck)
        #expect(desk.job(second.id)?.status == .queued)
        try desk.dismiss(first.id)
        try await until("#198 runs") { desk.job(second.id)?.status == .running }
    }

    // MARK: The runner's API and oby-mcp

    /// `POST /v1/plans` answers drafts with their `files`; `POST /v1/jobs` may replace them, and
    /// refuses a path outside the repository.
    @Test func aClientMayClaimFilesAtDispatch() async throws {
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { [owner] client in
            let plan = try await client.execute(uri: "/v1/plans", method: .post, headers: owner, body: ByteBuffer(string: #"{"said": "fix oby #176 and #198"}"#)) { response in
                object(Data(response.body.readableBytesView))
            }
            let drafts = try #require(plan["drafts"] as? [[String: Any]])
            let jobs = drafts.compactMap { $0["job"] as? [String: Any] }
            #expect(jobs.map { $0["files"] as? [String] } == [["Engine/Accounts.swift", "Engine/Review.swift", "RunnerTests/"], ["Engine/Review.swift", "Engine/CheckRuns.swift"]])
            func dispatch(_ job: [String: Any], files: Any?) async throws -> (HTTPResponse.Status, [String: Any]) {
                var body: [String: Any] = ["id": job["id"] ?? "", "branch": job["branch"] ?? "", "account": job["account"] ?? ""]
                if let files { body["files"] = files }
                let data = try JSONSerialization.data(withJSONObject: ["job": body])
                return try await client.execute(uri: "/v1/jobs", method: .post, headers: owner, body: ByteBuffer(bytes: data)) { response in
                    (response.status, object(Data(response.body.readableBytesView)))
                }
            }
            let (refused, error) = try await dispatch(jobs[0], files: ["/etc/passwd"])
            #expect(refused == .unprocessableContent && (error["error"] as? String)?.contains("isn't a path inside the repository") == true)
            let (status, started) = try await dispatch(jobs[0], files: ["./Engine/Review.swift", "docs/"])
            #expect(status == .created && started["files"] as? [String] == ["Engine/Review.swift", "docs/"])
            // Left out, the plan's stay.
            let (_, kept) = try await dispatch(jobs[1], files: nil)
            #expect(kept["files"] as? [String] == ["Engine/Review.swift", "Engine/CheckRuns.swift"])
        }
        try await until("#198 waits for #176") { desk.jobs.first { $0.issue == 198 }?.step.hasPrefix("Waiting for Fix 176") == true }
    }
}
