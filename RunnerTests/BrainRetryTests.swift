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
        // The real failure repeated on consecutive turns; a third attempt can recover it.
        let cli = CLI([emptyFailure, emptyFailure, good])
        let result = await Shell.$stand.withValue(Shell.Stand(run: { _, _ in await cli.run() })) {
            await Planner(adapters: [brain()]).plan("hello", context: context)
        }
        #expect(await cli.calls == 3)
        #expect(result.by == "claude")
        #expect(result.plan.reply == "Ready")
        #expect(result.refused.isEmpty)
    }

    @Test func exhaustedRetriesKeepExitAndStderrInFallbackEvidence() async {
        let failures = (1...3).map { Shell.Output(status: 15, out: Data(), err: "failure \($0)") }
        let cli = CLI(failures)
        let result = await Shell.$stand.withValue(Shell.Stand(run: { _, _ in await cli.run() })) {
            await Planner(adapters: [brain()]).plan("hello", context: context)
        }
        #expect(await cli.calls == 3)
        #expect(result.by == "rules")
        #expect(result.refused.count == 1)
        for attempt in 1...3 {
            #expect(result.refused[0].contains("attempt \(attempt): exit 15, stderr: failure \(attempt)"))
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
        let cli = CLI([output])
        let error = await Shell.$stand.withValue(Shell.Stand(run: { _, _ in await cli.run() })) {
            await #expect(throws: Shell.Failure.self) {
                try await brain().complete(system: "s", user: "u", schema: Plan.schema(for: context),
                                           timeout: kind == "deadline" ? 1 : 20)
            }
        }
        #expect(await cli.calls == 1)
        #expect(error?.message.contains("stderr: <empty>") == true)
        if kind == "timeout" { #expect(error?.message.contains("timed out") == true) }
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
