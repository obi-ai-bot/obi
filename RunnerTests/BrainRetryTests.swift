import Foundation
import Testing
@testable import ObyEngine

struct BrainRetryTests {
    private let context = BrainContext(accounts: ["claude": ["default"]], repos: ["deskree-inc/oby"])
    private let good = Shell.Output(status: 0, out: Data(#"{"structured_output":{"action":"reply_only","reply":"Ready","dispatches":[],"question":null}}"#.utf8), err: "")
    private let emptyFailure = Shell.Output(status: 15, out: Data(), err: "")

    private actor CLI {
        var outputs: [Shell.Output]
        var calls = 0
        init(_ outputs: [Shell.Output]) { self.outputs = outputs }
        func run() -> Shell.Output {
            calls += 1
            return outputs.removeFirst()
        }
    }

    private func brain() -> ClaudeBrain {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-brain-test-\(UUID().uuidString)/vault")
        return ClaudeBrain(vault: Vault(store: FileVault(folder: folder)))
    }

    @Test func emptyExit15RecoversBeforeRulesPlan() async {
        // One transient failure can recover on the one retry.
        let cli = CLI([emptyFailure, good])
        let result = await Shell.$stand.withValue(Shell.Stand(run: { _, _ in await cli.run() })) {
            await Planner(adapters: [brain()]).plan("hello", context: context)
        }
        #expect(await cli.calls == 2)
        #expect(result.by == "claude")
        #expect(result.plan.reply == "Ready")
        #expect(result.refused.isEmpty)
    }

    @Test func exhaustedRetriesKeepExitAndStderrInFallbackEvidence() async {
        let failures = (1...2).map { Shell.Output(status: 15, out: Data(), err: "failure \($0)") }
        let cli = CLI(failures)
        let result = await Shell.$stand.withValue(Shell.Stand(run: { _, _ in await cli.run() })) {
            await Planner(adapters: [brain()]).plan("hello", context: context)
        }
        #expect(await cli.calls == 2)
        #expect(result.by == "rules")
        #expect(result.refused.count == 1)
        for attempt in 1...2 {
            #expect(result.refused[0].contains("attempt \(attempt): exit code 15, stderr: failure \(attempt)"))
        }
    }

    @Test(arguments: ["success", "auth", "timeout", "deadline"])
    func retriesAreLimitedToTransientEmptyFailures(kind: String) async throws {
        var output = emptyFailure
        switch kind {
        case "success": output.status = 0
        case "auth": output.out = Data("Please sign in".utf8)
        case "timeout": output.timedOut = true
        default: break
        }
        let cli = CLI([output, output])
        let error = await Shell.$stand.withValue(Shell.Stand(run: { _, _ in await cli.run() })) {
            await #expect(throws: Shell.Failure.self) {
                try await brain().complete(system: "s", user: "u", schema: Plan.schema(for: context),
                                           timeout: kind == "deadline" ? 1 : 20)
            }
        }
        if kind != "deadline" { #expect(await cli.calls == 2) }
        #expect(error?.message.contains("stderr: <empty>") == true)
        if kind == "timeout" { #expect(error?.message.contains("timeout") == true) }
    }

    /// A fake `claude` that plays Claude Code's turns with --json-schema: each step is one model
    /// request, a StructuredOutput call that misses the schema goes back to the model as a tool
    /// error, and --max-turns is checked before every request, the one that follows the last tool
    /// result too. Read + one invalid StructuredOutput + the valid one is four requests.
    private actor TurnCLI {
        enum Step { case read, invalid, valid }
        let steps: [Step]
        var inputs: [String] = []
        var maxTurns: [Int?] = []
        init(_ steps: [Step]) { self.steps = steps }

        func run(_ argv: [String], _ call: Shell.Call?) -> Shell.Output {
            inputs.append(String(decoding: call?.input ?? Data(), as: UTF8.self))
            let limit = argv.firstIndex(of: "--max-turns").flatMap { Int(argv[$0 + 1]) }
            maxTurns.append(limit)
            var turn = 0
            var plan: String?
            for step in steps + [nil] {
                turn += 1
                if let limit, turn > limit {
                    return Shell.Output(status: 1, out: Data(#"{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":\#(turn - 1)}"#.utf8), err: "")
                }
                switch step {
                case .read:
                    // The quoted file is really there to read, and Read is allowed.
                    guard argv.contains("Read"), let directory = call?.directory,
                          (try? String(contentsOf: directory.appending(path: ClaudeBrain.quotedFile), encoding: .utf8)) != nil else {
                        return Shell.Output(status: 1, out: Data(#"{"type":"result","subtype":"error_during_execution","is_error":true}"#.utf8), err: "no work.md")
                    }
                case .invalid: continue
                case .valid: plan = #"{"action":"reply_only","reply":"Ready","dispatches":[],"question":null}"#
                case nil: break
                }
            }
            guard let plan else { return Shell.Output(status: 0, out: Data(#"{"type":"result","subtype":"success"}"#.utf8), err: "") }
            return Shell.Output(status: 0, out: Data(#"{"type":"result","subtype":"success","structured_output":\#(plan)}"#.utf8), err: "")
        }
    }

    @Test func readAndFixingTheJsonFitsInTheTurns() async throws {
        let cli = TurnCLI([.read, .invalid, .valid])
        let data = try await Shell.$stand.withValue(Shell.Stand(run: { argv, _ in await cli.run(argv, Shell.call) })) {
            try await brain().complete(system: "s", user: "u", quoted: "the job's result", schema: Plan.schema(for: context), timeout: 20)
        }
        #expect(try Plan.decode(data).reply == "Ready")
        #expect(await cli.maxTurns == [6])
    }

    @Test func runningOutOfTurnsIsRetriedOnceThenTheNextAdapterPlans() async {
        struct Next: BrainAdapter {
            let name = "codex"
            func complete(system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data {
                Data(#"{"action":"reply_only","reply":"From Codex","dispatches":[],"question":null}"#.utf8)
            }
        }
        // A model that keeps reading never answers.
        let cli = TurnCLI(Array(repeating: .read, count: 20))
        var quoted = context
        quoted.quoted = "the job's result"
        let result = await Shell.$stand.withValue(Shell.Stand(run: { argv, _ in await cli.run(argv, Shell.call) })) {
            await Planner(adapters: [brain(), Next()]).plan("what did the job find?", context: quoted)
        }
        let inputs = await cli.inputs
        #expect(inputs.count == 2)
        let hint = "Your last attempt ran out of turns: read only what you need, then answer."
        #expect(inputs.first?.contains(hint) == false)
        #expect(inputs.last?.contains(hint) == true)
        #expect(result.by == "codex")
        #expect(result.plan.reply == "From Codex")
        #expect(result.refused.count == 1)
        for attempt in 1...2 {
            #expect(result.refused.first?.contains("attempt \(attempt): error_max_turns") == true)
        }
    }

    @Test func cancellationDoesNotRestartClaude() async throws {
        let cli = CLI([emptyFailure])
        let task = Task {
            try await Shell.$stand.withValue(Shell.Stand(run: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return await cli.run()
            })) {
                try await brain().complete(system: "s", user: "u", schema: Plan.schema(for: context), timeout: 20)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await cli.calls == 1)
    }
}
