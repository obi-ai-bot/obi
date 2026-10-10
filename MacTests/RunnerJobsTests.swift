import Foundation
import Testing
@testable import Oby

/// The Mac reads the runner's jobs with the iPhone's client (Shared/Runner.swift) into Engine's Job.
struct RunnerJobsTests {
    /// Two jobs from tetrix-lab's GET /v1/jobs on 2026-10-10, as it sent them (the second summary cut short).
    let jobs = #"[{"account":"default","agent":"claude","base":"dev","branch":"oby/investigate-4bbb14","check":null,"commits":0,"created":"2026-10-10T00:04:01Z","finished":"2026-10-10T00:04:45Z","id":"4bbb145a","issue":null,"kind":"investigate","model":null,"notes":["In one sentence: which Tetrix tool did you call?"],"pr":null,"published":null,"repo":"deskree-inc/oby","request":"investigate oby: use the Tetrix MCP to find what it knows about the deskree-inc/oby repository, answer in two sentences, change nothing","round":2,"rounds":1,"session":"862ca2c8-5263-4eb8-9862-56a5f6ca1821","started":"2026-10-10T00:04:02Z","status":"done","step":"","summary":"I called four Tetrix tools, not one: `search_entities` to find the repo, `operational_context` for deploy, ownership and cost links, `query_graph` to count its nodes by type, and `get_entity` for the repo's details.","task":"Use the Tetrix MCP to find what it knows about the deskree-inc/oby repository. Answer the user in exactly two sentences. Change nothing: do not edit files, commit, push, or open or modify any PR or issue."},{"account":"default","agent":"claude","base":"dev","branch":"oby/investigate-e4ea28","check":null,"commits":0,"created":"2026-10-09T22:59:06Z","finished":"2026-10-09T22:59:21Z","id":"e4ea28be","issue":null,"kind":"investigate","model":null,"notes":null,"pr":null,"published":null,"repo":"deskree-inc/oby","request":"In oby, count the Swift files in Engine/ and tell me in one line","round":1,"rounds":1,"session":"c2f11b7a-f4c7-4c20-81d5-d5fb20654965","started":"2026-10-09T22:59:14Z","status":"done","step":"","summary":"There are 8 Swift files in `Engine/`.\n\nI ran `find Engine -type f -name '*.swift'` and it printed 8.","task":"Count the number of Swift files (.swift) in the Engine/ directory"}]"#

    @Test func capturedJobsDecode() throws {
        let decoded = try Runner.decoder.decode([Job].self, from: Data(jobs.utf8))
        #expect(decoded.map(\.id) == ["4bbb145a", "e4ea28be"])
        #expect(decoded[0].kind == .investigate && decoded[0].status == .done && !decoded[0].canPublish)
        #expect(decoded[0].notes == ["In one sentence: which Tetrix tool did you call?"])
        #expect(decoded[0].finished == ISO8601DateFormatter().date(from: "2026-10-10T00:04:45Z"))
        #expect(decoded[1].heading == "In oby, count the Swift files in Engine/ and tell me in one line".prefix(59) + "…")
        #expect(decoded[1].doneLine == "There are 8 Swift files in `Engine/`.")

        // The tag's name; the Mac skips the runner's accounts, which aren't Engine's.
        let status = #"{"accounts":[{"agent":"claude","fiveHour":0.53,"id":"default","label":"Team","name":"Deskree","running":0,"sevenDay":0.09,"signedIn":true}],"models":{"claude":{"effort":"xhigh","model":"claude-opus-5-5"},"codex":{"effort":"high","model":"gpt-6.1-sol"}},"runner":{"host":"tetrix-lab","version":"0.2.0"}}"#
        #expect(try Runner.decoder.decode(RunnerStatus.self, from: Data(status.utf8)).runner.host == "tetrix-lab")
    }
}
