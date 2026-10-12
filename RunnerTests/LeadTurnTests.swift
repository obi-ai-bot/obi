import Foundation
import Testing
@testable import ObyEngine
@testable import oby_runner

/// One `ClaudeLead` turn (#226): enough turns for a post-mortem that reads Oby's source, and an
/// error that says why claude stopped when there's no plan, from the reply on stdout.
struct LeadTurnTests {
    @Test func theTurnGetsTwentyFourTurnsUnlessTheCallerLowersIt() {
        let directory = URL(filePath: "/tmp/oby-lead-turn")
        let argv = ClaudeLead(model: Lead.provenModel).arguments(system: "Lead.", schema: Data("{}".utf8), in: directory)
        #expect(argv.contains(["--max-turns", "24"]))
        #expect(!argv.contains(["--max-turns", "8"]))
        let lowered = ClaudeLead(model: Lead.provenModel, maxTurns: 5).arguments(system: "Lead.", schema: Data("{}".utf8), in: directory)
        #expect(lowered.contains(["--max-turns", "5"]))
    }

    @Test func runningOutOfTurnsIsNamedEvenWithNothingOnStderr() {
        let reply = #"{"is_error":true,"subtype":"error_max_turns","errors":["Reached maximum number of turns (8)"]}"#
        let output = Shell.Output(status: 1, out: Data(reply.utf8), err: "")
        #expect(throws: Shell.Failure.self) { try ClaudeLead.plan(from: output) }
        let message = failure(output)
        #expect(message.contains("error_max_turns"))
        #expect(message == "claude returned no plan (exit 1, error_max_turns: Reached maximum number of turns (8))")
    }

    @Test func theReplysResultIsCutAndStderrStillCounts() {
        let long = String(repeating: "x", count: 500)
        let reply = #"{"is_error":true,"subtype":"error_during_execution","result":"\#(long)"}"#
        let message = failure(Shell.Output(status: 1, out: Data(reply.utf8), err: "boom\n"))
        #expect(message.hasPrefix("claude returned no plan (exit 1, error_during_execution, result: xxx"))
        #expect(message.hasSuffix("…): boom"))
        #expect(message.count < 300)
        // No JSON at all: the exit and stderr, as before.
        #expect(failure(Shell.Output(status: 2, out: Data(), err: "not logged in")) == "claude returned no plan (exit 2): not logged in")
    }

    @Test func aStructuredPlanIsTheAnswer() throws {
        let reply = #"{"subtype":"success","structured_output":{"action":"reply"}}"#
        let data = try ClaudeLead.plan(from: Shell.Output(status: 0, out: Data(reply.utf8), err: ""))
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: String]) == ["action": "reply"])
    }

    private func failure(_ output: Shell.Output) -> String {
        do {
            _ = try ClaudeLead.plan(from: output)
            return ""
        } catch {
            return error.localizedDescription
        }
    }
}
