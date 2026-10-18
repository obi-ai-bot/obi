import Foundation
import Testing
import WebKit
@testable import Oby

/// The conversation harness on the Mac (docs/conversation-harness.md, step 3): the feed's events
/// reach the thread (words as they're written, tool lines, artifacts, a job's card lines), and
/// the artifact viewer's web view keeps to the client contract on macOS. The rest of the cases
/// are in apps/ios/tests/HarnessTests.swift; apps/shared/ is one code.
@MainActor
struct MacHarnessTests {
    func event(_ name: String, _ json: String) -> RunnerEvent? {
        var parser = EventParser()
        for line in ["event: \(name)", "data: \(json)"] { #expect(parser.feed(line) == nil) }
        return parser.feed("")
    }

    @Test func harnessEventsReachTheThread() throws {
        let model = ConversationModel()
        guard case .delta(let delta)? = event("delta", #"{"conversation":"c1","turn":"u1","text":"Reading it now."}"#),
              case .step(let step)? = event("step", #"{"turn":"u1","index":1,"action":"tool","text":"Reading the web","tool":"web_search","detail":"obid csp","state":"running"}"#),
              case .artifact(let artifact)? = event("artifact", #"{"id":"a1","version":1,"title":"Plan","kind":"markdown","conversation":"c1","job":null}"#),
              case .turn(let turn, let extras)? = event("turn", #"{"id":"o1","who":"oby","text":"Reading it now.","at":"2026-10-17T09:12:09Z","artifacts":[{"id":"a1","version":1}]}"#)
        else { Issue.record("an event wasn't read"); return }
        let asked = Turn(id: "u1", who: .user, text: "Look it up")
        model.apply(asked)
        model.apply(delta)
        model.apply(step)
        #expect(model.streamed(under: asked, in: [asked])?.text == "Reading it now.")
        #expect(ToolLine.text(model.steps["u1"]![0]) == "Searching the web for “obid csp”" && ToolLine.folded(model.steps["u1"]!, words: true))
        model.apply(artifact)
        model.apply(turn, extras)
        model.settleLatestSteps()
        #expect(model.streamed.isEmpty && model.artifactRefs(of: turn) == [ArtifactRef(id: "a1", version: 1)])
        #expect(model.artifacts["a1"]?.kindName == "Document" && ToolLine.folded(model.steps["u1"]!))
        // The Mac's job reads its artifacts with what Engine's Job doesn't.
        let job = #"[{"id":"j1","artifacts":[{"id":"a9","version":2}],"mode":"ask"}]"#
        #expect(RunnerJobExtras.of(Data(job.utf8))["j1"]?.artifacts == [ArtifactRef(id: "a9", version: 2)])
    }

    @Test func aJobsCardOnTheMac() throws {
        let wire = #"{"id": "j1", "request": "Fix it", "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/fix-1", "kind": "fix", "task": "Fix it", "status": "done", "step": "", "summary": "Fixed.", "created": "2026-10-17T09:00:00Z", "published": "https://github.com/deskree-inc/oby/pull/7"}"#
        let job = try Runner.decoder.decode(Job.self, from: Data(wire.utf8))
        #expect(job.outcome == JobOutcome(text: "Pull request #7", link: URL(string: "https://github.com/deskree-inc/oby/pull/7"), failed: false))
        var running = job
        running.status = .running
        running.step = "Running swift test"
        #expect(running.liveLine?.hasSuffix(" · Running swift test") == true && running.agentLine == "Claude Code · Running swift test")
    }

    /// The same finding as on the iPhone, on macOS's WebKit: the page's own CSS and scripts under
    /// obid's policy through the scheme handler, an opaque origin, no fetch, no navigating away.
    @Test func aPageRunsItsOwnFilesUnderObidsPolicyOnTheMac() async throws {
        let ref = ArtifactRef(id: "a1", version: 1)
        let handler = ArtifactSchemeHandler(ref: ref) { ArtifactFixture.answer($0) }
        var links: [URL] = []
        let gate = ArtifactLinkGate()
        gate.ask = { links.append($0) }
        let navigation = ArtifactNavigation(ref: ref, links: gate)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: ArtifactWeb.configuration(handler))
        web.navigationDelegate = navigation
        web.load(URLRequest(url: ArtifactPage.url(ref, path: "index.html")!))
        let seen = try await ArtifactFixture.read(web)
        #expect(seen["title"] as? String == "classic ran" && seen["color"] as? String == ArtifactFixture.probeColor)
        #expect(seen["inline"] as? String == "yes", "\(seen)")
        #expect(seen["module"] as? String == "yes" && seen["origin"] as? String == "null", "\(seen)")
        #expect(seen["rtc"] as? String == "undefined")
        let fetched = try await web.callAsyncJavaScript("try { await fetch('style.css'); return 'fetched' } catch { return 'blocked' }", contentWorld: .page) as? String
        #expect(fetched == "blocked")
        _ = try await web.callAsyncJavaScript("location.href = 'https://example.com/'; return 1", contentWorld: .page)
        _ = try await web.callAsyncJavaScript("const a = document.createElement('a'); a.href = 'https://example.org/'; document.body.appendChild(a); a.click(); a.click(); return 1", contentWorld: .page)
        try await Task.sleep(for: .milliseconds(500))
        #expect(web.url == ArtifactPage.url(ref, path: "index.html") && links.isEmpty)
        #expect(navigation.denied.contains(URL(string: "https://example.com/")!))
    }

    /// Against a real obid (#648's, on a throwaway home and port): run with
    /// `TEST_RUNNER_OBID_LIVE_URL`, `TEST_RUNNER_OBID_LIVE_TOKEN_FILE` (its `api-token`) and `TEST_RUNNER_OBID_LIVE_ARTIFACT`
    /// (an html artifact whose page is ArtifactFixture's probe); skipped otherwise.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OBID_LIVE_URL"] != nil))
    func aLiveObidsArtifactThroughTheSchemeHandler() async throws {
        let env = ProcessInfo.processInfo.environment
        let token = try String(contentsOfFile: try #require(env["OBID_LIVE_TOKEN_FILE"]), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let runner = Runner(base: URL(string: env["OBID_LIVE_URL"]!)!, token: token)
        let id = try #require(env["OBID_LIVE_ARTIFACT"])
        let artifact = try #require(try await runner.artifact(id))
        let ref = ArtifactRef(id: id, version: artifact.latest)
        let (_, answer) = try await runner.artifactFile(ref, path: "index.html")
        #expect(answer.statusCode == 200 && answer.value(forHTTPHeaderField: "Content-Security-Policy") == ArtifactPage.policy)
        #expect(try await runner.artifactFile(ref, path: "../api-token").1.statusCode == 404)
        let handler = ArtifactSchemeHandler(ref: ref) { try await runner.artifactFile(ref, path: $0) }
        let navigation = ArtifactNavigation(ref: ref, links: ArtifactLinkGate())
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: ArtifactWeb.configuration(handler))
        web.navigationDelegate = navigation
        web.load(URLRequest(url: ArtifactPage.url(ref, path: "index.html")!))
        let seen = try await ArtifactFixture.read(web)
        #expect(seen["title"] as? String == "classic ran" && seen["color"] as? String == ArtifactFixture.probeColor, "\(seen)")
        #expect(seen["inline"] as? String == "yes" && seen["module"] as? String == "yes" && seen["origin"] as? String == "null", "\(seen)")
        let fetched = try await web.callAsyncJavaScript("try { await fetch('style.css'); return 'fetched' } catch { return 'blocked' }", contentWorld: .page) as? String
        #expect(fetched == "blocked")
    }
}
