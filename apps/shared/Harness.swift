import CoreGraphics
import Foundation

// The conversation harness's wire and the logic the apps put on it (docs/conversation-harness.md,
// sections 4 and 5; docs/runner-api.md, "obid only: the conversation harness" and "obid only:
// artifacts"). Foundation only: the Watch compiles apps/shared/ too.

/// A piece of Oby's words as its agent writes them: appended to the answer under way for the
/// user's turn `turn`, until Oby's `turn` replaces them.
nonisolated struct TurnDelta: Codable, Equatable, Sendable {
    var conversation: String?
    var turn: String
    var text: String
}

/// What a runner's turn carries that the app's Turn doesn't keep (obid only).
nonisolated struct TurnExtras: Equatable, Sendable {
    /// The artifacts it made.
    var artifacts: [ArtifactRef] = []
    /// It's the turn a job adds to its conversation when it ends (#351), not an answer to words.
    var ended = false
    /// It's a routine's run saying it started, skipped or missed (obid only, #395), not an answer.
    var routine = false
}

/// One version of an artifact, as a turn or a job names it.
nonisolated struct ArtifactRef: Codable, Hashable, Sendable {
    var id: String
    var version: Int
}

/// An artifact obid keeps (`GET /v1/artifacts/{id}`): what it's called, its kind and its versions.
nonisolated struct RunnerArtifact: Decodable, Equatable, Identifiable, Sendable {
    nonisolated struct Version: Decodable, Equatable, Sendable {
        var version: Int
        var files: [String]

        init(version: Int, files: [String]) {
            self.version = version
            self.files = files
        }

        private enum CodingKeys: String, CodingKey { case version, files }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(Int.self, forKey: .version)
            files = (try? c.decodeIfPresent([String].self, forKey: .files)) ?? []
        }
    }

    var id: String
    var title: String
    /// `html`, `markdown`, `image`, `pdf` or `canvas`; another is shown as a file to open.
    var kind: String
    var conversation: String?
    var job: String?
    var versions: [Version]

    init(id: String, title: String, kind: String, conversation: String? = nil, job: String? = nil, versions: [Version] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.conversation = conversation
        self.job = job
        self.versions = versions
    }

    private enum CodingKeys: String, CodingKey { case id, title, kind, conversation, job, versions }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        conversation = try? c.decodeIfPresent(String.self, forKey: .conversation)
        job = try? c.decodeIfPresent(String.self, forKey: .job)
        versions = (try? c.decodeIfPresent([Version].self, forKey: .versions)) ?? []
    }

    var latest: Int { versions.map(\.version).max() ?? 1 }

    /// The files of `version`, as obid lists them; none when it isn't known here.
    func files(_ version: Int) -> [String] { versions.first { $0.version == version }?.files ?? [] }

    /// What the card calls its kind.
    /// Its card's and viewer's second line: "Page · v2 · made by Oby", or by the agent of the job
    /// that made it.
    func line(version: Int?, agent: String?) -> String {
        let maker = job == nil ? "Oby" : agent ?? "a task"
        return [kindName, version.map { "v\($0)" }, "made by \(maker)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var kindName: String {
        ["html": "Page", "markdown": "Document", "image": "Image", "pdf": "PDF", "canvas": "Canvas"][kind] ?? kind.capitalized
    }
}

/// The `artifact` event: one was made or got a version, or `deleted`.
nonisolated struct ArtifactEvent: Decodable, Equatable, Sendable {
    var id: String
    var version: Int?
    var title: String?
    var kind: String?
    var conversation: String?
    var job: String?
    var deleted: Bool?

    init(id: String, version: Int? = nil, title: String? = nil, kind: String? = nil, conversation: String? = nil,
         job: String? = nil, deleted: Bool? = nil) {
        self.id = id
        self.version = version
        self.title = title
        self.kind = kind
        self.conversation = conversation
        self.job = job
        self.deleted = deleted
    }

    private enum CodingKeys: String, CodingKey { case id, version, title, kind, conversation, job, deleted }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        conversation = try? c.decodeIfPresent(String.self, forKey: .conversation)
        job = try? c.decodeIfPresent(String.self, forKey: .job)
        deleted = try? c.decodeIfPresent(Bool.self, forKey: .deleted)
    }
}

/// A tool call of the conversation's agent as a line under Oby's words, like Claude Code's.
nonisolated enum ToolLine {
    /// The line's verb and what it's on (shown as a path token), by `tool` as docs/ios-design.md
    /// words them; obid's own words for a tool it doesn't name, and for a step that isn't a tool's.
    static func parts(_ step: TurnStep) -> (verb: String, detail: String?) {
        let detail = step.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let what: String? = detail.isEmpty ? nil : detail
        switch step.tool {
        case "read": return ("Reading", what)
        case "search": return ("Searching for", what)
        case "web_search": return what.map { ("Searching the web for “\($0)”", nil) } ?? ("Searching the web", nil)
        case "web_fetch": return ("Reading", what.map { URL(string: $0)?.host() ?? $0 })
        case "bash": return ("Running", what)
        case "write": return ("Writing", what)
        case "agent": return ("Asking a helper agent", nil)
        case "oby_dispatch": return ("Starting a job", nil)
        case "oby_inbox": return ("Checking the inbox", nil)
        default: return (step.text.isEmpty ? (what ?? "Working") : step.text, nil)
        }
    }

    static func text(_ step: TurnStep) -> String {
        let (verb, detail) = parts(step)
        return detail.map { "\(verb) \($0)" } ?? verb
    }

    /// The turn's lines fold into one once its words start coming, or once nothing runs.
    static func folded(_ steps: [TurnStep], words: Bool = false) -> Bool { words || !steps.contains { $0.state == .running } }

    /// While they run, the last four show.
    static func shown(_ steps: [TurnStep]) -> [TurnStep] { Array(steps.suffix(4)) }

    /// The folded line, in Sangam's words: "Read 3 files, searched the web, ran 2 commands", what
    /// failed after it; "Took 2 steps" for the plan loop's.
    static func summary(_ steps: [TurnStep]) -> String {
        /// "read a file", "read 3 files".
        func phrase(_ n: Int, _ verb: String, _ one: String, _ many: String) -> String? {
            n == 0 ? nil : n == 1 ? "\(verb) \(one)" : "\(verb) \(n) \(many)"
        }
        func count(_ tools: String...) -> Int { steps.filter { $0.action == "tool" && tools.contains($0.tool ?? "") }.count }
        let named = ["read", "search", "web_search", "web_fetch", "bash", "write", "agent", "oby_dispatch"]
        let others = steps.filter { $0.action != "tool" || !named.contains($0.tool ?? "") }.count
        let parts = [
            phrase(count("read"), "read", "a file", "files"),
            phrase(count("search"), "searched", "the code", "times"),
            count("web_search", "web_fetch") > 0 ? "searched the web" : nil,
            phrase(count("bash"), "ran", "a command", "commands"),
            phrase(count("write"), "wrote", "a file", "files"),
            count("agent") > 0 ? "asked a helper agent" : nil,
            phrase(count("oby_dispatch"), "started", "a job", "jobs"),
            phrase(others, "took", "a step", "steps"),
        ].compactMap { $0 }
        let joined = parts.joined(separator: ", ")
        var line = joined.prefix(1).uppercased() + joined.dropFirst()
        let failed = steps.filter { $0.state == .failed }.count
        if failed > 0 { line += " · \(failed) failed" }
        return line
    }
}

/// When a link out of an artifact's page may be offered ("Open in your browser?"): only within a
/// second of a real tap or click on the page, once per tap, and never again from a page whose
/// offer was turned down. A script clicking its own links gets nothing.
nonisolated struct LinkGate: Equatable, Sendable {
    static let window: TimeInterval = 1
    private var touched: Date?
    private(set) var refused = false

    /// A tap or a mouse-down on the page.
    mutating func touch(at now: Date = .now) { touched = now }

    /// Whether a link may be offered now; offering it takes the tap.
    mutating func offer(at now: Date = .now) -> Bool {
        guard !refused, let touched, now.timeIntervalSince(touched) >= 0, now.timeIntervalSince(touched) <= Self.window else { return false }
        self.touched = nil
        return true
    }

    /// The offer was turned down: none again from this page.
    mutating func refuse() { refused = true }
}

/// How a job a turn started stands, for its card under the words.
nonisolated struct JobOutcome: Equatable, Sendable {
    var text: String
    /// The pull request it opened.
    var link: URL?
    var failed: Bool
}

extension Job {
    /// The card's live line while it runs: the stage and the latest step, "Work · Running swift
    /// test" (docs/ios-design.md); nil once it ended. Every `job` event brings the latest.
    nonisolated var liveLine: String? {
        guard isActive else { return nil }
        let line = [stageNow ?? "", step].filter { !$0.isEmpty }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    /// The stage it's at ("Work", "Check"), or nil.
    nonisolated var stageNow: String? {
        #if os(macOS)
        pipeline.stages.first { $0.state == .current }?.title
        #else
        pipeline?.stages.first { $0.state == .current }?.title
        #endif
    }

    /// A task thread's last line while its agent runs: "Claude Code · Running swift test", or,
    /// while the owner's words wait for its next turn, "Claude Code · You: Also check…" (obid
    /// writes that step). Nil once it ended or before it has a step.
    nonisolated var agentLine: String? {
        guard status == .running, !step.isEmpty else { return nil }
        return "\(agentName) · \(step)"
    }

    /// How it ended, for its card: the pull request it opened, why it failed or wasn't
    /// published, else its summary's first line. Nil while it runs.
    nonisolated var outcome: JobOutcome? {
        let first = summary.split(separator: "\n").first.map(String.init)
        switch status {
        case .queued, .running: return nil
        case .stopped: return JobOutcome(text: "Stopped", link: nil, failed: false)
        case .failed: return JobOutcome(text: first ?? status.rawValue.capitalized, link: nil, failed: true)
        // Needs you, nothing lost: why it stopped, not a failure.
        case .interrupted: return JobOutcome(text: reason ?? first ?? "Needs you", link: nil, failed: false)
        case .done:
            if let url = PublishedLink.url(published) {
                let number = url.lastPathComponent
                return JobOutcome(text: Int(number) != nil ? "Pull request #\(number)" : "Published", link: url, failed: false)
            }
            if let publishError, !publishError.isEmpty { return JobOutcome(text: "Not published: \(publishError)", link: nil, failed: true) }
            return JobOutcome(text: first ?? "Done", link: nil, failed: false)
        }
    }
}

/// How the apps load an artifact's page (the client contract, docs/conversation-harness.md
/// section 4): from `oby-artifact://<id>/<version>/<path>`, which a scheme handler fetches from
/// obid with the token, passing obid's Content-Security-Policy on. Nothing else loads.
nonisolated enum ArtifactPage {
    static let scheme = "oby-artifact"

    /// What obid sends on every artifact file (docs/runner-api.md), for an answer that comes without it.
    static let policy = "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' data: blob:; style-src 'self' 'unsafe-inline' data:; img-src 'self' data: blob:; connect-src 'none'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; sandbox allow-scripts"

    /// Nil for an id or path no URL can hold.
    static func url(_ ref: ArtifactRef, path: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = ref.id
        parts.path = "/\(ref.version)/" + path
        return parts.url
    }

    /// The file of `ref`'s version that `url` names, or nil for anything else: another scheme,
    /// another artifact or version, a way out (`..`), or no file. A query or fragment (a page's
    /// `style.css?v=2`, `#top`) names the same file.
    static func path(of url: URL?, for ref: ArtifactRef) -> String? {
        guard let url, url.scheme == scheme, url.host() == ref.id else { return nil }
        let parts = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard parts.first == Substring(String(ref.version)) else { return nil }
        let file = parts.dropFirst()
        guard !file.isEmpty, !file.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return file.joined(separator: "/")
    }

    /// The headers the web view gets: obid's own that matter for a page, its policy unchanged (or
    /// obid's when the answer had none), and `Access-Control-Allow-Origin: *` because the
    /// sandbox gives the page an opaque origin, so its module scripts (fetched with CORS) wouldn't
    /// load without it; its `fetch` stays shut by `connect-src 'none'`.
    static func headers(_ obid: [AnyHashable: Any]) -> [String: String] {
        var found: [String: String] = [:]
        for (key, value) in obid {
            if let key = key as? String, let value = value as? String { found[key.lowercased()] = value }
        }
        var headers = ["Access-Control-Allow-Origin": "*", "Content-Security-Policy": found["content-security-policy"] ?? policy]
        for name in ["Content-Type", "X-Content-Type-Options", "Referrer-Policy"] {
            if let value = found[name.lowercased()] { headers[name] = value }
        }
        return headers
    }
}

/// One frame of a canvas artifact's artboard (`canvas.json`): an HTML file of the version, at its
/// place and size.
nonisolated struct CanvasFrame: Decodable, Equatable, Identifiable, Sendable {
    var title: String?
    var file: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    /// The agent marked it as the one it picks: a ring shows it.
    var picked: Bool?
    var id: String { file }
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

nonisolated enum Artboards {
    /// At most this many frames, each at most this wide and tall: one web view each.
    static let most = 24
    static let largest: Double = 4096

    /// The frames `canvas.json` lists (a list, or `{"frames": […]}`), the first `most`, each
    /// clamped to `largest`; one that can't be read, has no size, or names a file outside the
    /// version, is left out.
    static func frames(_ data: Data) -> [CanvasFrame] {
        struct Lossy: Decodable {
            var frame: CanvasFrame?
            init(from decoder: any Decoder) throws { frame = try? CanvasFrame(from: decoder) }
        }
        struct Wrapped: Decodable { var frames: [Lossy] }
        let list = (try? JSONDecoder().decode([Lossy].self, from: data)) ?? (try? JSONDecoder().decode(Wrapped.self, from: data))?.frames ?? []
        let kept = list.compactMap(\.frame).filter { frame in
            let parts = frame.file.split(separator: "/", omittingEmptySubsequences: false)
            return frame.w > 0 && frame.h > 0 && frame.x.isFinite && frame.y.isFinite
                && !frame.file.hasPrefix("/") && !parts.contains { $0.isEmpty || $0 == ".." }
        }
        return kept.prefix(most).map { frame in
            var frame = frame
            frame.w = min(frame.w, largest)
            frame.h = min(frame.h, largest)
            return frame
        }
    }

    /// The artboard: what holds every frame.
    static func bounds(_ frames: [CanvasFrame]) -> CGRect {
        frames.map(\.rect).reduce(nil as CGRect?) { $0?.union($1) ?? $1 } ?? .zero
    }
}

/// A Markdown artifact in blocks, for the viewer: headings, fenced code, and the rest as Oby's
/// words are set (paragraphs and lists, `SaidText`).
nonisolated enum MarkdownBlocks {
    enum Block: Equatable {
        case heading(Int, String)
        case code(String)
        case text(String)
    }

    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var lines: [Substring] = []
        var code: [Substring]?
        func flush() {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.text(text)) }
            lines = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if let open = code { blocks.append(.code(open.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
            } else if code != nil {
                code?.append(line)
            } else if let hashes = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) {
                flush()
                blocks.append(.heading(hashes.1.count, String(hashes.2)))
            } else if line.allSatisfy(\.isWhitespace) {
                flush()
            } else {
                lines.append(line)
            }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
