import Foundation
import Testing
@testable import Oby

/// Tetrix connected once, on obid, for every agent (docs/runner-api.md, "obid only: Tetrix"): what
/// the Mac reads of it, the only sign-in pages it opens, and what a job's agent did with it.
struct TetrixConnectTests {
    let dogfood = TetrixStatus.Server(preset: "dogfood", name: "Tetrix Dogfood", url: URL(string: "https://mcp.tetrix.dev/mcp")!)

    /// The contract's own example, each state, and a runner that leaves keys out.
    @Test func decodesTheStatus() throws {
        let presets = #""presets": [{"id": "dogfood", "name": "Tetrix Dogfood", "url": "https://mcp.tetrix.dev/mcp"}]"#
        let on = try Runner.decoder.decode(TetrixStatus.self, from: Data(#"""
            {"connected": true, "url": "https://mcp.tetrix.dev/mcp", "preset": "dogfood", \#(presets),
             "scopes": ["graph:read", "sessions:write", "hitl:write", "offline_access"],
             "connectedAt": "2026-10-18T14:02:11Z", "signIn": null, "error": null}
            """#.utf8))
        #expect(on.state == .connected(dogfood) && on.how == "Signed in to Tetrix Dogfood. Every agent on every account uses it.")
        let ready = try Runner.decoder.decode(TetrixStatus.self, from: Data(#"{"connected": false, "url": null, "preset": null, \#(presets)}"#.utf8))
        #expect(ready.state == .available && ready.presets == [dogfood] && ready.server == nil)
        let signing = try Runner.decoder.decode(TetrixStatus.self, from: Data(#"""
            {"connected": false, "url": "https://tetrix.example.com/mcp", "preset": null, \#(presets),
             "signIn": {"url": "https://auth.example.com/authorize?state=x", "expiresAt": "2026-10-18T22:00:00Z"}}
            """#.utf8))
        #expect(signing.state == .signingIn(TetrixStatus.Server(preset: nil, name: "tetrix.example.com", url: URL(string: "https://tetrix.example.com/mcp")!)))
        let signedOut = try Runner.decoder.decode(TetrixStatus.self, from: Data(#"{"connected": false, "url": "https://mcp.tetrix.dev/mcp", "preset": "dogfood", "error": "Tetrix signed Oby out: sign in again."}"#.utf8))
        #expect(signedOut.state == .available && signedOut.how == "Tetrix signed Oby out: sign in again.")
        #expect(try Runner.decoder.decode(TetrixStatus.self, from: Data("{}".utf8)) == TetrixStatus())
    }

    /// The Mac opens a sign-in page only over https, with no login in it, on the server's host or one
    /// under its parent domain (its authorization server's).
    @Test func opensOnlyTheServersOwnPage() {
        let page = { (text: String) in TetrixSignIn(url: URL(string: text)!).opens(for: dogfood) }
        #expect(page("https://mcp.tetrix.dev/oauth/authorize?client_id=obid"))
        #expect(page("https://auth.tetrix.dev/authorize") && page("https://tetrix.dev/authorize") && page("https://MCP.Tetrix.dev/a"))
        #expect(!page("http://mcp.tetrix.dev/authorize"))
        #expect(!page("https://evil.example.com/authorize"))
        #expect(!page("https://tetrix.dev.evil.example.com/authorize") && !page("https://eviltetrix.dev/authorize"))
        #expect(!page("https://user:pass@auth.tetrix.dev/authorize"))
        #expect(!page("file:///etc/passwd") && !page("javascript:alert(1)"))
        // A server on a two-label host allows only that host and what's under it.
        let bare = TetrixStatus.Server(preset: nil, name: "t", url: URL(string: "https://tetrix.dev/mcp")!)
        #expect(TetrixSignIn(url: URL(string: "https://auth.tetrix.dev/a")!).opens(for: bare))
        #expect(!TetrixSignIn(url: URL(string: "https://other.dev/a")!).opens(for: bare))
        let plain = TetrixStatus.Server(preset: nil, name: "x", url: URL(string: "http://mcp.tetrix.dev/mcp")!)
        #expect(!TetrixSignIn(url: URL(string: "https://mcp.tetrix.dev/a")!).opens(for: plain))
    }

    /// Another Tetrix takes what obid takes (https, a host, no login, query or fragment), named by its host.
    @Test func anotherTetrixsAddress() {
        #expect(TetrixStatus.isServerURL("https://tetrix.example.com/mcp") && TetrixStatus.isServerURL("  https://t.example.com  "))
        for bad in ["", "https://", "http://tetrix.example.com/mcp", "tetrix.example.com", "https://me:secret@tetrix.example.com/mcp",
                    "https://tetrix.example.com/mcp?token=x", "https://tetrix.example.com/mcp#a"] {
            #expect(!TetrixStatus.isServerURL(bad), "\(bad)")
        }
        #expect(TetrixStatus.custom("https://tetrix.example.com/mcp") == .init(preset: nil, name: "tetrix.example.com", url: URL(string: "https://tetrix.example.com/mcp")!))
    }

    /// A job's `tetrix` as obid fills it, read with the job's other extras, never failing the job; an
    /// older runner's stamped sessions stand for `saved`.
    @Test func readsWhatAJobDidWithTetrix() throws {
        let jobs = #"""
            [{"id": "j1", "tetrix": {"connected": true, "calls": {"search_entities": 2, "get_entity": 1, "save_session": 1}, "rounds": null,
              "reminded": null, "stamps": {"commits": 2, "stamped": 2, "sessions": ["8f2a"]}, "author": null, "context": true, "saved": ["8f2a"],
              "gaps": {"noResults": ["acme/shop#12"], "missing": ["repo:acme/legacy"], "unknownFiles": ["src/new.rs"],
                       "failed": [{"tool": "code_impact", "error": "Tetrix said: timeout"}],
                       "sent": "2026-10-18T14:40:02Z", "session": "c41d", "notSent": null}}},
             {"id": "j2", "tetrix": {"connected": true, "calls": {}, "stamps": {"commits": 1, "stamped": 1, "sessions": ["old"]}}},
             {"id": "j3", "tetrix": "not an object"},
             {"id": "j4", "tetrix": {"calls": {"get_entity": 1}, "gaps": {"noResults": [], "notSent": "The secret scan found something."}}}]
            """#
        let extras = RunnerJobExtras.of(Data(jobs.utf8))
        let report = try #require(extras["j1"]?.tetrix)
        #expect(report.callsLine == "Asked Tetrix 4 times: search_entities 2, get_entity 1, save_session 1")
        #expect(report.context == true && report.saved == ["8f2a"])
        #expect(report.gaps?.lines == ["No results: acme/shop#12", "Not in the graph: repo:acme/legacy", "A file it didn't know: src/new.rs",
                                       "code_impact failed: Tetrix said: timeout"])
        #expect(report.gaps?.sentLine == "Sent to Tetrix as session c41d")
        #expect(extras["j2"]?.tetrix?.saved == ["old"] && extras["j2"]?.tetrix?.callsLine == "Had Tetrix, but didn't ask it anything")
        #expect(extras["j3"] != nil && extras["j3"]?.tetrix == nil)
        let notSent = try #require(extras["j4"]?.tetrix)
        #expect(notSent.callsLine == "Asked Tetrix once: get_entity 1" && notSent.gaps?.isEmpty == true)
        #expect(notSent.gaps?.sentLine == "Not sent to Tetrix: The secret scan found something.")
        #expect(TetrixJobReport().isEmpty && !report.isEmpty)
    }

    /// Each account's line once obid holds Tetrix: how many of its jobs used it, or where to connect it.
    @Test func accountLine() {
        #expect(TetrixJobReport.accountLine(connected: true, jobs: 12, used: 9, there: "in Connectors") == "Tetrix: used in 9 of 12 jobs")
        #expect(TetrixJobReport.accountLine(connected: true, jobs: 1, used: 0, there: "in Connectors") == "Tetrix: used in 0 of 1 job")
        #expect(TetrixJobReport.accountLine(connected: true, jobs: 0, used: 0, there: "in Connectors") == "Tetrix: connected")
        #expect(TetrixJobReport.accountLine(connected: false, jobs: 3, used: 3, there: "on your Mac") == "Tetrix: not connected: connect it on your Mac")
    }

    /// The fake obid: the Mac asks for the status, starts a preset's sign-in by its id and another
    /// Tetrix's by its address, cancels and disconnects; a runner without Tetrix (404) is nil.
    @Test func talksToObid() async throws {
        let obid = RunnerStub { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/tetrix"): (200, #"{"connected": false, "presets": [{"id": "dogfood", "name": "Tetrix Dogfood", "url": "https://mcp.tetrix.dev/mcp"}]}"#)
            case ("POST", "/v1/tetrix/sign-in"): (200, #"{"url": "https://auth.tetrix.dev/authorize?state=s", "expiresAt": "2026-10-18T22:00:00Z"}"#)
            case ("DELETE", "/v1/tetrix/sign-in"), ("DELETE", "/v1/tetrix"): (204, "")
            default: (404, "")
            }
        }
        #expect(try await obid.runner.tetrix()?.presets == [dogfood])
        let signIn = try await obid.runner.startTetrixSignIn(dogfood)
        #expect(signIn.opens(for: dogfood) && obid.requests.last?.json as? [String: String] == ["preset": "dogfood"])
        let other = try #require(TetrixStatus.custom("https://tetrix.example.com/mcp"))
        _ = try await obid.runner.startTetrixSignIn(other)
        #expect(obid.requests.last?.json as? [String: String] == ["url": "https://tetrix.example.com/mcp"])
        try await obid.runner.cancelTetrixSignIn()
        try await obid.runner.disconnectTetrix()
        #expect(obid.requests.suffix(2).map { "\($0.method) \($0.path)" } == ["DELETE /v1/tetrix/sign-in", "DELETE /v1/tetrix"])
        #expect(try await RunnerStub { _ in (404, "") }.runner.tetrix() == nil)
    }
}
