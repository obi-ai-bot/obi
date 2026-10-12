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
        var options = ["Todo", "In progress", "In review", "Blocked", "Needs test"]
        /// Each option's id by its name; its name when it has none here.
        var ids: [String: String] = [:]
        /// `updateProjectV2Field` gives every option a new id, as it would without theirs.
        var renumbers = false
        var fieldUpdates: [[[String: Any]]] = []
        func id(_ name: String) -> String { ids[name] ?? name }
        var number = 116
        var issueURL: String { "https://github.com/deskree-inc/oby/issues/\(number)" }

        func encode(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        var row: [String: Any] { ["number": number, "title": "Issues always current", "body": body, "labels": labels.map { ["name": $0] }, "url": issueURL, "state": "OPEN"] }
        func run(_ args: [String]) async throws -> String {
            calls.append(args)
            let command = Array(args.prefix(2))
            if args.first == "issue", ["edit", "comment"].contains(args[1]), let repositoryFailure { throw Shell.Failure(message: repositoryFailure) }
            if args.first == "project", scopeFailure { throw Shell.Failure(message: "missing required scope read:project") }
            switch command {
            case ["issue", "view"] where args.last == "comments": return try encode(["comments": notes.map { ["body": $0] }])
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
                return try encode(["fields": [["id": "FIELD", "name": "Status", "options": options.map { ["id": id($0), "name": $0] }]]])
            case ["api", "graphql"] where args.contains("--input"):
                let file = args[args.firstIndex(of: "--input")! + 1]
                let request = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: file))) as? [String: Any])
                #expect((request["query"] as? String)?.contains("updateProjectV2Field") == true)
                let input = try #require((request["variables"] as? [String: Any])?["input"] as? [String: Any])
                #expect(input["fieldId"] as? String == "FIELD")
                let sent = try #require(input["singleSelectOptions"] as? [[String: Any]])
                fieldUpdates.append(sent)
                options = sent.compactMap { $0["name"] as? String }
                for option in sent {
                    let name = option["name"] as? String ?? ""
                    ids[name] = renumbers ? "X-\(name)" : option["id"] as? String ?? name
                }
                return try encode(["data": ["updateProjectV2Field": ["projectV2Field": ["id": "FIELD"]]]])
            case ["api", "graphql"] where args.contains { $0.contains("ProjectV2SingleSelectField{options") }:
                #expect(args.contains("id=FIELD"))
                return try encode(["data": ["node": ["options": options.map { ["id": id($0), "name": $0, "color": $0 == "Done" ? "GREEN" : "GRAY", "description": "\($0) cards"] }]]])
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

    /// Labels and the board follow the job; no comment and no assignee, which would email the owner (#162).
    @Test func lifecycleAndReports() async throws {
        let (desk, fake, original) = try fixture()
        await send(original, to: desk)
        #expect(fake.labels.sorted() == ["feature", "status:in-progress"])
        #expect(fake.column == "In progress")
        #expect(IssueSync.claimant(fake.body) == original.id && fake.body.hasPrefix("## Build\n- [ ] First slice"))
        #expect(desk.issueJobs.first?.outgoing?.map(\.action.rawValue) == ["issueClaim", "issueLabels", "projectStatus"])
        #expect(desk.issueJobs.first?.claim == "Claimed: labeled status:in-progress.")
        let started = fake.calls.count
        desk.issueSync.observe(original)
        await desk.issueSync.drain()
        #expect(fake.calls.count == started)
        var job = desk.issueJobs.first!
        job.status = .done
        job.published = "https://github.com/deskree-inc/oby/pull/117"
        await send(job, to: desk)
        #expect(fake.labels.contains("status:in-review") && fake.column == "In review")
        job = desk.issueJobs.first!
        job.question = Plan.Question(text: "Which account?", options: [])
        await send(job, to: desk)
        #expect(fake.labels.contains("status:blocked") && fake.column == "Blocked")
        job = desk.issueJobs.first!
        job.question = nil
        job.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: .now, checkedAt: .now)
        job.summary = "Implemented the first slice."
        await send(job, to: desk)
        #expect(fake.body.contains("- [x] First slice") && fake.body.contains("- [ ] Second slice"))
        #expect(fake.labels.contains("status:in-progress"))
        #expect(desk.issueJobs.first?.sentLines?.contains("issueChecklist") == true)
        #expect(fake.notes.isEmpty && !fake.calls.contains { $0.prefix(2) == ["issue", "comment"] })
        #expect(!fake.calls.contains { $0.contains("--add-assignee") || $0.contains("--assignee") })
    }

    @Test func claimLineIsHiddenOneAndStable() {
        let body = "## Build\r\n- [ ] First\r\n<!-- oby-claim: job old-job -->\r\n"
        let claimed = IssueSync.claimed(body, by: "new-job")
        #expect(claimed == "## Build\r\n- [ ] First\n\n<!-- oby-claim: job new-job -->")
        #expect(IssueSync.claimant(claimed) == "new-job" && IssueSync.claimant(body) == "old-job")
        #expect(IssueSync.claimed(claimed, by: "new-job") == claimed)
        #expect(IssueSync.claimed("", by: "a") == "<!-- oby-claim: job a -->")
        #expect(IssueSync.claimant("Oby is working on branch `oby/fix-1` (job a).") == nil)
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
        // The claim line goes out with the issue's body, which is scanned whole.
        var job = original
        job.branch = "oby/fix-116"
        fake.body += "\nToken: ghp_" + String(repeating: "a", count: 36)
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
        desk.issueSync.now = { Date.now.addingTimeInterval(61) }
        desk.issueSync.observe(job)
        await desk.issueSync.drain()
        #expect(fake.calls.contains { $0.contains("cursor=next") })
        #expect(!fake.calls.contains { $0.prefix(2) == ["project", "item-add"] })
        #expect(fake.notes.isEmpty)
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
        fake.body = IssueSync.claimed(fake.body, by: original.id)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        await desk.issueSync.audit(now: day)
        #expect(fake.labels == ["feature"] && fake.column == "In progress")
        #expect(fake.notes.isEmpty && !fake.calls.contains { $0.prefix(2) == ["issue", "comment"] })
        #expect(desk.inbox.count == 1 && desk.inbox.first?.text == "Issue audit: fixed drift on 1 issue(s).")
        // It fixed the drift by itself and nothing failed: the report arrives done, with nothing to decide (#215).
        #expect(desk.inbox.first?.done == day && desk.inbox.first?.options == [])
        #expect(desk.inbox.filter(\.isOpen).isEmpty)
        #expect(desk.issueJobs.first(where: { $0.id == original.id })?.outgoing?.count == 1)
        let count = fake.calls.count
        await desk.issueSync.audit(now: day)
        #expect(fake.calls.count == count)
    }

    @Test func dailyAuditLeavesUnownedIssuesAndManualPRsAlone() async throws {
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
        #expect(fake.labels == ["status:needs-test", "feature"] && fake.column == "Todo")
        #expect(fake.notes.isEmpty && fake.mutations.isEmpty)
        #expect(desk.issueJobs.count == 1)
        #expect(desk.inbox.isEmpty)
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
        #expect(fake.labels.contains("status:blocked") && fake.notes.isEmpty)
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

    @Test func auditReadsProjectOnceAndDoesNotCommentOnManualPRs() async throws {
        let (desk, fake, original) = try fixture()
        var idle = original
        idle.status = .done
        idle.issue = 116
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
        #expect(fake.notes.isEmpty && desk.inbox.count == 1 && desk.issueJobs.count == 1)
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

    @Test func realGhMultilineScopeDiagnosticReachesSyncAndLead() async throws {
        let (desk, _, job) = try fixture()
        let folder = try temporaryFolder()
        let diagnostic = "error: your authentication token is missing required scopes [read:project]\nTo request it, run: gh auth refresh -s read:project"
        try executable("#!/bin/sh\nprintf '%s\\n' 'error: your authentication token is missing required scopes [read:project]' 'To request it, run: gh auth refresh -s read:project' >&2\nexit 1\n", at: folder.appending(path: "gh"))
        let environment: [String: String?] = ["PATH": folder.path + ":/usr/bin:/bin"]
        let raw = await #expect(throws: Shell.Failure.self) { try await Shell.ok(["gh", "project", "list"], env: environment) }
        #expect(raw?.localizedDescription.contains(diagnostic) == true)
        desk.issueSync.gh = { args in
            if args.first == "project" { return try await Shell.ok(["gh"] + args, env: environment) }
            if args.prefix(2) == ["issue", "view"] { return "{\"labels\":[],\"body\":\"\"}" }
            return ""
        }
        await send(job, to: desk)
        #expect(desk.issueJobs.first?.claim == "Issue sync: \(IssueSync.scopeFix)")
        let lead = await #expect(throws: Shell.Failure.self) {
            try await Board.read(repos: [job.repo], gh: { try await Shell.ok($0, env: environment) })
        }
        #expect(lead?.localizedDescription == IssueSync.scopeFix)
    }

    @Test func failedTransitionsBackOffStopAndSurviveRestart() async throws {
        let (desk, fake, original) = try fixture()
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        desk.issueSync.now = { time }
        fake.scopeFailure = true
        await send(original, to: desk)
        var count = fake.calls.count
        var step = original
        for index in 0..<20 {
            step.step = "Agent step \(index)"
            desk.issueSync.observe(step)
            await desk.issueSync.drain()
        }
        #expect(fake.calls.count == count)
        for delay in [60.0, 120.0, 240.0] {
            time = time.addingTimeInterval(delay - 1)
            desk.issueSync.observe(step)
            await desk.issueSync.drain()
            #expect(fake.calls.count == count)
            time = time.addingTimeInterval(1)
            desk.issueSync.observe(step)
            await desk.issueSync.drain()
            #expect(fake.calls.count > count)
            count = fake.calls.count
        }
        time = time.addingTimeInterval(86400)
        let restarted = IssueSync(desk: desk, store: desk.issueSync.store)
        restarted.enabled = true
        restarted.auditURL = desk.issueSync.auditURL
        restarted.gh = fake.run
        restarted.now = { time }
        restarted.observe(step)
        await restarted.drain()
        #expect(fake.calls.count == count)
        step.question = Plan.Question(text: "Which target?", options: [])
        restarted.observe(step)
        await restarted.drain()
        #expect(fake.calls.count > count)
        #expect(IssueSync.retryDelay(1) == 60 && IssueSync.retryDelay(2) == 120 && IssueSync.retryDelay(99) == 3600)
    }

    @Test func auditNeverCommentsOnOwnedPRs() async throws {
        let (desk, fake, original) = try fixture()
        var job = original
        job.status = .done
        job.published = "https://github.com/deskree-inc/oby/pull/117"
        desk.issueSync.store.save(job)
        fake.openPRs = [["url": job.published!, "closingIssuesReferences": [["number": 116, "url": fake.issueURL]]]]
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        await desk.issueSync.audit(now: day)
        #expect(fake.labels.contains("status:in-review") && fake.column == "In review")
        job = desk.issueJobs.first!
        job.published = "https://github.com/deskree-inc/oby/pull/118"
        desk.issueSync.store.save(job)
        fake.openPRs = [["url": job.published!, "closingIssuesReferences": [["number": 116, "url": fake.issueURL]]]]
        fake.labels = ["feature"]
        await desk.issueSync.audit(now: day.addingTimeInterval(86400))
        #expect(fake.labels.contains("status:in-review"))
        #expect(fake.notes.isEmpty && !fake.calls.contains { $0.prefix(2) == ["issue", "comment"] })
    }

    @Test func firstAuditRepairsRunningStatusWithoutBranchComments() async throws {
        let (desk, fake, _) = try fixture()
        await desk.issueSync.audit()
        #expect(fake.labels.contains("status:in-progress") && fake.column == "In progress")
        #expect(fake.notes.isEmpty)
    }

    @Test func issueOneDoesNotDeduplicateAgainstTwelveOrThirteen() async throws {
        let (desk, fake, original) = try fixture()
        var job = original
        job.id = "issue-one"
        job.issue = 1
        job.branch = "oby/build-1"
        fake.number = 1
        let outgoing = [12, 13].map { number in
            Outgoing(action: .init(rawValue: "issueClaim"), repo: job.repo, id: "https://github.com/\(job.repo)/issues/\(number) (issueClaim)")
        }
        let entries = try JSONSerialization.jsonObject(with: JSONEncoder().encode(outgoing))
        try JSONSerialization.data(withJSONObject: ["outgoing": entries]).write(to: desk.issueSync.auditURL)
        await send(job, to: desk)
        #expect(IssueSync.claimant(fake.body) == "issue-one")
        #expect(fake.labels.contains("status:in-progress") && fake.column == "In progress")
        #expect(desk.issueJobs.first { $0.id == "issue-one" }?.outgoing?.first?.id == "https://github.com/\(job.repo)/issues/1 (issueClaim)")
        let edits = fake.mutations.count
        let restarted = IssueSync(desk: desk, store: desk.issueSync.store)
        restarted.enabled = true
        restarted.auditURL = desk.issueSync.auditURL
        restarted.gh = fake.run
        restarted.observe(job)
        await restarted.drain()
        #expect(fake.mutations.count == edits)
        #expect(fake.notes.isEmpty && !fake.calls.contains { $0.prefix(2) == ["issue", "comment"] })
    }

    /// Issues claimed before #162 have only the start comment: it's read, never written, until a claim line replaces it.
    @Test func claimsMadeByStartCommentsStillClear() async throws {
        let legacy = { (id: String) in "Oby is working on branch `oby/build-116` (job \(id))." }
        let (desk, fake, original) = try fixture()
        fake.labels = ["feature", "status:in-progress"]
        fake.notes = [legacy(original.id)]
        var done = original
        done.status = .done
        await send(done, to: desk)
        #expect(fake.labels == ["feature"] && fake.notes.count == 1)
        #expect(!fake.calls.contains { $0.prefix(2) == ["issue", "comment"] })

        let (other, otherFake, otherJob) = try fixture()
        otherFake.labels = ["feature", "status:blocked"]
        otherFake.notes = [legacy(otherJob.id), legacy("mac-job")]
        var finished = otherJob
        finished.status = .done
        await send(finished, to: other)
        #expect(otherFake.labels.contains("status:blocked"))
        otherFake.notes = [legacy(otherJob.id)]
        otherFake.body = IssueSync.claimed(otherFake.body, by: "mac-job")
        await other.issueSync.audit(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(otherFake.labels.contains("status:blocked") && other.inbox.isEmpty)

        let (audited, auditFake, auditJob) = try fixture()
        var idle = auditJob
        idle.status = .done
        audited.issueSync.store.save(idle)
        auditFake.labels = ["feature", "status:in-progress"]
        auditFake.notes = [legacy(auditJob.id)]
        await audited.issueSync.audit(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(auditFake.labels == ["feature"] && auditFake.notes.count == 1)
        #expect(audited.inbox.first?.text == "Issue audit: fixed drift on 1 issue(s).")
    }

    @Test func runnerAuditPreservesWorkOwnedByTheMacDesk() async throws {
        let (mac, fake, macJob) = try fixture()
        await send(macJob, to: mac)
        let (runner, _, original) = try fixture()
        var unrelated = original
        unrelated.issue = nil
        unrelated.branch = "unrelated"
        unrelated.task = "Unrelated work"
        runner.issueSync.store.save(unrelated)
        runner.issueSync.gh = fake.run
        let count = fake.mutations.count
        await runner.issueSync.audit()
        #expect(mac.issueJobs.first?.status == .running)
        #expect(fake.labels.contains("status:in-progress") && fake.column == "In progress")
        #expect(fake.mutations.count == count && runner.inbox.isEmpty)
    }

    @Test func runnerKeepsRunningStatusWhileTheMacHoldsTheLatestClaim() async throws {
        let (runner, fake, original) = try fixture()
        await send(original, to: runner)
        let (mac, _, stale) = try fixture()
        var unrelated = stale
        unrelated.issue = nil
        unrelated.status = .done
        mac.issueSync.store.save(unrelated)
        mac.issueSync.gh = fake.run
        var macJob = original
        macJob.id = "mac-job"
        macJob.branch = "oby/fix-116"
        macJob.started = Date(timeIntervalSince1970: 5678)
        await send(macJob, to: mac)
        #expect(IssueSync.claimant(fake.body) == "mac-job" && fake.notes.isEmpty)
        var done = runner.issueJobs.first { $0.id == original.id }!
        done.status = .done
        await send(done, to: runner)
        #expect(fake.labels.contains("status:in-progress"))
        await runner.issueSync.audit()
        #expect(fake.labels.contains("status:in-progress") && fake.column == "In progress" && runner.inbox.isEmpty)
        macJob = mac.issueJobs.first { $0.id == "mac-job" }!
        macJob.status = .done
        await send(macJob, to: mac)
        #expect(!fake.labels.contains("status:in-progress"))
    }

    // MARK: A status the roadmap lacks is a decision (#215)

    /// A merged slice whose Build list is done belongs in Needs test, on a roadmap with no such column.
    func lackingNeedsTest() throws -> (Desk, FakeGH, Date) {
        let (desk, fake, original) = try fixture()
        var merged = original
        merged.status = .done
        merged.pullRequest = PullRequestStatus(state: .merged, base: "dev", mergedAt: .now, checkedAt: .now)
        desk.issueSync.store.save(merged)
        fake.body = "## Build\n- [x] First slice\n\n## Test it when it's done\n- [ ] Test on a Mac"
        fake.column = "In progress"
        fake.options = ["Todo", "In progress", "In review", "Blocked", "Done"]
        return (desk, fake, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func decision(_ desk: Desk) -> InboxItem? { desk.inbox.first { $0.isOpen && $0.title == IssueSync.statusTitle("Needs test") } }

    @Test func aMissingStatusIsADecisionNotAReport() async throws {
        let (desk, fake, day) = try lackingNeedsTest()
        await desk.issueSync.audit(now: day)
        // Nothing fixed, nothing failed: no report. The missing column asks the owner, with what it can do.
        let item = try #require(decision(desk))
        #expect(desk.inbox.count == 1 && item.kind == .audit && item.job == "" && item.isDecision)
        // As Claude Code asks: each answer says what it does, the recommended one first.
        #expect(item.options == ["Add the column", "Use In review instead", "Ignore this status"] && item.recommended == 0)
        #expect(item.details == ["Adds Needs test to the roadmap's Status field, every card keeping its column, and moves these issues there.",
                                 "Moves these issues to In review, now and whenever they'd go to Needs test.",
                                 "Leaves these issues where they are, and doesn't ask about Needs test again."])
        #expect(item.text == "The roadmap's Status field has no Needs test option. Issues that belong there stay where they are: deskree-inc/oby#116.")
        #expect(fake.column == "In progress" && fake.mutations.isEmpty)
        // Asked once: the next day's audit doesn't ask again while it waits, even put off.
        try desk.settle(item.id, .later(day.addingTimeInterval(3600)))
        await desk.issueSync.audit(now: day.addingTimeInterval(86400))
        #expect(desk.inbox.filter { $0.title == item.title }.count == 1)
        // Only what it offers: other words change nothing.
        #expect(throws: (any Error).self) { try desk.settle(item.id, .answer("Make one up")) }
        #expect(desk.item(item.id)?.isOpen == true)
    }

    @Test func useInsteadMovesTheIssuesAndIsRemembered() async throws {
        let (desk, fake, day) = try lackingNeedsTest()
        await desk.issueSync.audit(now: day)
        let item = try #require(decision(desk))
        let settled = try desk.settle(item.id, .answer("Use In review instead"))
        #expect(settled.done != nil && settled.answer == "Use In review instead")
        // It moves them now, and remembers it for that status.
        await desk.issueSync.drain()
        #expect(fake.column == "In review")
        #expect(desk.issueSync.choice(for: "Needs test") == IssueSync.Choice(use: "In review"))
        // The next audit, and a job's own step, use it: no item, no move back.
        fake.column = "In progress"
        await desk.issueSync.audit(now: day.addingTimeInterval(2 * 86400))
        #expect(fake.column == "In review" && desk.inbox.filter(\.isOpen).isEmpty)
        // After a restart too.
        let restarted = IssueSync(desk: desk, store: desk.issueSync.store)
        restarted.auditURL = desk.issueSync.auditURL
        #expect(restarted.choice(for: "needs test")?.use == "In review")
    }

    @Test func ignoreThisStatusLeavesItsIssuesAloneAndIsRemembered() async throws {
        let (desk, fake, day) = try lackingNeedsTest()
        await desk.issueSync.audit(now: day)
        let item = try #require(decision(desk))
        try desk.settle(item.id, .answer(Inbox.ignoreStatus))
        await desk.issueSync.drain()
        #expect(desk.issueSync.choice(for: "Needs test") == IssueSync.Choice(use: nil))
        let calls = fake.calls.count
        await desk.issueSync.audit(now: day.addingTimeInterval(86400))
        #expect(fake.calls.count > calls)
        #expect(fake.column == "In progress" && fake.mutations.isEmpty && desk.inbox.filter(\.isOpen).isEmpty)
    }

    /// Once the column exists, the decision is done by itself and the issue moves there.
    @Test func theDecisionGoesOnceTheColumnExists() async throws {
        let (desk, fake, day) = try lackingNeedsTest()
        await desk.issueSync.audit(now: day)
        let item = try #require(decision(desk))
        fake.options.append("Needs test")
        await desk.issueSync.audit(now: day.addingTimeInterval(86400))
        #expect(desk.item(item.id)?.done != nil && desk.item(item.id)?.answer == nil)
        #expect(fake.column == "Needs test" && desk.inbox.filter(\.isOpen).isEmpty)
        #expect(desk.issueSync.choice(for: "Needs test") == nil)
    }

    /// Add the column: every option goes back with its id in its order, the new one with none after
    /// In review; the ids are read back to check they were kept, and the issue moves.
    @Test func addTheColumnKeepsEveryOptionAndMovesTheIssues() async throws {
        let (desk, fake, day) = try lackingNeedsTest()
        fake.ids = ["Todo": "OPT-1", "In progress": "OPT-2", "In review": "OPT-3", "Blocked": "OPT-4", "Done": "OPT-5"]
        var scanned: [String] = []
        desk.issueSync.scan = { texts in scanned += texts.map(\.text) }
        await desk.issueSync.audit(now: day)
        let item = try #require(decision(desk))
        // Only through what reaches GitHub: settling it in place is refused.
        #expect(throws: (any Error).self) { try desk.settle(item.id, .answer(Inbox.addColumn)) }
        let settled = try await desk.answer(item.id, .answer(Inbox.addColumn))
        #expect(settled.done != nil && settled.answer == Inbox.addColumn)
        let sent = try #require(fake.fieldUpdates.first)
        #expect(fake.fieldUpdates.count == 1)
        #expect(sent.map { $0["name"] as? String } == ["Todo", "In progress", "In review", "Needs test", "Blocked", "Done"])
        #expect(sent.map { $0["id"] as? String } == ["OPT-1", "OPT-2", "OPT-3", nil, "OPT-4", "OPT-5"])
        // Each option keeps its color and description; the new one is gray, with none.
        #expect(sent[5]["color"] as? String == "GREEN" && sent[5]["description"] as? String == "Done cards")
        #expect(sent[3]["color"] as? String == "GRAY" && sent[3]["description"] as? String == "")
        // What went out was scanned first, and the options were read again after.
        #expect(scanned.contains { $0.contains("updateProjectV2Field") && $0.contains("OPT-5") })
        #expect(fake.calls.filter { $0.contains { $0.contains("ProjectV2SingleSelectField{options") } }.count == 2)
        // The audit ran again: the issue is in Needs test, and nothing waits.
        await desk.issueSync.drain()
        #expect(fake.column == "Needs test" && desk.inbox.filter(\.isOpen).isEmpty)
    }

    /// Options that come back with other ids aren't the ones the cards were on: an error, and the
    /// item waits. A scan that can't pass sends nothing.
    @Test func addTheColumnRefusesChangedIdsAndUnscannedRequests() async throws {
        let (desk, fake, day) = try lackingNeedsTest()
        fake.renumbers = true
        await desk.issueSync.audit(now: day)
        let item = try #require(decision(desk))
        let error = await #expect(throws: (any Error).self) { try await desk.answer(item.id, .answer(Inbox.addColumn)) }
        #expect(error?.localizedDescription.contains("didn't come back as they were") == true)
        #expect(desk.item(item.id)?.isOpen == true)

        let (other, otherFake, otherDay) = try lackingNeedsTest()
        await other.issueSync.audit(now: otherDay)
        let waiting = try #require(decision(other))
        other.issueSync.scan = { _ in throw Shell.Failure(message: "scanner unavailable") }
        await #expect(throws: (any Error).self) { try await other.answer(waiting.id, .answer(Inbox.addColumn)) }
        #expect(otherFake.fieldUpdates.isEmpty && other.item(waiting.id)?.isOpen == true)
    }

    /// No column to offer instead: only Ignore.
    @Test func closestColumnIsTheStepBefore() {
        #expect(IssueSync.closest(to: "Needs test", in: ["Todo", "In progress", "in review"]) == "in review")
        #expect(IssueSync.closest(to: "Needs test", in: ["Todo", "In progress"]) == "In progress")
        #expect(IssueSync.closest(to: "Needs test", in: ["Todo", "Done"]) == nil)
        #expect(IssueSync.closest(to: "In progress", in: ["Todo", "In review"]) == nil)
    }

    /// What failed waits with Try again, which runs the audit again now.
    @Test func aFailedAuditCanBeTriedAgain() async throws {
        let (desk, fake, original) = try fixture()
        var job = original
        job.status = .done
        desk.issueSync.store.save(job)
        fake.repositoryFailure = "Resource not accessible"
        fake.labels = ["status:in-progress", "feature"]
        fake.body = IssueSync.claimed(fake.body, by: original.id)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        await desk.issueSync.audit(now: day)
        let report = try #require(desk.inbox.first { $0.isOpen })
        #expect(report.title == IssueSync.reportTitle && report.options == [Inbox.tryAgain] && report.text.contains("Resource not accessible"))
        fake.repositoryFailure = nil
        try desk.settle(report.id, .answer(Inbox.tryAgain))
        await desk.issueSync.drain()
        #expect(fake.labels == ["feature"])
        // The second run's report is its own item, done: it fixed the drift by itself.
        #expect(desk.inbox.count == 2 && desk.inbox.filter(\.isOpen).isEmpty && desk.inbox.last?.id != report.id)
    }
}
