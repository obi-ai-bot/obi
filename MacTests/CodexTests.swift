import Foundation
import Testing
@testable import Oby

/// Lines as `codex app-server` 0.155.1 sent them on 2026-10-09 (trimmed; the probe's folder is
/// now /tmp/oby/jobs/abc).
struct CodexTests {
    let worktree = URL(filePath: "/tmp/oby/jobs/abc")

    func message(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    @Test func threadStartKeepsCommitsInTheSandbox() {
        let params = CodexRPC.threadStart(worktree: worktree, git: "/tmp/oby/repos/deskree-inc/oby/.git")
        #expect(params["cwd"] as? String == "/tmp/oby/jobs/abc")
        #expect(params["sandbox"] as? String == "workspace-write")
        #expect(params["approvalPolicy"] as? String == "on-request" && params["approvalsReviewer"] as? String == "user")
        let sandbox = (params["config"] as? [String: Any])?["sandbox_workspace_write"] as? [String: Any]
        #expect(sandbox?["writable_roots"] as? [String] == ["/tmp/oby/repos/deskree-inc/oby/.git"])
        #expect(sandbox?["network_access"] as? Bool == false)
        let plain = CodexRPC.threadStart(worktree: worktree, git: nil)
        #expect(plain["config"] == nil && plain["sandbox"] as? String == "workspace-write")
    }

    /// Permission modes (#134) on the Mac: Bypass keeps Codex's own sandbox answering, the others
    /// send every command and file change to Oby, and Plan runs read-only.
    @Test func threadStartFollowsTheMode() {
        let git = "/tmp/oby/repos/deskree-inc/oby/.git"
        #expect(CodexRPC.threadStart(worktree: worktree, git: git, mode: .bypass)["approvalPolicy"] as? String == "on-request")
        for mode in [PermissionMode.ask, .acceptEdits] {
            let params = CodexRPC.threadStart(worktree: worktree, git: git, mode: mode)
            #expect(params["approvalPolicy"] as? String == "untrusted" && params["sandbox"] as? String == "workspace-write", "\(mode)")
        }
        let plan = CodexRPC.threadStart(worktree: worktree, git: git, mode: .plan)
        #expect(plan["sandbox"] as? String == "read-only" && plan["approvalPolicy"] as? String == "untrusted")
        let approval = message(#"{"id": 3, "method": "item/commandExecution/requestApproval", "params": {"threadId": "t", "turnId": "u", "command": "/bin/zsh -lc 'swift test'"}}"#)
        #expect(CodexRPC.call(approval, files: [:]) == ToolCall(request: "3", tool: "Bash", command: "swift test"))
        #expect(PermissionPolicy.decide(ToolCall(request: "3", tool: "Bash", command: "swift test"), mode: .ask, rules: [], worktree: worktree) == .ask)
    }

    @Test func commandSteps() {
        let cat = message(#"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"exec-c7d8352a","command":"/bin/zsh -lc 'cat hello.txt'","cwd":"/tmp/oby/jobs/abc","status":"inProgress","commandActions":[{"type":"read","command":"cat hello.txt","name":"hello.txt","path":"/tmp/oby/jobs/abc/hello.txt"}]},"threadId":"01a1228b-a556","turnId":"01a1228b-a5fb"}}"#)
        #expect(CodexRPC.events(cat) == [.step("Reading hello.txt")])
        let status = message(#"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"exec-9303d952","command":"/bin/zsh -lc 'git status'","cwd":"/tmp/oby/jobs/abc","source":"agent","status":"inProgress","commandActions":[{"type":"unknown","command":"git status"}]},"threadId":"01a1228d-573f","turnId":"01a1228d-57d2"}}"#)
        #expect(CodexRPC.events(status) == [.step("Running git status")])
        #expect(CodexRPC.command("/bin/zsh -lc 'pnpm test && echo '\\''done'\\'''") == "pnpm test && echo 'done'")
        #expect(CodexRPC.command("ls") == "ls")
    }

    @Test func fileChangeStep() throws {
        let started = message(#"{"method":"item/started","params":{"item":{"type":"fileChange","id":"exec-4c792341","changes":[{"path":"/tmp/oby/jobs/abc/hello.txt","kind":{"type":"add"},"diff":"hi\n"}],"status":"inProgress"},"threadId":"01a1228b-a556","turnId":"01a1228b-a5fb"}}"#)
        #expect(CodexRPC.events(started) == [.step("Editing hello.txt")])
        let change = try #require(CodexRPC.changes(started))
        #expect(change.item == "exec-4c792341" && change.files == ["/tmp/oby/jobs/abc/hello.txt"])
        let moved = message(#"{"method":"item/fileChange/patchUpdated","params":{"threadId":"t","turnId":"u","itemId":"exec-4c792341","changes":[{"path":"/tmp/oby/jobs/abc/a.ts","kind":{"type":"update","move_path":"/tmp/oby/jobs/abc/b.ts"},"diff":""}]}}"#)
        #expect(CodexRPC.changes(moved)?.files == ["/tmp/oby/jobs/abc/a.ts", "/tmp/oby/jobs/abc/b.ts"])
    }

    @Test func rateLimits() {
        let update = message(#"{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":8,"windowDurationMins":300,"resetsAt":1791593680},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1792001242},"planType":"plus"}}}"#)
        #expect(CodexRPC.events(update) == [.usage(fiveHour: 0.08, sevenDay: 0.4, fiveHourResets: Date(timeIntervalSince1970: 1_791_593_680),
                                                   sevenDayResets: Date(timeIntervalSince1970: 1_792_001_242))])
        let reserve = message(#"{"limitId":"base_model_inference","limitName":"gpt-reserve","primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1791760565},"secondary":null}"#)
        #expect(CodexRPC.usage(reserve) == nil)
    }

    @Test func turnCompleted() {
        let done = message(#"{"method":"turn/completed","params":{"threadId":"01a1228b-a556","turn":{"id":"01a1228b-a5fb","items":[{"type":"agentMessage","id":"msg_02ac","text":"ok","phase":"final_answer"}],"itemsView":"summary","status":"completed","error":null}}}"#)
        #expect(CodexRPC.events(done) == [.finished(summary: "ok", failed: false)])
        let failed = message(#"{"method":"turn/completed","params":{"threadId":"01a1228b-2016","turn":{"id":"01a1228b-213b","items":[],"itemsView":"notLoaded","status":"failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.\"}}","codexErrorInfo":"other"}}}}"#)
        #expect(CodexRPC.events(failed) == [.finished(summary: "Codex hit an error: The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.", failed: true)])
        let interrupted = message(#"{"method":"turn/completed","params":{"threadId":"01a1228d-573f","turn":{"id":"01a1228d-7d4d","items":[],"itemsView":"notLoaded","status":"interrupted","error":null}}}"#)
        #expect(CodexRPC.events(interrupted) == [.finished(summary: "Stopped.", failed: true)])
    }

    @Test func approvalsGoThroughPolicy() {
        let push = message(#"{"method":"item/commandExecution/requestApproval","id":0,"params":{"kind":"command","threadId":"01a1228c-479b","turnId":"01a1228c-483b","itemId":"exec-5eb53210","environmentId":"local","reason":"probe","command":"/bin/zsh -lc 'git push origin main'","cwd":"/tmp/oby/jobs/abc","commandActions":[{"type":"unknown","command":"git push origin main"}],"proposedExecpolicyAmendment":["git","push","origin","main"],"availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["git","push","origin","main"]}},"cancel"]}}"#)
        guard case .decline(let reason) = CodexRPC.answer(push, files: [:], worktree: worktree) else { Issue.record("git push was approved"); return }
        #expect(reason.contains("Oby publishes the job's branch itself"))
        let status = message(#"{"method":"item/commandExecution/requestApproval","id":0,"params":{"kind":"command","threadId":"01a1228d-573f","turnId":"01a1228d-57d2","itemId":"exec-9303d952","environmentId":"local","reason":"probe","command":"/bin/zsh -lc 'git status'","cwd":"/tmp/oby/jobs/abc","commandActions":[{"type":"unknown","command":"git status"}],"proposedExecpolicyAmendment":["git","status"],"availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["git","status"]}},"cancel"]}}"#)
        #expect(CodexRPC.answer(status, files: [:], worktree: worktree) == .accept)
    }

    @Test func fileApprovalsStayInTheWorktree() {
        let request = message(#"{"method":"item/fileChange/requestApproval","id":1,"params":{"threadId":"01a1228c-479b","turnId":"01a1228c-483b","itemId":"exec-6360f4de","reason":null,"grantRoot":null}}"#)
        #expect(CodexRPC.answer(request, files: ["exec-6360f4de": ["/Users/someone/oby-probe-outside.txt"]], worktree: worktree) != .accept)
        #expect(CodexRPC.answer(request, files: ["exec-6360f4de": ["/tmp/oby/jobs/abc/src/a.ts"]], worktree: worktree) == .accept)
        #expect(CodexRPC.answer(request, files: [:], worktree: worktree) != .accept)
    }

    @Test func otherRequestsAreNotApprovals() {
        let question = message(#"{"method":"item/tool/requestUserInput","id":2,"params":{"threadId":"t","turnId":"u","itemId":"i","questions":[]}}"#)
        #expect(CodexRPC.answer(question, files: [:], worktree: worktree) == nil)
    }

    @Test func account() {
        #expect(CodexRPC.account(message(#"{"account":{"type":"chatgpt","email":"name@example.com","planType":"plus"},"requiresOpenaiAuth":true}"#)) == "Plus · name@example.com")
        #expect(CodexRPC.account(message(#"{"account":null,"requiresOpenaiAuth":true}"#)) == nil)
    }
}

struct ModelsTests {
    @Test func defaultsAreOpusExtraHighAndSol61High() {
        #expect(AgentModels.defaults["claude.model"] == "claude-opus-5-5")
        #expect(AgentModels.defaults["claude.effort"] == "xhigh")
        #expect(AgentModels.defaults["codex.model"] == "gpt-6.1-sol")
        #expect(AgentModels.defaults["codex.effort"] == "high")
        #expect(AgentModels.effortName("xhigh") == "Extra high")
    }

    @Test func turnStartCarriesModelAndEffort() {
        let params = CodexRPC.turnStart(thread: "t", prompt: "hi", model: "gpt-6-sol", effort: "high")
        #expect(params["model"] as? String == "gpt-6-sol")
        #expect(params["effort"] as? String == "high")
        #expect(CodexRPC.turnStart(thread: "t", prompt: "hi", model: "", effort: "")["model"] == nil)
    }

    /// `model/list` as codex 0.155.1 answered on 2026-10-09 (trimmed).
    @Test func modelList() {
        let result: [String: Any] = ["data": [
            ["id": "gpt-6-astra", "displayName": "GPT-6-Astra", "supportedReasoningEfforts": ["low", "high"]],
            ["id": "gpt-6-sol", "displayName": "GPT-6-Sol", "supportedReasoningEfforts": [["reasoningEffort": "high"]]],
        ]]
        #expect(CodexRPC.models(result) == [CodexModel(id: "gpt-6-astra", name: "GPT-6-Astra", efforts: ["low", "high"]),
                                            CodexModel(id: "gpt-6-sol", name: "GPT-6-Sol", efforts: ["high"])])
    }
}
