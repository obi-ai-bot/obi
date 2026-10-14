import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import oby_runner

@Suite(.serialized)
struct ResearchTests {
    @Test func researchRunsAtComplexEffortWithTwoRounds() {
        var research = job
        research.kind = .research
        research.rounds = 1
        Research.shape(&research)
        #expect(research.complexity == .complex)
        #expect(research.effort == AgentModels.effort(research.agent, complex: true))
        #expect(research.rounds == 2)
        research.rounds = 9
        Research.shape(&research)
        #expect(research.rounds == 4)
    }

    @Test func roundOneAlwaysGetsTheVerifyRound() {
        var research = job
        research.kind = .research
        research.round = 1
        research.rounds = 2
        guard case .again(let message) = Rounds.next(research, summary: "GOAL MET", failed: false, check: nil) else {
            Issue.record("Round one should always verify")
            return
        }
        #expect(message.contains("Verification round"))
    }

    @Test func researchNeverPublishes() throws {
        var research = job
        research.kind = .research
        research.base = "dev"
        research.status = .done
        research.commits = 2
        #expect(!research.canPublish)
        let ended = Job.ending(research, .done, "Finished", made: 2)
        #expect(ended.0 == .failed)
        #expect(ended.1.hasPrefix("Not published: research jobs don't commit"))
    }

    @Test @MainActor func deskPublishRefusesResearchJobs() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        var research = job
        research.id = "research"
        research.kind = .research
        research.base = "dev"
        research.status = .done
        research.commits = 2
        desk.dispatch(research)
        await #expect(throws: Shell.Failure.self) { try await desk.publish(research.id) { _ in } }
    }

    @Test func researchDeniesWritesOutsideOby() {
        let root = URL(filePath: "/tmp/research-test")
        #expect(Policy.deny(tool: "Edit", input: ["file_path": "Engine/Brain.swift"], worktree: root, kind: .research) != nil)
        #expect(Policy.deny(tool: "Write", input: ["file_path": ".oby/report.md"], worktree: root, kind: .research) == nil)
        #expect(Policy.deny(tool: "Write", input: ["file_path": ".oby/proposed-issues.json"], worktree: root, kind: .research) == nil)
        for path in ["Engine/Brain.swift", ".oby/reads/acme/arch/CLAUDE.md", ".oby/inputs/reads.md"] {
            #expect(Policy.deny(tool: "Write", input: ["file_path": path], worktree: root, kind: .research) != nil, "\(path)")
        }
        #expect(Policy.deny(tool: "MultiEdit", input: [:], worktree: root, kind: .research) != nil)
        for command in ["printf x > Engine/Brain.swift", "chmod -R u+w .oby/reads", "git commit -m x"] {
            #expect(Policy.deny(tool: "Bash", input: ["command": command], worktree: root, kind: .research) != nil, "\(command)")
        }
    }

    @Test func researchWritesCannotEscapeThroughSymlinks() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appending(path: "jobs/research")
        let oby = worktree.appending(path: ".oby")
        let engine = worktree.appending(path: "Engine")
        try FileManager.default.createDirectory(at: oby, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        let source = engine.appending(path: "Brain.swift")
        try Data("source".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: oby.appending(path: "report.md"), withDestinationURL: source)
        #expect(Policy.deny(tool: "Write", input: ["file_path": ".oby/report.md"], worktree: worktree, kind: .research) != nil)
    }

    @Test func worktreePathsBecomeGitHubLinksAndRejectTraversal() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let clone = Workspace.clone("deskree-inc/oby", root: root)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        func git(_ args: [String]) async throws -> String { try await Shell.ok(["git", "-C", clone.path] + args) }
        _ = try await git(["init", "-q"])
        _ = try await git(["config", "user.email", "test@example.com"])
        _ = try await git(["config", "user.name", "Test"])
        try FileManager.default.createDirectory(at: clone.appending(path: "Engine"), withIntermediateDirectories: true)
        try Data("source".utf8).write(to: clone.appending(path: "Engine/Brain.swift"))
        try Data("source".utf8).write(to: clone.appending(path: "Runner.swift"))
        _ = try await git(["add", "."])
        _ = try await git(["commit", "-qm", "fixture"])
        let sha = try await git(["rev-parse", "HEAD"])
        var research = job
        research.kind = .research
        research.id = "abcd1234"
        research.startCommit = sha.trimmingCharacters(in: .whitespacesAndNewlines)
        let report = "\(Workspace.worktree("abcd1234", root: root).path)/Engine/Brain.swift:529 and `Runner.swift:76-80` and `Missing.swift:9` and `../etc/passwd:2"
        let linked = ResearchLinks.rewrite(report, job: research, root: root)
        #expect(linked.contains("https://github.com/deskree-inc/oby/blob/\(research.startCommit!)/Engine/Brain.swift#L529"))
        #expect(linked.contains("https://github.com/deskree-inc/oby/blob/\(research.startCommit!)/Runner.swift#L76-L80"))
        #expect(linked.contains("`Missing.swift:9`"))
        #expect(linked.contains("../etc/passwd:2"))
    }

    @Test func readPathsUseTheirOwnRepositoryCommit() {
        var research = job
        research.kind = .research
        research.startCommit = "base123"
        research.readCommits = ["deskree-inc/tetrix-architecture": "read456"]
        let text = ".oby/reads/deskree-inc/tetrix-architecture/CLAUDE.md:12"
        #expect(ResearchLinks.rewrite(text, job: research).contains("https://github.com/deskree-inc/tetrix-architecture/blob/read456/CLAUDE.md#L12"))
    }

    @Test func aNamedRepositoryIsExportedAtItsDefaultCommitAndReadOnly() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appending(path: "arch.git")
        let source = root.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try await Shell.ok(["git", "init", "--quiet", "-b", "main", source.path])
        try await Shell.ok(["git", "-C", source.path, "config", "user.email", "test@example.com"])
        try await Shell.ok(["git", "-C", source.path, "config", "user.name", "Test"])
        try Data("Architecture\n".utf8).write(to: source.appending(path: "CLAUDE.md"))
        try await Shell.ok(["git", "-C", source.path, "add", "."])
        try await Shell.ok(["git", "-C", source.path, "commit", "--quiet", "-m", "architecture"])
        try await Shell.ok(["git", "init", "--quiet", "--bare", remote.path])
        try await Shell.ok(["git", "-C", remote.path, "symbolic-ref", "HEAD", "refs/heads/main"])
        try await Shell.ok(["git", "-C", source.path, "remote", "add", "origin", remote.path])
        try await Shell.ok(["git", "-C", source.path, "push", "--quiet", "origin", "main"])

        let worktree = root.appending(path: "jobs/research")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        var research = job
        research.id = "research"
        research.kind = .research
        research.reads = ["acme/arch"]
        try await Workspace.prepareReads(&research, in: worktree, root: root, cloneURL: { _ in remote.path })
        let exported = worktree.appending(path: ".oby/reads/acme/arch/CLAUDE.md")
        #expect(try String(contentsOf: exported, encoding: .utf8) == "Architecture\n")
        #expect(research.readCommits?["acme/arch"]?.count == 40)
        #expect(try String(contentsOf: worktree.appending(path: ".oby/inputs/reads.md"), encoding: .utf8).contains(research.readCommits?["acme/arch"] ?? "missing"))
        do {
            try Data("change".utf8).write(to: exported)
            Issue.record("The named repository export should be read-only")
        } catch { }
    }

    @Test func readExportsStayReadOnlyAndHideGitHubLoginInTheBox() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appending(path: "jobs/research")
        let reads = worktree.appending(path: ".oby/reads/acme/arch")
        try FileManager.default.createDirectory(at: reads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree.appending(path: ".git"), withIntermediateDirectories: true)
        let target = reads.appending(path: "CLAUDE.md")
        try Data("architecture".utf8).write(to: target)
        func boxed(_ argv: [String]) -> [String] {
            Agents.sandboxed(argv, in: worktree, own: nil,
                             reading: [worktree.appending(path: ".oby/reads").path], bubblewrap: true, research: true, apple: nil)
        }
        let writeCommand = ["sh", "-c", "touch \"\(target.path)\""]
        let reportCommand = ["sh", "-c", "printf report > \"\(worktree.appending(path: ".oby/report.md").path)\""]
        let readonlyWorktree = ["--ro-bind", worktree.path, worktree.path]
        let writableOby = ["--bind", worktree.appending(path: ".oby").path, worktree.appending(path: ".oby").path]
        let readOnlyBind = ["--ro-bind", worktree.appending(path: ".oby/reads").path,
                            worktree.appending(path: ".oby/reads").path]
        let writeBox = boxed(writeCommand)
        func index(of sequence: [String]) -> Int? {
            guard sequence.count <= writeBox.count else { return nil }
            return (0...(writeBox.count - sequence.count)).first {
                Array(writeBox[$0..<$0 + sequence.count]) == sequence
            }
        }
        if let worktreeReadOnlyIndex = index(of: readonlyWorktree),
           let obyWritableIndex = index(of: writableOby),
           let readOnlyBindIndex = index(of: readOnlyBind) {
            #expect(obyWritableIndex > worktreeReadOnlyIndex)
            #expect(readOnlyBindIndex > obyWritableIndex)
        } else {
            Issue.record("The research sandbox should keep the worktree read-only, expose .oby for reports, and keep exports read-only")
        }

        guard bubblewrapRuns else { return }
        func run(_ argv: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = boxed(argv)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try run(["sh", "-c", "touch \"\(target.path)\""]) != 0)
        #expect(try run(reportCommand) == 0)
        #expect(try run(["gh", "auth", "status"]) != 0)
    }

    @Test func codexResearchUsesLiveWebSearchInEveryMode() {
        let worktree = URL(filePath: "/tmp/research")
        let plan = CodexRPC.threadStart(worktree: worktree, git: nil, bubblewrap: false, mode: .plan, research: true)
        #expect((plan["config"] as? [String: Any])?["web_search"] as? String == "live")
        let resumed = CodexRPC.threadResume(thread: "thread", worktree: worktree, git: nil, research: true)
        #expect((resumed["config"] as? [String: Any])?["web_search"] as? String == "live")
        let ordinary = CodexRPC.threadStart(worktree: worktree, git: nil, bubblewrap: false)
        #expect((ordinary["config"] as? [String: Any])?["web_search"] == nil)
    }

    @Test func anUnknownReadIsRefusedByPlanValidation() {
        let dispatch = Plan.Dispatch(agent: "codex", account: "default", repo: "deskree-inc/oby", baseBranch: nil,
                                     pr: nil, issue: nil, epic: nil, kind: .research, title: nil, task: "Compare the architecture",
                                     inputs: [], rounds: 1, check: nil, complexity: .routine, reads: ["acme/arch"])
        let plan = Plan(action: .dispatch, reply: "", dispatches: [dispatch], question: nil)
        let context = BrainContext(accounts: ["codex": ["default"]], repos: ["deskree-inc/oby"])
        #expect(plan.problems(in: context, canary: "c4n4ry") == ["acme/arch isn't a known repository"])
    }

    @Test func theReportIsStoredAndReadableFromJobStore() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        let report = ResearchReport(job: "research", commit: "abc123", markdown: "# Findings", created: .now, proposals: [])
        store.save(report)
        #expect(store.report("research") == report)
        #expect(store.report("missing") == nil)
    }

    @Test @MainActor func theReportIsServedByItsEndpoint() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.prepare = { $0 }
        var research = job
        research.id = "report-job"
        research.kind = .research
        research.status = .done
        desk.store.save(research)
        desk.store.save(ResearchReport(job: research.id, commit: "abc123", markdown: "# Answer\n\nVerified.", created: .now, proposals: []))
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/jobs/report-job/report", method: .get,
                                     headers: [.tailscaleUserLogin: "well@example.com"]) { response in
                #expect(response.status == .ok)
                let body = object(Data(response.body.readableBytesView))
                #expect(body["commit"] as? String == "abc123")
                #expect(body["markdown"] as? String == "# Answer\n\nVerified.")
            }
            try await client.execute(uri: "/v1/jobs/report-job/report", method: .get,
                                     headers: [.tailscaleUserLogin: "well@example.com"]) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test @MainActor func anUnknownReadIsRejectedByJobsAPI() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/jobs", method: .post, headers: [.tailscaleUserLogin: "well@example.com"],
                                     body: ByteBuffer(string: #"{"job":{"repo":"deskree-inc/oby","kind":"research","task":"Compare designs","reads":["acme/arch"]}}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(decoding: response.body.readableBytesView, as: UTF8.self).contains("acme/arch isn't a known repository"))
            }
        }
    }

    @Test @MainActor func proposalsAreScannedBeforeTheyCanBeFiledAndFileOnlyOnce() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.prepare = { $0 }
        var research = job
        research.id = "proposal-job"
        research.kind = .research
        research.status = .done
        desk.store.save(research)
        let proposal = ProposedIssue(index: 0, repo: "deskree-inc/oby", title: "Document architecture", body: "## What\nDocument the design.", labels: [], filed: nil, filedAt: nil)
        desk.store.save(ResearchReport(job: research.id, commit: "abc123", markdown: "# Answer", created: .now, proposals: [proposal]))
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        actor Calls { var gh = 0; func sawGH() { gh += 1 }; func count() -> Int { gh } }
        let calls = Calls()
        try await Shell.$stand.withValue(Shell.Stand(run: { args, _ in
            if args.first == "gitleaks" { return Shell.Output(status: 0, out: Data(), err: "") }
            if args.prefix(3).elementsEqual(["gh", "issue", "create"]) {
                await calls.sawGH()
                return Shell.Output(status: 0, out: Data("https://github.com/deskree-inc/oby/issues/999".utf8), err: "")
            }
            throw Shell.Failure(message: "Unexpected command")
        })) {
            try await app.test(.router) { client in
                let headers: HTTPFields = [.tailscaleUserLogin: "well@example.com"]
                try await client.execute(uri: "/v1/jobs/proposal-job/proposals/0/file", method: .post,
                                         headers: headers, body: ByteBuffer(string: #"{"start":false}"#)) { response in
                    #expect(response.status == .ok)
                    #expect(object(Data(response.body.readableBytesView))["issue"] as? String == "https://github.com/deskree-inc/oby/issues/999")
                }
                try await client.execute(uri: "/v1/jobs/proposal-job/proposals/0/file", method: .post,
                                         headers: headers, body: ByteBuffer(string: #"{"start":false}"#)) { response in
                    #expect(response.status == .conflict)
                }
            }
        }
        #expect(await calls.count() == 1)
        #expect(desk.store.report(research.id)?.proposals.first?.filed == "https://github.com/deskree-inc/oby/issues/999")
        #expect(desk.job(research.id)?.outgoing?.contains(where: { $0.action == .issue }) == true)
    }

    @Test @MainActor func aMissingScannerFilesNothing() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        var research = job
        research.id = "no-scanner"
        research.kind = .research
        research.status = .done
        desk.store.save(research)
        desk.store.save(ResearchReport(job: research.id, commit: "abc123", markdown: "# Answer", created: .now,
                                       proposals: [ProposedIssue(index: 0, repo: research.repo, title: "Write docs", body: "What", labels: [], filed: nil, filedAt: nil)]))
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        actor Calls { var gh = 0; func sawGH() { gh += 1 }; func count() -> Int { gh } }
        let calls = Calls()
        try await Shell.$stand.withValue(Shell.Stand(run: { args, _ in
            if args.first == "gitleaks" { throw Shell.Failure(message: "scanner unavailable") }
            await calls.sawGH()
            return Shell.Output(status: 0, out: Data(), err: "")
        })) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/v1/jobs/no-scanner/proposals/0/file", method: .post,
                                         headers: [.tailscaleUserLogin: "well@example.com"], body: ByteBuffer(string: #"{"start":false}"#)) { response in
                    #expect(response.status == .unprocessableContent)
                }
            }
        }
        #expect(await calls.count() == 0)
        #expect(desk.store.report(research.id)?.proposals.first?.filed == nil)
    }

    @Test @MainActor func aSecretInAProposalIsRefused() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        var research = job
        research.id = "secret-proposal"
        research.kind = .research
        research.status = .done
        desk.store.save(research)
        let flaggedProposalFixture = ["fake", "key", "for", "secret", "scan", "test"].joined(separator: "-")
        desk.store.save(ResearchReport(job: research.id, commit: "abc123", markdown: "# Answer", created: .now,
                                       proposals: [ProposedIssue(index: 0, repo: research.repo, title: "Write docs", body: flaggedProposalFixture, labels: [], filed: nil, filedAt: nil)]))
        let api = API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json")))
        let app = Application(router: api.router(owner: "well@example.com"))
        actor Calls { var gh = 0; func sawGH() { gh += 1 }; func count() -> Int { gh } }
        let calls = Calls()
        try await Shell.$stand.withValue(Shell.Stand(run: { args, _ in
            if args.first == "gitleaks" { return Shell.Output(status: 99, out: Data(), err: "finding") }
            await calls.sawGH()
            return Shell.Output(status: 0, out: Data(), err: "")
        })) {
            try await app.test(.router) { client in
                try await client.execute(uri: "/v1/jobs/secret-proposal/proposals/0/file", method: .post,
                                         headers: [.tailscaleUserLogin: "well@example.com"], body: ByteBuffer(string: #"{"start":false}"#)) { response in
                    #expect(response.status == .unprocessableContent)
                }
            }
        }
        #expect(await calls.count() == 0)
        #expect(desk.store.report(research.id)?.proposals.first?.filed == nil)
    }
}
