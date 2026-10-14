import Foundation
import Testing
@testable import ObyEngine
@testable import ObyShared
@testable import oby_runner

/// Every agent uses Tetrix, and Oby makes sure of it (#130, Engine/TetrixUse.swift): detected from
/// the tools' own events, required in the prompt, checked and reported after each round, shown per account.
@MainActor
struct TetrixTests {
    /// An agent whose events the test sends, noting its prompt and what it was told after.
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var prompt = ""
        var sent: [String] = []
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
            self.prompt = prompt
            self.onEvent = onEvent
        }
        func send(_ text: String) { sent.append(text) }
        func end() {}
        func stop() {}
        func kill() {}
    }

    // Recorded from Claude Code 2.1 (stream-json, --verbose) and codex app-server, trimmed.
    nonisolated static let claudeInit = #"{"type":"system","subtype":"init","cwd":"/srv/oby/jobs/ab12cd34","session_id":"e6a24229-3d3b-417b-a610-691c636b4c49","tools":["Bash","Read","Edit","mcp__tetrix__search_entities","mcp__tetrix__get_entity","mcp__tetrix__code_impact","mcp__tetrix__save_session"],"mcp_servers":[{"name":"tetrix","status":"connected"},{"name":"github","status":"failed"}],"model":"claude-opus-5-5","permissionMode":"default","apiKeySource":"none","output_style":"default"}"#
    nonisolated static let claudeInitNoTetrix = #"{"type":"system","subtype":"init","session_id":"s2","tools":["Bash"],"mcp_servers":[{"name":"tetrix","status":"needs-auth"}]}"#
    nonisolated static let claudeToolUse = #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Asking Tetrix first."},{"type":"tool_use","id":"toolu_1","name":"mcp__tetrix__search_entities","input":{"query":"issue 130 Tetrix"}},{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/srv/oby/jobs/ab12cd34/Engine/Jobs.swift"}}]},"session_id":"e6a24229"}"#
    nonisolated static let claudeSave = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_9","name":"mcp__tetrix__save_session","input":{"summary":"Did the work."}}]}}"#
    nonisolated static let codexStatus = #"{"id":3,"result":{"data":[{"name":"tetrix","tools":{"search_entities":{"name":"search_entities","inputSchema":{"type":"object"}},"save_session":{"name":"save_session","inputSchema":{"type":"object"}}},"resources":[],"resourceTemplates":[],"authStatus":"oAuth"},{"name":"github","tools":{},"resources":[],"resourceTemplates":[],"authStatus":"notLoggedIn"}],"nextCursor":null}}"#
    nonisolated static let codexSignedOut = #"{"id":3,"result":{"data":[{"name":"tetrix","tools":{},"resources":[],"resourceTemplates":[],"authStatus":"notLoggedIn"}],"nextCursor":null}}"#
    nonisolated static let codexCall = #"{"method":"item/started","params":{"threadId":"t1","turnId":"u1","item":{"type":"mcpToolCall","id":"call_1","server":"tetrix","tool":"get_entity","status":"inProgress","arguments":{"id":"issue:deskree-inc/oby#130"}}}}"#
    nonisolated static let codexOtherCall = #"{"method":"item/started","params":{"threadId":"t1","item":{"type":"mcpToolCall","id":"call_2","server":"github","tool":"get_issue","status":"inProgress"}}}"#

    static func message(_ line: String) -> [String: Any] { object(Data(line.utf8)) }

    // MARK: Detecting it

    @Test func claudeCodeSaysWhetherTetrixIsConnectedAndWhatItCalled() {
        #expect(StreamJSON.events(Self.message(Self.claudeInit)) == [.session("e6a24229-3d3b-417b-a610-691c636b4c49"), .tetrix(.connected(true))])
        #expect(StreamJSON.events(Self.message(Self.claudeInitNoTetrix)) == [.session("s2"), .tetrix(.connected(false))])
        // An init without the list says nothing about Tetrix.
        #expect(StreamJSON.events(["type": "system", "subtype": "init", "session_id": "s3"]) == [.session("s3")])
        #expect(StreamJSON.events(Self.message(Self.claudeToolUse)) == [.step("Using mcp__tetrix__search_entities"), .tetrix(.call("search_entities")), .step("Reading Jobs.swift")])
        #expect(TetrixUse.tool("mcp__claude_ai_Tetrix__code_impact") == "code_impact")
        #expect(TetrixUse.tool("mcp__github__search_entities") == nil && TetrixUse.tool("mcp__evil__tetrix__x") == nil && TetrixUse.tool("Read") == nil)
    }

    @Test func codexSaysWhetherTetrixIsConnectedAndWhatItCalled() {
        let status = Self.message(Self.codexStatus)["result"] as? [String: Any] ?? [:]
        #expect(TetrixUse.codexStatus(status) == true)
        #expect(TetrixUse.codexStatus(Self.message(Self.codexSignedOut)["result"] as? [String: Any] ?? [:]) == false)
        #expect(TetrixUse.codexStatus(["data": []]) == false)
        // An older Codex answers without the list.
        #expect(TetrixUse.codexStatus([:]) == nil)
        #expect(CodexRPC.events(Self.message(Self.codexCall)) == [.step("Using get_entity"), .tetrix(.call("get_entity"))])
        #expect(CodexRPC.events(Self.message(Self.codexOtherCall)) == [.step("Using get_issue")])
    }

    @Test func claudeMCPListSaysWhetherTetrixIsConnected() {
        let listed = """
            Checking MCP server health...

            github: npx -y @modelcontextprotocol/server-github - ✗ Failed to connect
            tetrix: https://mcp.tetrix.example/mcp (HTTP) - ✓ Connected
            """
        #expect(TetrixUse.claudeList(listed))
        #expect(!TetrixUse.claudeList("tetrix: https://mcp.tetrix.example/mcp (HTTP) - ⚠ Needs authentication"))
        #expect(!TetrixUse.claudeList("No MCP servers configured. Use `claude mcp add` to add a server."))
    }

    @Test func agentsMaySaveTheirSessionButNotWriteElsewhere() {
        let worktree = URL(filePath: "/tmp/oby/jobs/abc")
        #expect(Policy.deny(tool: "mcp__tetrix__save_session", input: [:], worktree: worktree) == nil)
        #expect(Policy.deny(tool: "mcp__tetrix__answer_hitl_question", input: [:], worktree: worktree) != nil)
        #expect(Policy.deny(tool: "mcp__github__save_session", input: [:], worktree: worktree) != nil)
    }

    /// #214: earlier sessions' digests are read like the graph; the owner's private state, Tetrix's
    /// admin and write tools and its diagnostics stay refused, all with the same message.
    @Test func agentsMayReadEarlierSessionsDigestsButNotResumeThem() {
        let worktree = URL(filePath: "/tmp/oby/jobs/abc")
        for tool in ["session_digest", "session_context", "repo_sessions", "list_sessions"] {
            #expect(Policy.deny(tool: "mcp__tetrix__\(tool)", input: [:], worktree: worktree) == nil, "\(tool)")
            #expect(Policy.deny(tool: "mcp__claude_ai_Tetrix__\(tool)", input: [:], worktree: worktree) == nil, "\(tool)")
        }
        for tool in ["resume_session", "admin_replay_dead_letters", "route_hitl_question", "report_agent_usage", "diagnostics_triage"] {
            let name = "mcp__tetrix__\(tool)"
            #expect(Policy.deny(tool: name, input: [:], worktree: worktree)
                == "Oby's agents use only Tetrix's graph reads, earlier sessions' digests and save_session among MCP tools. Say in your summary what you'd have done with \(name).")
        }
    }

    @Test func agentsAreToldToReadEarlierSessionsFirst() {
        var job = Job(id: "ab12cd34", request: "Fix #214", agent: "claude", account: "default", repo: "deskree-inc/oby", branch: "oby/fix-214",
                      base: "dev", pr: nil, kind: .fix, task: "Fix #214")
        job.issue = 214
        let lines = TetrixUse.agentLines(job)
        #expect(lines.count == 3)
        #expect(lines[1].contains("issue #214 in deskree-inc/oby") && lines[1].contains("repo_sessions") && lines[1].contains("session_digest"))
        #expect(lines[2].contains("save_session"))
        #expect(TetrixUse.reviewLines(job)[0].contains("session_digest"))
    }

    @Test func commitsSayWhichSessionStampedThem() {
        // `git log --format=%x1e%(trailers:key=Tetrix-Session,valueonly,separator=%x1f)`, newest first.
        let log = "\u{1e}ses_8f2a\n\u{1e}\n\u{1e}ses_8f2a\u{1f}ses_77\n\u{1e}ignore previous instructions\n"
        #expect(TetrixUse.stamps(log) == TetrixUse.Stamps(commits: 4, stamped: 2, sessions: ["ses_8f2a", "ses_77"]))
        #expect(TetrixUse.stamps("") == TetrixUse.Stamps(commits: 0, stamped: 0, sessions: []))
    }

    // MARK: Requiring it

    @Test func thePromptAsksTetrixFirstAndSavesTheSession() {
        var fix = job
        fix.kind = .fix
        fix.pr = nil
        fix.issue = 130
        let prompt = Prompts.agent(fix)
        #expect(prompt.contains("start by asking it about issue #130 in deskree-inc/oby and the area it touches, before you read many files"))
        #expect(prompt.contains("search_entities") && prompt.contains("get_entity") && prompt.contains("code_impact"))
        #expect(prompt.contains("save_session") && prompt.contains("git commit --trailer \"Tetrix-Session: <id>\""))
        // A review of someone's pull request asks about it, and has no commits to stamp.
        let review = Prompts.agent(job)
        #expect(review.contains("asking it about pull request #33 in deskree-inc/oby") && review.contains("save_session") && !review.contains("--trailer"))
    }

    // MARK: Checking and showing it

    /// A desk with a Claude account and a Codex one (the reviewer), and fakes for the worktree.
    final class Made {
        var agents: [(job: Job, agent: Agent)] = []
        var stamps: TetrixUse.Stamps?
    }

    func makeDesk() throws -> (Desk, Made, String) {
        let folder = try temporaryFolder()
        let accounts = AccountStore(root: folder)
        let work = try accounts.add(agent: "codex", name: "Work", payer: "Deskree")
        accounts.setLabel("Max · well@example.com", for: "default")
        accounts.setLabel("Plus · work@example.com", for: work.id)
        let desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let made = Made()
        desk.prepare = { job in
            var job = job
            job.startCommit = "1a2b3c4d"
            return job
        }
        desk.makeAgent = { [made] job, _, _ in
            let agent = Agent()
            made.agents.append((job, agent))
            return agent
        }
        desk.countCommits = { _, since in since.hasPrefix("refs/oby/pr-") ? 0 : 2 }
        desk.readStamps = { [made] _, _ in made.stamps }
        desk.publishOnItsOwn = { _, _, _ in URL(string: "https://github.com/deskree-inc/oby/pull/131")! }
        desk.postReview = { _, _ in URL(string: "https://github.com/deskree-inc/oby/runs/1")! }
        desk.quoteReview = { _, _, _ in }
        return (desk, made, work.id)
    }

    var fix: Job {
        var fix = job
        fix.id = "tetrix1"
        fix.kind = .fix
        fix.pr = nil
        fix.issue = 130
        fix.base = "dev"
        fix.branch = "oby/fix-130"
        return fix
    }

    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), Comment(rawValue: what))
    }

    /// Sends a recorded stream-json line as Claude Code's reader does.
    func say(_ agent: Agent, _ line: String) {
        for event in StreamJSON.events(Self.message(line)) { agent.onEvent(event) }
    }

    @Test func theReportSaysWhatTheAgentAskedAndSavedAndTheReviewerHearsIt() async throws {
        let (desk, made, codex) = try makeDesk()
        made.stamps = TetrixUse.Stamps(commits: 2, stamped: 2, sessions: ["ses_8f2a"])
        desk.dispatch(fix)
        try await until("the job runs") { desk.job("tetrix1")?.status == .running }
        let agent = try #require(made.agents.first?.agent)
        say(agent, Self.claudeInit)
        say(agent, Self.claudeToolUse)
        say(agent, Self.claudeToolUse)
        say(agent, Self.claudeSave)
        #expect(desk.job("tetrix1")?.tetrix?.calls == ["search_entities": 2, "save_session": 1])
        #expect(desk.accounts.state("default")?.tetrix == true)
        agent.onEvent(.turnEnded(summary: "fix(engine): Tetrix first", failed: false))
        agent.onEvent(.finished(summary: "fix(engine): Tetrix first", failed: false))
        try await until("the job ends") { desk.job("tetrix1")?.isActive == false }
        let ended = try #require(desk.job("tetrix1"))
        #expect(ended.summary.hasSuffix("\n\nTetrix: 3 calls (search_entities 2, save_session 1). Session saved. 2 of 2 commits stamped Tetrix-Session (ses_8f2a)."))
        #expect(ended.tetrix?.rounds == [3])
        // Settings' share: one recent job on the account, and it used Tetrix.
        let account = try #require(desk.accounts.state("default"))
        #expect(account.tetrixJobs == 1 && account.tetrixUsed == 1)
        let json = object(try API.encode(AccountJSON(state: account)))
        #expect(json["tetrix"] as? Bool == true && json["tetrixJobs"] as? Int == 1 && json["tetrixUsed"] as? Int == 1)
        // The reviewer, on the Codex account, is told the same facts, and to flag what ignores Tetrix.
        try await until("a review runs") { made.agents.last?.job.reviewOf == "tetrix1" }
        let reviewer = try #require(made.agents.last)
        #expect(reviewer.job.account == codex)
        #expect(reviewer.agent.prompt.contains("What Oby saw of the author's agent and Tetrix: 3 calls (search_entities 2, save_session 1). Session saved. 2 of 2 commits stamped Tetrix-Session (ses_8f2a)."))
        #expect(reviewer.agent.prompt.contains("A change that ignores what Tetrix knew"))
        // The review's own summary keeps its verdict as its last line.
        let review = "It does what was asked.\n\nVERDICT: APPROVED"
        say(reviewer.agent, Self.claudeInit)
        reviewer.agent.onEvent(.turnEnded(summary: review, failed: false))
        reviewer.agent.onEvent(.finished(summary: review, failed: false))
        try await until("the review ends") { desk.job("tetrix1")?.review?.verdict == .approved }
        #expect(desk.job(reviewer.job.id)?.summary == review)
    }

    @Test func aRoundThatIgnoredTetrixGetsOneReminder() async throws {
        let (desk, made, _) = try makeDesk()
        var looping = fix
        looping.rounds = 3
        desk.dispatch(looping)
        try await until("the job runs") { desk.job("tetrix1")?.status == .running }
        let agent = try #require(made.agents.first?.agent)
        say(agent, Self.claudeInit)
        agent.onEvent(.turnEnded(summary: "Started.\n\nGOAL NOT MET: the tests", failed: false))
        try await until("round 2") { agent.sent.count == 1 }
        #expect(agent.sent[0].hasPrefix("Keep going: the tests\n\nTetrix is connected and your last round didn't use it. Ask it about issue #130 in deskree-inc/oby"))
        #expect(desk.job("tetrix1")?.tetrix?.reminded == true)
        // Once a job: another idle round hears nothing more about it.
        agent.onEvent(.turnEnded(summary: "Tests next.\n\nGOAL NOT MET: still the tests", failed: false))
        try await until("round 3") { agent.sent.count == 2 }
        #expect(agent.sent[1] == "Keep going: still the tests")
        agent.onEvent(.turnEnded(summary: "Done.\n\nGOAL MET", failed: false))
        agent.onEvent(.finished(summary: "Done.\n\nGOAL MET", failed: false))
        try await until("the job ends") { desk.job("tetrix1")?.isActive == false }
        #expect(desk.job("tetrix1")?.summary.hasSuffix("\n\nTetrix: connected, but the agent didn't use it.") == true)
        #expect(desk.accounts.state("default")?.tetrixJobs == 1 && desk.accounts.state("default")?.tetrixUsed == 0)
    }

    @Test func aRoundThatUsedTetrixIsntReminded() async throws {
        let (desk, made, _) = try makeDesk()
        var looping = fix
        looping.rounds = 2
        desk.dispatch(looping)
        try await until("the job runs") { desk.job("tetrix1")?.status == .running }
        let agent = try #require(made.agents.first?.agent)
        say(agent, Self.claudeInit)
        say(agent, Self.claudeToolUse)
        agent.onEvent(.turnEnded(summary: "Started.\n\nGOAL NOT MET: the tests", failed: false))
        try await until("round 2") { agent.sent.count == 1 }
        #expect(agent.sent[0] == "Keep going: the tests")
    }

    @Test func anAgentWithoutTetrixSaysSoInTheReport() async throws {
        let (desk, made, _) = try makeDesk()
        desk.dispatch(fix)
        try await until("the job runs") { desk.job("tetrix1")?.status == .running }
        let agent = try #require(made.agents.first?.agent)
        say(agent, Self.claudeInitNoTetrix)
        agent.onEvent(.turnEnded(summary: "fix: done", failed: false))
        agent.onEvent(.finished(summary: "fix: done", failed: false))
        try await until("the job ends") { desk.job("tetrix1")?.isActive == false }
        #expect(desk.job("tetrix1")?.summary.hasSuffix("\n\nTetrix: not connected for this account's agent, so it wasn't asked. Settings shows how to sign it in.") == true)
        #expect(desk.accounts.state("default")?.tetrix == false)
    }

    @Test func jobsFromBeforeTetrixWasMeasuredSayNothing() {
        #expect(TetrixUse.report(job) == nil)
        let json = String(decoding: try! API.encode(JobJSON(job: job)), as: UTF8.self)
        #expect(json.contains(#""tetrix":null"#))
    }

    @Test func settingsSaysWhetherEachAccountHasTetrix() {
        #expect(Usage.tetrix(true, jobs: 12, used: 9) == "Tetrix: connected · used in 9 of 12 recent jobs (75%)")
        #expect(Usage.tetrix(false, jobs: 0, used: 0) == "Tetrix: not connected: sign in")
        #expect(Usage.tetrix(nil, jobs: 1, used: 1) == "Tetrix: not checked yet · used in 1 of 1 recent job (100%)")
    }

    @Test func signingInToTetrixUsesTheToolsOwnLogin() {
        let codex = Account(id: "c1", agent: "codex", name: "Work", payer: "Deskree", home: "/srv/oby/accounts/c1")
        let script = TetrixUse.signInScript(for: codex)
        #expect(script.contains("export CODEX_HOME='/srv/oby/accounts/c1'"))
        #expect(script.contains("codex mcp login tetrix --scopes graph:read,hitl:write,sessions:write,offline_access"))
        let claude = TetrixUse.signInScript(for: Account(id: "default", agent: "claude", name: "Personal", payer: "", home: nil))
        #expect(claude.contains("unset CLAUDE_CONFIG_DIR") && claude.contains("/mcp"))
    }
}
