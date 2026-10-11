import Foundation
import Testing
@testable import ObyEngine

@MainActor
struct IssueSyncTests {
    final class FakeGH {
        var calls: [[String]] = []
        var notes: [String] = []
        var labels = ["status:needs-test", "feature"]
        var body = "## Build\n- [ ] First slice\n- [ ] Second slice\n\n## Test it when it's done\n- [ ] Test on a Mac"
        var prBody = "- [x] First slice"
        var column = "Todo"
        var openPRs: [[String: Any]] = []
        var scopeFailure = false
        var laterPage = false
        var missingItem = false
        var extraIssues: [[String: Any]] = []
        var extraItems: [[String: Any]] = []
        var repositoryFailure: String?
        var projectTitle = Lead.boardTitle
        let issueURL = "https://github.com/deskree-inc/oby/issues/116"

        func encode(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        var row: [String: Any] { ["number": 116, "title": "Issues always current", "body": body, "labels": labels.map { ["name": $0] }, "url": issueURL, "state": "OPEN"] }
        func run(_ args: [String]) async throws -> String {
            calls.append(args)
            let command = Array(args.prefix(2))
            if args.first == "issue", ["edit", "comment"].contains(args[1]), let repositoryFailure { throw Shell.Failure(message: repositoryFailure) }
            if args.first == "project", scopeFailure { throw Shell.Failure(message: "missing required scope read:project") }
            switch command {
            case ["issue", "view"]: return try encode(row)
            case ["issue", "list"]: return try encode([row] + extraIssues)
            case ["pr", "list"]: return try encode(openPRs)
            case ["pr", "view"]: return try encode(["body": prBody])
            case ["issue", "comment"]:
                let file = args[args.firstIndex(of: "--body-file")! + 1]
                notes.append(try String(contentsOfFile: file, encoding: .utf8))
                return issueURL + "#issuecomment-\(notes.count)"
            case ["issue", "edit"]:
                for index in args.indices {
                    if args[index] == "--remove-label" { labels.removeAll { $0 == args[index + 1] } }
                    if args[index] == "--add-label" { labels.append(args[index + 1]) }
                    if args[index] == "--body-file" { body = try String(contentsOfFile: args[index + 1], encoding: .utf8) }
                }
                return ""
            case ["project", "view"]: return try encode(["id": "PVT_20"])
            case ["api", "user"]: return "well-prado"
            case ["project", "list"]: return try encode(["projects": [["title": projectTitle, "number": 20, "id": "PVT_20"]]])
            case ["project", "field-list"]:
                return try encode(["fields": [["id": "FIELD", "name": "Status", "options": ["Todo", "In progress", "In review", "Blocked", "Needs test"].map { ["id": $0, "name": $0] }]]])
            case ["api", "graphql"]:
                let firstPage = laterPage && !args.contains("cursor=next")
                let items: [[String: Any]] = firstPage || missingItem ? [] : [["id": "ITEM", "content": ["url": issueURL], "fieldValueByName": ["name": column]]] + extraItems
                return try encode(["data": ["node": ["items": ["nodes": items, "pageInfo": ["hasNextPage": firstPage, "endCursor": "next"]]]]])
            case ["project", "item-add"]: missingItem = false; return try encode(["id": "ITEM"])
            case ["project", "item-edit"]:
                column = args[args.firstIndex(of: "--single-select-option-id")! + 1]
                #expect(args.contains("PVT_20") && args.contains("FIELD") && args.contains("ITEM"))
                return ""
            default: throw Shell.Failure(message: "Unexpected fake gh command: \(args)")
            }
        }
        var mutations: [[String]] { calls.filter { ["comment", "edit", "item-add", "item-edit"].contains($0.dropFirst().first ?? "") } }
    }

    func fixture() throws -> (Desk, FakeGH, Job) {
        let folder = try temporaryFolder()
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "jobs.sqlite")))
        desk.vault = Vault(store: FileVault(folder: folder.appending(path: "vault")))
        desk.repos = ["deskree-inc/oby"]
        let fake = FakeGH()
        desk.issueSync.gh = fake.run
        desk.issueSync.enabled = true
        desk.issueSync.auditURL = folder.appending(path: "audit.json")
        var job = Job(id: "issue-sync", request: "Implement issue #116", agent: "codex", account: "default", repo: "deskree-inc/oby", branch: "oby/build-116", base: "dev", pr: nil, kind: .build, task: "Implement issue #116")
        job.issue = 116
        job.status = .running
        job.started = Date(timeIntervalSince1970: 1234)
        desk.issueSync.store.save(job)
        return (desk, fake, job)
    }

    func send(_ job: Job, to desk: Desk) async {
        desk.issueSync.store.save(job)
        desk.issueSync.observe(job)
        await desk.issueSync.drain()
    }

    @Test func lifecycleAndReports() async throws {
        let (desk, fake, original) = try fixture()
        await send(original, to: desk)
        #expect(fake.labels.sorted() == ["feature", "status:in-progress"])
        #expect(fake.column == "In progress")
        #expect(fake.notes.first?.contains("oby/build-116") == true)
        #expect(desk.issueJobs.first?.outgoing?.count == 4)
        #expect(fake.calls.contains { $0.contains("--add-assignee") && $0.contains("@me") })
        desk.issueSync.observe(original)
        await desk.issueSync.drain()
        #expect(fake.notes.count == 1)
        var job = desk.issueJobs.first!
        job.status = .done
        job.published = "https://github.com/deskree-inc/oby/pull/117"
        await send(job, to: desk)
        #expect(fake.labels.contains("status:in-review") && fake.column == "In review")
        #expect(fake.notes.last?.contains("/pull/117") == true)
        job = desk.issueJobs.first!
        job.question = Plan.Question(text: "Which account?", options: [])
        await send(job, to: desk)
        #expect(fake.labels.contains("status:blocked") && fake.notes.last?.contains("Which account?") == true)
        job = desk.issueJobs.first!
        job.question = nil
        job.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: .now, checkedAt: .now)
        job.summary = "Implemented the first slice."
        await send(job, to: desk)
        #expect(fake.body.contains("- [x] First slice") && fake.body.contains("- [ ] Second slice"))
        #expect(fake.labels.contains("status:in-progress"))
        #expect(fake.notes.last?.contains("Merged") == true)
        #expect(desk.issueJobs.first?.sentLines?.contains("issueChecklist") == true)
    }

    @Test func completeBuildNeedsRealMacTest() async throws {
        let (desk, fake, original) = try fixture()
        fake.prBody = "- [x] First slice\n- [x] Second slice\n- [x] Test on a Mac"
        var job = original
        job.status = .done
        job.published = "https://github.com/deskree-inc/oby/pull/117"
        job.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: .now, checkedAt: .now)
        await send(job, to: desk)
        #expect(fake.labels.contains("status:needs-test") && fake.column == "Needs test")
        #expect(fake.body.contains("- [ ] Test on a Mac"))
    }

    @Test func scanFailureAndSecretsSendNothing() async throws {
        let (desk, fake, original) = try fixture()
        desk.issueSync.scan = { _ in throw Shell.Failure(message: "scanner unavailable") }
        await send(original, to: desk)
        #expect(fake.mutations.isEmpty)
        #expect(desk.issueJobs.first?.claim?.contains("scanner unavailable") == true)
        desk.issueSync.scan = { texts in
            let findings = texts.flatMap { Publish.findings(inText: $0.text, named: $0.name) }
            if !findings.isEmpty { throw Publish.Blocked(findings: findings) }
        }
        var job = original
        job.branch = "oby/" + "ghp_" + String(repeating: "a", count: 36)
        await send(job, to: desk)
        #expect(fake.mutations.isEmpty)
        #expect(desk.issueJobs.first?.claim?.contains("possible secret") == true)
    }

    @Test func paginationAndScopeFailure() async throws {
        let (desk, fake, job) = try fixture()
        fake.laterPage = true
        fake.scopeFailure = true
        await send(job, to: desk)
        #expect(desk.issueJobs.first?.claim?.contains(IssueSync.scopeFix) == true)
        fake.scopeFailure = false
        desk.issueSync.observe(job)
        await desk.issueSync.drain()
        #expect(fake.calls.contains { $0.contains("cursor=next") })
        #expect(!fake.calls.contains { $0.prefix(2) == ["project", "item-add"] })
        #expect(fake.notes.count == 1)
    }

    @Test func conservativeLinking() throws {
        let (_, _, original) = try fixture()
        let issues: [[String: Any]] = [["number": 116, "title": "Issues always current"], ["number": 20, "title": "Watch"]]
        var job = original
        job.issue = nil
        #expect(IssueSync.inferred(job, issues: issues) == 116)
        job.task = "Part of #20"
        job.request = "Work on Watch"
        job.branch = "oby/build-abcd"
        #expect(IssueSync.inferred(job, issues: issues) == 20)
        job.task = "Part of #20\nPart of #116"
        #expect(IssueSync.inferred(job, issues: issues) == nil)
        job.task = "Do some work"
        #expect(IssueSync.inferred(job, issues: issues) == nil)
        job.task = "Build something like issue #20"
        #expect(IssueSync.inferred(job, issues: issues) == nil)
        job.title = "Issues always current"
        #expect(IssueSync.inferred(job, issues: issues) == 116)
    }

    @Test func dailyAuditRepairsStaleLabelsAndBoardOnce() async throws {
        let (desk, fake, original) = try fixture()
        var job = original
        job.status = .done
        desk.issueSync.store.save(job)
        fake.labels = ["status:in-progress", "feature"]
        fake.column = "In progress"
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        await desk.issueSync.audit(now: day)
        #expect(fake.labels == ["feature"] && fake.column == "In progress")
        #expect(desk.inbox.count == 1 && desk.inbox.first?.text == "Issue audit: fixed drift on 1 issue(s).")
        #expect(desk.issueJobs.first(where: { $0.id == original.id })?.outgoing?.count == 1)
        let count = fake.calls.count
        await desk.issueSync.audit(now: day)
        #expect(fake.calls.count == count)
    }

    @Test func dailyAuditFindsOpenPRWithoutAJob() async throws {
        let (desk, fake, original) = try fixture()
        var job = original
        job.status = .done
        job.issue = nil
        job.branch = "unrelated"
        job.request = "Unrelated work"
        job.task = "Unrelated work"
        desk.issueSync.store.save(job)
        fake.openPRs = [["url": "https://github.com/deskree-inc/oby/pull/117", "headRefName": "manual-branch", "closingIssuesReferences": [["number": 116, "url": fake.issueURL]]]]
        await desk.issueSync.audit()
        #expect(fake.labels.contains("status:in-review") && fake.column == "In review")
        #expect(fake.notes.first?.contains("/pull/117") == true)
        #expect(desk.issueJobs.count == 1)
        #expect(desk.inbox.first?.job == "" && desk.inbox.first?.outgoing?.count == 3)
    }

    @Test func unknownChecklistCoverageIsNotGuessed() {
        #expect(IssueSync.checklist("- [ ] first\n- [ ] second", covered: "Finished first\n- [x] other") == "- [ ] first\n- [ ] second")
        #expect(IssueSync.checklist("## Build\n- [ ] **Issue sync.** A long description", covered: "- [x] **Issue sync.**") == "## Build\n- [x] **Issue sync.** A long description")
        #expect(IssueSync.checklist("- [ ] **Same.** One\n- [ ] **Same.** Two", covered: "- [x] **Same.**") == "- [ ] **Same.** One\n- [ ] **Same.** Two")
    }

    @Test func reviewCapAndOlderSliceDoNotHideRunningWork() async throws {
        let (desk, fake, original) = try fixture()
        var job = original
        job.status = .done
        job.published = "https://github.com/deskree-inc/oby/pull/117"
        job.review = Review(verdict: .changesRequested, job: "review-2", agent: "claude", account: "Personal", round: Review.maxRounds)
        await send(job, to: desk)
        #expect(fake.labels.contains("status:blocked"))
        #expect(fake.notes.last?.contains(Review.stopLine) == true)
        var other = original
        other.id = "another-slice"
        desk.issueSync.store.save(other)
        job = desk.issueJobs.first { $0.id == original.id }!
        job.review = nil
        job.published = nil
        await send(job, to: desk)
        #expect(fake.labels.contains("status:in-progress") && fake.column == "In progress")
    }

    @Test func runnerLinksUnlinkedJobWithoutAddingProjectItem() async throws {
        let (desk, fake, original) = try fixture()
        var job = original
        job.issue = nil
        fake.missingItem = true
        await send(job, to: desk)
        #expect(desk.issueJobs.first?.issue == 116)
        #expect(!fake.calls.contains { $0.prefix(2) == ["project", "item-add"] })
        #expect(fake.column == "Todo")
    }

    @Test func leadScopeFailureIsNotMissingProject() async throws {
        let error = await #expect(throws: Shell.Failure.self) {
            try await Board.read(repos: ["deskree-inc/oby"], gh: { _ in throw Shell.Failure(message: "missing scope read:project") })
        }
        #expect(error?.localizedDescription == IssueSync.scopeFix)
    }

    @Test(arguments: ["Done", "Shipped", "Closed"])
    func finishedColumnsAreNeverReopened(_ column: String) async throws {
        let (desk, fake, job) = try fixture()
        fake.column = column
        await send(job, to: desk)
        #expect(fake.column == column)
        #expect(!fake.calls.contains { $0.prefix(2) == ["project", "item-edit"] })
    }

    @Test func auditIsLimitedToExistingNamedRoadmapItems() async throws {
        let (desk, fake, original) = try fixture()
        var job = original
        job.status = .done
        desk.issueSync.store.save(job)
        desk.repos += ["other-owner/unrelated", "deskree-inc/another"]
        fake.extraIssues = [["number": 999, "title": "Unrelated", "url": "https://github.com/deskree-inc/oby/issues/999", "labels": [["name": "status:in-progress"]]]]
        await desk.issueSync.audit()
        #expect(!fake.calls.contains { $0.contains("other-owner/unrelated") || $0.contains("deskree-inc/another") || $0.contains("999") || $0.prefix(2) == ["project", "item-add"] })
        fake.calls = []
        fake.projectTitle = "An unrelated project numbered 20"
        await desk.issueSync.audit(now: Date.now.addingTimeInterval(86400))
        #expect(fake.mutations.isEmpty)
        #expect(!fake.calls.contains { $0.prefix(2) == ["project", "field-list"] || $0.prefix(2) == ["issue", "list"] })
    }

    @Test func idleSlicePreservesMergedSliceHandoff() async throws {
        let (desk, fake, original) = try fixture()
        fake.body = "## Build\n- [x] First slice\n## Test it when it's done\n- [ ] Test on a Mac"
        fake.column = "Needs test"
        var merged = original
        merged.id = "merged-slice"
        merged.status = .done
        merged.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: .now, checkedAt: .now)
        desk.issueSync.store.save(merged)
        var idle = original
        idle.status = .done
        await send(idle, to: desk)
        #expect(fake.labels.contains("status:needs-test") && fake.column == "Needs test")
    }

    @Test func auditKeepsRemainingSlicesAndQuietDaysQuiet() async throws {
        let (desk, fake, original) = try fixture()
        var merged = original
        merged.status = .done
        merged.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: .now, checkedAt: .now)
        desk.issueSync.store.save(merged)
        fake.labels = ["feature", "status:in-progress"]
        fake.column = "In progress"
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        await desk.issueSync.audit(now: day)
        #expect(fake.labels.contains("status:in-progress") && desk.inbox.isEmpty && fake.mutations.isEmpty)
        let count = fake.calls.count
        await desk.issueSync.audit(now: day)
        #expect(fake.calls.count == count)
        await desk.issueSync.audit(now: day.addingTimeInterval(86400))
        #expect(desk.inbox.isEmpty && desk.issueJobs.count == 1 && fake.mutations.isEmpty)
    }

    @Test func auditReadsProjectOnceAndDoesNotRepeatOrphanComments() async throws {
        let (desk, fake, original) = try fixture()
        var idle = original
        idle.status = .done
        idle.issue = nil
        idle.branch = "unrelated"
        idle.task = "Unrelated"
        desk.issueSync.store.save(idle)
        fake.laterPage = true
        fake.extraItems = [["id": "FINISHED", "content": ["url": "https://github.com/deskree-inc/oby/issues/20"], "fieldValueByName": ["name": "Shipped"]]]
        fake.extraIssues = [["number": 20, "title": "Finished feature", "body": "", "labels": [["name": "status:needs-test"]]]]
        fake.openPRs = [["url": "https://github.com/deskree-inc/oby/pull/117", "headRefName": "manual-branch", "closingIssuesReferences": [["number": 116, "url": fake.issueURL]]]]
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        await desk.issueSync.audit(now: day)
        #expect(fake.calls.filter { $0.prefix(2) == ["project", "field-list"] }.count == 1)
        #expect(fake.calls.filter { $0.prefix(2) == ["api", "graphql"] }.count == 2)
        await desk.issueSync.audit(now: day.addingTimeInterval(86400))
        #expect(fake.notes.count == 1 && desk.inbox.count == 1 && desk.issueJobs.count == 1)
    }

    @Test func repositoryPermissionErrorsKeepTheirActualCause() async throws {
        let (desk, fake, job) = try fixture()
        let failure = "Resource not accessible: missing repository scope"
        fake.repositoryFailure = failure
        await send(job, to: desk)
        #expect(desk.issueJobs.first?.claim == "Issue sync: \(failure)")
        #expect(IssueSync.projectError(failure) == failure)
        #expect(IssueSync.projectError("missing required scopes [read:project]") == IssueSync.scopeFix)
    }
}
