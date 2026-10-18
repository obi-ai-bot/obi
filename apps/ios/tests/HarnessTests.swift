import Foundation
import Testing
import WebKit
@testable import Oby

/// The conversation harness on the iPhone (docs/conversation-harness.md, step 3): Oby's words as
/// they're written (`delta`), its tool lines (`step` with `tool` and `detail`), the artifacts a
/// turn made and their viewer, and the live card of a job a turn started. apps/shared/ is one
/// code: apps/mac/tests/HarnessTests.swift checks the Mac's side of it.
@MainActor
struct HarnessTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    func event(_ name: String, _ json: String) -> RunnerEvent? {
        var parser = EventParser()
        for line in ["event: \(name)", "data: \(json)"] { #expect(parser.feed(line) == nil) }
        return parser.feed("")
    }

    func job(_ json: String) throws -> Job {
        let base = #"{"id": "j1", "request": "Fix the login screen", "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/fix-12", "kind": "fix", "task": "Fix #12", "created": "2026-10-17T09:00:00Z""#
        return try Runner.decoder.decode(Job.self, from: Data((base + ", " + json + "}").utf8))
    }

    // MARK: Decoding

    @Test func harnessEventsAreRead() throws {
        #expect(event("delta", #"{"conversation":"c1","turn":"u1","text":"Looking at "}"#)
                == .delta(TurnDelta(conversation: "c1", turn: "u1", text: "Looking at ")))
        let wire = #"{"turn":"u1","conversation":"c1","index":2,"action":"tool","text":"Reading the web","tool":"web_search","detail":"swift testing tags","state":"running","at":"2026-10-17T09:12:04Z"}"#
        guard case .step(let step)? = event("step", wire) else { Issue.record("no step"); return }
        #expect(step.tool == "web_search" && step.detail == "swift testing tags" && step.action == "tool" && step.state == .running)
        #expect(event("artifact", #"{"id":"a1","version":2,"title":"Landing page","kind":"html","conversation":"c1","job":null}"#)
                == .artifact(ArtifactEvent(id: "a1", version: 2, title: "Landing page", kind: "html", conversation: "c1")))
        #expect(event("artifact", #"{"id":"a1","deleted":true}"#) == .artifact(ArtifactEvent(id: "a1", deleted: true)))
        // A turn's artifacts come with it.
        let turn = #"{"id":"o1","who":"oby","text":"Here it is.","at":"2026-10-17T09:12:09Z","jobs":[],"conversation":"c1","artifacts":[{"id":"a1","version":2}]}"#
        guard case .turn(let read, let extras)? = event("turn", turn) else { Issue.record("no turn"); return }
        #expect(read.id == "o1" && extras == TurnExtras(artifacts: [ArtifactRef(id: "a1", version: 2)]))
        // A job's ended turn says so (#351).
        let ended = #"{"id":"o2","who":"oby","text":"Done: PR #7.","at":"2026-10-17T09:30:00Z","jobs":["j1"],"ended":true}"#
        guard case .turn(_, let endedExtras)? = event("turn", ended) else { Issue.record("no turn"); return }
        #expect(endedExtras.ended)
        let meta = #"{"id":"a1","title":"Landing page","kind":"html","conversation":"c1","job":null,"created":"2026-10-17T09:12:00Z","versions":[{"version":1,"created":"2026-10-17T09:12:00Z","files":["index.html","style.css"],"bytes":1832}]}"#
        let artifact = try Runner.decoder.decode(RunnerArtifact.self, from: Data(meta.utf8))
        #expect(artifact.files(1) == ["index.html", "style.css"] && artifact.latest == 1 && artifact.kindName == "Page")
        #expect(artifact.line(version: 2, agent: nil) == "Page · v2 · made by Oby")
        var made = artifact
        made.job = "j1"
        #expect(made.line(version: nil, agent: "Codex") == "Page · made by Codex")
        // A job's artifacts.
        #expect(try job(#""status": "done", "step": "", "summary": "", "artifacts": [{"id": "a9", "version": 1}]"#).artifacts == [ArtifactRef(id: "a9", version: 1)])
    }

    /// Today's obid (and the Swift runner) sends none of it, and a newer one may add more: what the
    /// app doesn't know is left alone, and the rest reads as before.
    @Test func unknownFieldsAndEventsAreIgnored() throws {
        #expect(event("subagent", #"{"anything":1}"#) == nil)
        #expect(event("delta", #"{"text":"no turn"}"#) == nil)
        let older = #"{"turn":"u1","index":1,"action":"move_job","text":"Moving","state":"done"}"#
        guard case .step(let step)? = event("step", older) else { Issue.record("no step"); return }
        #expect(step.tool == nil && step.detail == nil)
        let newer = #"{"turn":"u1","index":1,"action":"tool","text":"Reading a.md","tool":7,"detail":{"x":1},"state":"done","extra":true}"#
        guard case .step(let odd)? = event("step", newer) else { Issue.record("no step"); return }
        #expect(odd.tool == nil && odd.text == "Reading a.md")
        let plain = #"{"id":"o1","who":"oby","text":"Hi","at":"2026-10-17T09:12:09Z","artifacts":"soon","mood":"good"}"#
        guard case .turn(let turn, let extras)? = event("turn", plain) else { Issue.record("no turn"); return }
        #expect(turn.text == "Hi" && extras == TurnExtras())
        let thin = try Runner.decoder.decode(RunnerArtifact.self, from: Data(#"{"id":"a1","title":"Plan","kind":"hologram"}"#.utf8))
        #expect(thin.versions.isEmpty && thin.kindName == "Hologram")
    }

    // MARK: Streamed words

    /// Only Oby's answer replaces the words coming in: not a job's ended turn (#351), and not a
    /// turn sent again because a job joined it; a reload keeps them for the same reasons.
    @Test func onlyAnAnswerReplacesWordsUnderWay() async {
        let asked = Turn(id: "u1", date: now, who: .user, text: "Look into it")
        let earlier = Turn(id: "o0", date: now.addingTimeInterval(-60), who: .oby, text: "Started it.", jobs: ["j0"])
        var page = [earlier, asked]
        let model = ConversationModel(page: { _, _ in page })
        model.time = { self.now }
        await model.reload()
        model.apply(TurnDelta(conversation: nil, turn: "u1", text: "Reading "))
        // A job ends meanwhile: its turn comes, after your words.
        let jobEnded = Turn(id: "o-end", date: now.addingTimeInterval(1), who: .oby, text: "The job opened PR #7.", jobs: ["j0"])
        model.apply(jobEnded, TurnExtras(ended: true))
        #expect(model.streamed["u1"]?.text == "Reading ")
        // An earlier answer sent again (a job joined it).
        model.apply(Turn(id: "o0", date: earlier.date, who: .oby, text: "Started it.", jobs: ["j0", "j1"]))
        #expect(model.streamed["u1"]?.text == "Reading ")
        // A reload whose page has the ended turn after your words keeps them too.
        page = [earlier, asked, jobEnded]
        await model.reload()
        #expect(model.streamed["u1"]?.text == "Reading ")
        // The answer replaces them.
        model.apply(Turn(id: "o1", date: now.addingTimeInterval(2), who: .oby, text: "Reading done."))
        #expect(model.streamed.isEmpty)
    }

    @Test func deltasAppendToTheAnswerUnderWayAndTheTurnReplacesThem() {
        let model = ConversationModel()
        model.time = { self.now }
        let asked = Turn(id: "u1", date: now, who: .user, text: "What's in the README?")
        model.apply(asked)
        model.apply(TurnDelta(conversation: "c1", turn: "u1", text: "It says "))
        model.time = { self.now.addingTimeInterval(2) }
        model.apply(TurnDelta(conversation: "c1", turn: "u1", text: "Oby runs your agents."))
        let streamed = model.streamed(under: asked, in: [asked])
        #expect(streamed?.text == "It says Oby runs your agents." && streamed?.since == now)
        // Another turn's words stay apart.
        model.apply(TurnDelta(conversation: "c1", turn: "u2", text: "Else"))
        #expect(model.streamed["u2"]?.text == "Else")
        // The final turn replaces them, and its words carry on from when they started coming.
        let answer = Turn(id: "o1", date: now.addingTimeInterval(3), who: .oby, text: "It says Oby runs your agents.")
        model.apply(answer)
        #expect(model.streamed.isEmpty && model.streamed(under: asked, in: [asked, answer]) == nil)
        #expect(model.arrived["o1"] == now)
        // The phone's echo of what it said takes the words of a turn the thread doesn't have yet.
        let echo = Turn(id: "echo", date: now, who: .user, text: "And then?")
        model.apply(TurnDelta(conversation: "c1", turn: "u9", text: "Then"))
        #expect(model.streamed(under: echo, in: [asked, answer, echo])?.text == "Then")
        model.forget()
        #expect(model.streamed.isEmpty)
    }

    /// A reload after the connection dropped keeps words under way, and drops those answered meanwhile.
    @Test func aReloadDropsWordsTheThreadAnswered() async {
        let asked = Turn(id: "u1", date: now, who: .user, text: "Hi")
        var page = [asked]
        let model = ConversationModel(page: { _, _ in page })
        await model.reload()
        model.apply(TurnDelta(conversation: nil, turn: "u1", text: "Hel"))
        await model.reload()
        #expect(model.streamed["u1"]?.text == "Hel")
        page.append(Turn(id: "o1", date: now.addingTimeInterval(1), who: .oby, text: "Hello"))
        await model.reload()
        #expect(model.streamed.isEmpty)
    }

    // MARK: Tool lines

    /// The verbs docs/ios-design.md gives each tool, with what it's on as a path token.
    @Test func toolLinesSayWhatObyIsDoing() {
        func step(_ tool: String?, _ detail: String?, text: String = "Reading the web") -> TurnStep {
            TurnStep(turn: "u1", index: 1, action: "tool", text: text, state: .running, tool: tool, detail: detail)
        }
        func line(_ tool: String?, _ detail: String?, text: String = "Reading the web") -> String { ToolLine.text(step(tool, detail, text: text)) }
        #expect(line("web_search", "swift testing tags") == "Searching the web for “swift testing tags”")
        #expect(line("web_fetch", "https://developer.apple.com/documentation/webkit") == "Reading developer.apple.com")
        #expect(ToolLine.parts(step("read", "apps/ios/app/Chat.swift", text: "Reading Chat.swift")) == ("Reading", "apps/ios/app/Chat.swift"))
        #expect(line("bash", "ls -la", text: "Running ls -la") == "Running ls -la")
        #expect(line("search", "TODO", text: "") == "Searching for TODO")
        #expect(line("write", "page/index.html", text: "Editing index.html") == "Writing page/index.html")
        #expect(line("agent", "Explore the repo", text: "Explore the repo") == "Asking a helper agent")
        #expect(line("oby_dispatch", "deskree-inc/oby", text: "Starting a job") == "Starting a job")
        #expect(line("oby_inbox", nil, text: "Looking at the inbox") == "Checking the inbox")
        // Other Oby tools in Oby's words; a step that isn't a tool's, as obid says it.
        #expect(line("oby_jobs", nil, text: "Looking at the jobs") == "Looking at the jobs")
        #expect(line(nil, nil, text: "Moving Docs to Codex") == "Moving Docs to Codex")
    }

    @Test func toolLinesRunThenFoldOnceWordsCome() {
        let model = ConversationModel()
        model.apply(TurnStep(turn: "u1", index: 1, action: "tool", text: "Reading README.md", state: .running, tool: "read", detail: "README.md"))
        model.apply(TurnStep(turn: "u1", index: 2, action: "tool", text: "Running ls", state: .running, tool: "bash", detail: "ls"))
        var steps = model.steps["u1"] ?? []
        #expect(!ToolLine.folded(steps) && model.working)
        // Oby's words starting fold them into one line over the words, even while one still runs.
        #expect(ToolLine.folded(steps, words: true))
        // While they run, the last four show.
        let many = (1...6).map { TurnStep(turn: "u", index: $0, action: "tool", text: "Reading \($0)", state: .running, tool: "read") }
        #expect(ToolLine.shown(many).map(\.index) == [3, 4, 5, 6])
        model.apply(TurnStep(turn: "u1", index: 1, action: "tool", text: "Reading README.md", state: .done, tool: "read", detail: "README.md"))
        model.apply(TurnStep(turn: "u1", index: 2, action: "tool", text: "Running ls", state: .failed, tool: "bash", detail: "ls"))
        steps = model.steps["u1"] ?? []
        #expect(steps.map(\.state) == [.done, .failed])
        #expect(ToolLine.folded(steps) && ToolLine.summary(steps) == "Read a file, ran a command · 1 failed")
        // Sangam's folded line.
        let turn: [TurnStep] = [("read", 3), ("web_search", 1), ("web_fetch", 1), ("bash", 2)].flatMap { (tool: String, n: Int) -> [TurnStep] in
            (0..<n).map { _ in TurnStep(turn: "u", index: 0, action: "tool", text: "", state: .done, tool: tool) }
        }
        #expect(ToolLine.summary(turn) == "Read 3 files, searched the web, ran 2 commands")
        #expect(ToolLine.summary([TurnStep(turn: "u", index: 1, action: "move_job", text: "Moving", state: .done)]) == "Took a step")
        #expect(ToolLine.summary(turn + [TurnStep(turn: "u", index: 1, action: "tool", text: "x", state: .done, tool: "oby_jobs")])
                == "Read 3 files, searched the web, ran 2 commands, took a step")
        // The answer came without the end of a step: the turn ended, so it's done and folds.
        model.apply(TurnStep(turn: "u2", index: 1, action: "tool", text: "Reading a.md", state: .running, tool: "read"))
        model.settleLatestSteps()
        #expect(ToolLine.folded(model.steps["u2"] ?? []))
    }

    // MARK: Artifacts

    @Test func artifactCardsFollowTurnsAndEvents() async {
        let model = ConversationModel()
        var asked: [String] = []
        model.lookUp = { id in
            asked.append(id)
            return id == "a1" ? RunnerArtifact(id: "a1", title: "Landing page", kind: "html", versions: [.init(version: 1, files: ["index.html"])]) : nil
        }
        let said = Turn(id: "o1", date: now, who: .oby, text: "Here it is.")
        model.apply(said, TurnExtras(artifacts: [ArtifactRef(id: "a1", version: 1)]))
        #expect(model.artifactRefs(of: said) == [ArtifactRef(id: "a1", version: 1)])
        await model.resolve("a1")
        await model.resolve("a1")
        #expect(model.artifacts["a1"]?.title == "Landing page" && asked == ["a1"])
        // A new version comes as an event: the card opens it; a rename keeps the files of the first.
        model.apply(ArtifactEvent(id: "a1", version: 2, title: "Landing page v2", kind: "html"))
        #expect(model.artifacts["a1"]?.latest == 2 && model.artifacts["a1"]?.title == "Landing page v2")
        #expect(model.artifacts["a1"]?.files(1) == ["index.html"])
        // The page read later carries the refs too.
        model.note([try! Runner.decoder.decode(RunnerTurn.self, from: Data(#"{"id":"o2","who":"oby","text":"x","at":"2026-10-17T09:12:09Z","artifacts":[{"id":"a2","version":3}]}"#.utf8))])
        #expect(model.refs["o2"] == [ArtifactRef(id: "a2", version: 3)])
        // One that's gone: deleted, or obid doesn't have it.
        await model.resolve("a2")
        #expect(model.gone.contains("a2"))
        model.apply(ArtifactEvent(id: "a1", deleted: true))
        #expect(model.artifacts["a1"] == nil && model.gone.contains("a1"))
    }

    /// A canvas can't ask for more web views, or bigger ones, than the phone should hold.
    @Test func theCanvasIsCapped() {
        let many = (0..<40).map { #"{"file": "f\#($0).html", "x": \#($0 * 10), "y": 0, "w": 100000, "h": 99999}"# }
        let frames = Artboards.frames(Data(("[" + many.joined(separator: ",") + "]").utf8))
        #expect(frames.count == 24 && frames.first?.file == "f0.html" && frames.last?.file == "f23.html")
        #expect(frames.allSatisfy { $0.w == 4096 && $0.h == 4096 })
    }

    @Test func theCanvasIsReadTolerantly() throws {
        let json = #"""
        [{"title": "Phone", "file": "phone.html", "x": 0, "y": 0, "w": 390, "h": 844},
         {"title": "Desktop", "file": "desk/wide.html", "x": 440, "y": 0, "w": 1280, "h": 800, "note": "new"},
         {"file": "../away.html", "x": 0, "y": 0, "w": 10, "h": 10},
         {"file": "/etc/hosts", "x": 0, "y": 0, "w": 10, "h": 10},
         {"file": "flat.html", "x": 0, "y": 0, "w": 0, "h": 10},
         {"file": "odd.html", "x": "left"},
         "not a frame"]
        """#
        let frames = Artboards.frames(Data(json.utf8))
        #expect(frames.map(\.file) == ["phone.html", "desk/wide.html"])
        #expect(frames[0].title == "Phone" && frames[1].w == 1280 && frames[0].picked == nil)
        #expect(Artboards.frames(Data(#"[{"file": "a.html", "x": 0, "y": 0, "w": 10, "h": 10, "picked": true}]"#.utf8)).first?.picked == true)
        #expect(Artboards.bounds(frames) == CGRect(x: 0, y: 0, width: 1720, height: 844))
        // Wrapped in an object, as a newer obid might.
        #expect(Artboards.frames(Data(#"{"frames": [{"file": "a.html", "x": 10, "y": 20, "w": 100, "h": 50}]}"#.utf8)).count == 1)
        #expect(Artboards.frames(Data("nonsense".utf8)).isEmpty && Artboards.bounds([]) == .zero)
    }

    @Test func markdownIsReadInBlocks() {
        let text = "# Plan\n\nFirst paragraph\nwith two lines.\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n- one\n- two\n\n### Notes"
        #expect(MarkdownBlocks.blocks(text) == [
            .heading(1, "Plan"), .text("First paragraph\nwith two lines."), .code("let a = 1\n\nlet b = 2"),
            .text("- one\n- two"), .heading(3, "Notes"),
        ])
    }

    // MARK: The viewer's web view

    @Test func onlyTheArtifactsOwnFilesNavigate() {
        let ref = ArtifactRef(id: "3f0c", version: 2)
        let own = ArtifactPage.url(ref, path: "assets/site.css")!
        #expect(own.absoluteString == "oby-artifact://3f0c/2/assets/site.css")
        // A query or fragment names the same file: it loads, not fails.
        #expect(ArtifactPage.path(of: URL(string: "oby-artifact://3f0c/2/assets/site.css?v=2"), for: ref) == "assets/site.css")
        #expect(ArtifactPage.path(of: URL(string: "oby-artifact://3f0c/2/index.html#top"), for: ref) == "index.html")
        #expect(ArtifactPage.path(of: own, for: ref) == "assets/site.css")
        #expect(ArtifactPage.path(of: ArtifactPage.url(ref, path: "a b.html"), for: ref) == "a b.html")
        for url in ["https://example.com/", "http://127.0.0.1:7357/v1/status", "oby-artifact://other/2/index.html",
                    "oby-artifact://3f0c/1/index.html", "oby-artifact://3f0c/2/../../x", "oby-artifact://3f0c/2/", "about:blank",
                    "blob:oby-artifact://3f0c/1", "data:text/html,hi", "javascript:alert(1)", "file:///etc/hosts"] {
            #expect(ArtifactPage.path(of: URL(string: url), for: ref) == nil, "\(url)")
        }
        #expect(ArtifactPage.path(of: nil, for: ref) == nil)
    }

    @Test func obidsPolicyIsPassedOnUnchanged() {
        let obid: [AnyHashable: Any] = [
            "Content-Type": "text/html; charset=utf-8", "content-security-policy": "default-src 'none'; sandbox allow-scripts",
            "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Set-Cookie": "a=b", "Server": "obid",
        ]
        let passed = ArtifactPage.headers(obid)
        #expect(passed["Content-Security-Policy"] == "default-src 'none'; sandbox allow-scripts")
        #expect(passed["Content-Type"] == "text/html; charset=utf-8" && passed["X-Content-Type-Options"] == "nosniff" && passed["Referrer-Policy"] == "no-referrer")
        #expect(passed["Set-Cookie"] == nil && passed["Server"] == nil)
        // Module scripts load under the sandbox's opaque origin; fetch stays shut (connect-src).
        #expect(passed["Access-Control-Allow-Origin"] == "*")
        // An answer without one (an older obid, a proxy that took it out) still gets obid's.
        #expect(ArtifactPage.headers(["Content-Type": "text/html"])["Content-Security-Policy"] == ArtifactPage.policy)
        #expect(ArtifactPage.policy.hasSuffix("sandbox allow-scripts") && ArtifactPage.policy.contains("connect-src 'none'"))
    }

    /// The finding docs/conversation-harness.md asked for: through the scheme handler, under obid's
    /// policy (`sandbox allow-scripts`), WKWebView loads the page's own CSS, runs its scripts
    /// (inline, classic and module), gives it an opaque origin, and stops its fetch and its
    /// navigating away.
    @Test func aPageRunsItsOwnFilesUnderObidsPolicy() async throws {
        let ref = ArtifactRef(id: "a1", version: 1)
        let files = ArtifactFixture.files
        var served: [String] = []
        let handler = ArtifactSchemeHandler(ref: ref) { path in
            served.append(path)
            return ArtifactFixture.answer(path, files: files)
        }
        var links: [URL] = []
        let gate = ArtifactLinkGate()
        gate.ask = { links.append($0) }
        let navigation = ArtifactNavigation(ref: ref, links: gate)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: ArtifactWeb.configuration(handler))
        web.navigationDelegate = navigation
        web.load(URLRequest(url: ArtifactPage.url(ref, path: "index.html")!))
        let seen = try await ArtifactFixture.read(web)
        #expect(seen["title"] as? String == "classic ran")
        #expect(seen["color"] as? String == ArtifactFixture.probeColor)
        #expect(seen["inline"] as? String == "yes", "\(seen)")
        #expect(seen["module"] as? String == "yes", "\(seen)")
        #expect(seen["origin"] as? String == "null")
        #expect(seen["rtc"] as? String == "undefined")
        let fetched = try await web.callAsyncJavaScript("try { await fetch('style.css'); return 'fetched' } catch { return 'blocked' }", contentWorld: .page) as? String
        #expect(fetched == "blocked")
        // Navigating itself away is denied, and not opened either: only a tapped link offers that.
        _ = try await web.callAsyncJavaScript("location.href = 'https://example.com/'; return 1", contentWorld: .page)
        // A script clicking a link of its own, again and again, never brings up "Open in your browser?".
        _ = try await web.callAsyncJavaScript("""
            for (let i = 0; i < 5; i++) { const a = document.createElement('a'); a.href = 'https://example.org/' + i; document.body.appendChild(a); a.click(); }
            return 1
            """, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(500))
        #expect(web.url == ArtifactPage.url(ref, path: "index.html") && links.isEmpty)
        #expect(navigation.denied.contains(URL(string: "https://example.com/")!))
        #expect(navigation.denied.contains(URL(string: "https://example.org/0")!))
        #expect(served.sorted() == ["app.js", "index.html", "mod.js", "style.css"])
    }

    /// A link out is offered only within a second of a real tap, once per tap, and never again
    /// from a viewer whose offer was turned down.
    @Test func linksOutWaitForARealTap() {
        let start = Date(timeIntervalSince1970: 1_000)
        var gate = LinkGate()
        func offer(_ seconds: TimeInterval) -> Bool { gate.offer(at: start.addingTimeInterval(seconds)) }
        let untouched = offer(0)
        gate.touch(at: start)
        let late = offer(1.5)
        gate.touch(at: start.addingTimeInterval(2))
        let tapped = offer(2.4)
        // One tap, one offer: a script clicking again right after gets nothing.
        let again = offer(2.5)
        gate.touch(at: start.addingTimeInterval(3))
        gate.refuse()
        let refused = offer(3.1)
        gate.touch(at: start.addingTimeInterval(4))
        let afterCancel = offer(4.1)
        #expect(!untouched && !late && tapped && !again && !refused && !afterCancel && gate.refused)
    }

    // MARK: A job's card

    @Test func aJobsCardFollowsItsEvents() throws {
        let stages = #"{"stages": [{"id": "prepare", "title": "Prepare", "state": "done"}, {"id": "work", "title": "Work", "state": "current"}, {"id": "check", "title": "Check", "state": "upcoming"}], "number": 2, "total": 3}"#
        let running = try job(#""status": "running", "step": "Running swift test", "summary": "", "pipeline": \#(stages)"#)
        #expect(running.stageNow == "Work" && running.outcome == nil && running.liveLine == "Work · Running swift test")
        // The next `job` event carries the next step: the card's line follows it.
        var next = running
        next.step = "You: Also check the jitter cap"
        #expect(next.liveLine == "Work · You: Also check the jitter cap")
        #expect(next.agentLine == "Claude Code · You: Also check the jitter cap")
        #expect(try job(#""status": "queued", "step": "", "summary": """#).liveLine == nil)
        let published = try job(#""status": "done", "step": "", "summary": "The empty state says what to do.", "published": "https://github.com/deskree-inc/oby/pull/412""#)
        #expect(published.outcome == JobOutcome(text: "Pull request #412", link: URL(string: "https://github.com/deskree-inc/oby/pull/412"), failed: false))
        #expect(published.liveLine == nil && published.agentLine == nil)
        let failed = try job(#""status": "failed", "step": "", "summary": "swift test failed: 2 tests\nMore below""#)
        #expect(failed.outcome == JobOutcome(text: "swift test failed: 2 tests", link: nil, failed: true))
        let unpublished = try job(#""status": "done", "step": "", "summary": "Done it.", "commits": 1, "publishError": "The secret scan couldn't run.""#)
        #expect(unpublished.outcome == JobOutcome(text: "Not published: The secret scan couldn't run.", link: nil, failed: true))
        #expect(try job(#""status": "stopped", "step": "", "summary": """#).outcome == JobOutcome(text: "Stopped", link: nil, failed: false))
        #expect(try job(#""status": "done", "step": "", "summary": "Answered.""#).outcome == JobOutcome(text: "Answered.", link: nil, failed: false))
    }
}
