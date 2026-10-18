#if os(iOS) || os(macOS)
import PDFKit
import SwiftUI
import WebKit

// What the conversation harness looks like on the iPhone and the Mac, in Sangam's style: Oby's
// words coming in, its tool lines, a job's live card lines, and artifact cards with their viewer.
// The logic is in apps/shared/Harness.swift.

/// One file of an artifact's version, as obid answers it.
typealias ArtifactFetch = @MainActor (_ path: String) async throws -> (Data, HTTPURLResponse)

// MARK: The web view

/// Serves `oby-artifact://<id>/<version>/<path>` to a web view from obid (`fetch`, with the token),
/// with obid's headers and its Content-Security-Policy passed on (`ArtifactPage.headers`). A URL
/// of another artifact or version fails.
final class ArtifactSchemeHandler: NSObject, WKURLSchemeHandler {
    let ref: ArtifactRef
    let fetch: ArtifactFetch
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(ref: ArtifactRef, fetch: @escaping ArtifactFetch) {
        self.ref = ref
        self.fetch = fetch
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        guard let url = task.request.url, let path = ArtifactPage.path(of: url, for: ref) else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        running[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let (data, answer) = try await fetch(path)
                // Stopped meanwhile: WebKit doesn't take another word about it.
                guard running.removeValue(forKey: key) != nil else { return }
                let response = HTTPURLResponse(url: url, statusCode: answer.statusCode, httpVersion: "HTTP/1.1",
                                               headerFields: ArtifactPage.headers(answer.allHeaderFields))!
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            } catch {
                guard running.removeValue(forKey: key) != nil else { return }
                task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        running.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }
}

/// Whether a link out may be offered from one viewer's pages (`LinkGate`), shared by its web
/// views and its Cancel.
@MainActor final class ArtifactLinkGate {
    var gate = LinkGate()
    /// What the viewer does with a link it may offer: "Open … in your browser?".
    var ask: (@MainActor (URL) -> Void)?
}

/// Lets the artifact's own files load and nothing else: every other navigation is denied. A link
/// the person tapped (within a second of a real tap, `LinkGate`) is handed to `onLink`, which may
/// open it outside after they confirm; a script clicking links gets nothing.
final class ArtifactNavigation: NSObject, WKNavigationDelegate {
    let ref: ArtifactRef
    let links: ArtifactLinkGate
    /// What was denied, newest last (the tests read it).
    private(set) var denied: [URL] = []

    init(ref: ArtifactRef, links: ArtifactLinkGate) {
        self.ref = ref
        self.links = links
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = action.request.url
        if ArtifactPage.path(of: url, for: ref) != nil { return .allow }
        if let url {
            denied.append(url)
            if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme), links.gate.offer() { links.ask?(url) }
        }
        return .cancel
    }
}

/// The artifact's web view: it tells its gate when a person (never a script) taps or clicks it.
final class ArtifactWKWebView: WKWebView {
    var onTouch: (@MainActor () -> Void)?

    #if os(iOS)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type == .touches { onTouch?() }
        return super.hitTest(point, with: event)
    }
    #else
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let event = NSApp.currentEvent, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { onTouch?() }
        return super.hitTest(point)
    }
    #endif
}

enum ArtifactWeb {
    /// A web view's settings for an artifact: its files from `handler`, scripts on unless it's a
    /// card's preview, nothing kept between pages, media only when tapped and never to AirPlay or
    /// picture in picture, and no WebRTC (a CSP has no rule for it; ponytail: a script at document
    /// start in every frame, the strongest public switch WebKit has; DNS prefetch has none at all).
    static func configuration(_ handler: ArtifactSchemeHandler, scripts: Bool = true) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: ArtifactPage.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = scripts
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        let noRTC = """
        for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel', 'RTCRtpSender', 'RTCRtpReceiver']) {
          try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); } catch (e) {}
        }
        try { Object.defineProperty(navigator, 'mediaDevices', { value: undefined, configurable: false }); } catch (e) {}
        """
        configuration.userContentController.addUserScript(WKUserScript(source: noRTC, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        #if os(iOS)
        configuration.dataDetectorTypes = []
        configuration.allowsPictureInPictureMediaPlayback = false
        #endif
        return configuration
    }
}

/// One page of an artifact (`path` in `ref`'s version) in a web view, loaded only through
/// `ArtifactSchemeHandler`: never `loadHTMLString`, `blob:` or `srcdoc`, which drop obid's
/// policy. `zoom` scales it, for a canvas's frames; `scripts` off for a card's preview.
@MainActor struct ArtifactWebView {
    let ref: ArtifactRef
    let path: String
    /// Where its files come from (`ArtifactSource`).
    let runner: Runner?
    var zoom: CGFloat = 1
    var scripts = true
    var links = ArtifactLinkGate()

    final class Coordinator {
        var navigation: ArtifactNavigation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func make(_ coordinator: Coordinator) -> WKWebView {
        let navigation = ArtifactNavigation(ref: ref, links: links)
        coordinator.navigation = navigation
        let fetch = ArtifactSource.fetch(ref, runner: runner) ?? { _ in throw URLError(.notConnectedToInternet) }
        let web = ArtifactWKWebView(frame: .zero, configuration: ArtifactWeb.configuration(ArtifactSchemeHandler(ref: ref, fetch: fetch), scripts: scripts))
        let links = links
        web.onTouch = { links.gate.touch() }
        web.navigationDelegate = navigation
        // A preview of a link opens it without asking the navigation delegate.
        web.allowsLinkPreview = false
        web.pageZoom = zoom
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .clear
        #else
        web.underPageBackgroundColor = .clear
        #endif
        if let url = ArtifactPage.url(ref, path: path) { web.load(URLRequest(url: url)) }
        return web
    }
}

#if os(iOS)
extension ArtifactWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateUIView(_ web: WKWebView, context: Context) { if web.pageZoom != zoom { web.pageZoom = zoom } }
}
#else
extension ArtifactWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ web: WKWebView, context: Context) { if web.pageZoom != zoom { web.pageZoom = zoom } }
}
#endif

/// A PDF artifact, natively. Its links go to the viewer's confirmation, http and https only.
@MainActor struct PDFPage {
    let data: Data
    let onLink: @MainActor (URL) -> Void

    final class Coordinator: NSObject, PDFViewDelegate {
        var onLink: @MainActor (URL) -> Void = { _ in }

        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            if ["http", "https"].contains(url.scheme) { onLink(url) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func make(_ coordinator: Coordinator) -> PDFView {
        coordinator.onLink = onLink
        let view = PDFView()
        view.autoScales = true
        view.delegate = coordinator
        view.document = PDFDocument(data: data)
        return view
    }
}

#if os(iOS)
extension PDFPage: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { make(context.coordinator) }
    func updateUIView(_ view: PDFView, context: Context) {}
}
#else
extension PDFPage: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { make(context.coordinator) }
    func updateNSView(_ view: PDFView, context: Context) {}
}
#endif

// MARK: Cards and the viewer

/// Where an artifact's files come from: obid with the token (through the gateway on the phone),
/// or, in a debug build's sample screens, `ArtifactFixture`.
enum ArtifactSource {
    static func fetch(_ ref: ArtifactRef, runner: Runner?) -> ArtifactFetch? {
        #if DEBUG
        if ref.id == ArtifactFixture.sample.id { return { ArtifactFixture.answer($0) } }
        #endif
        guard let runner else { return nil }
        return { try await runner.artifactFile(ref, path: $0) }
    }
}

/// An artifact under the words that made it (Sangam's `.artifact-card`, docs/ios-design.md): a
/// 116-point preview of its first screen, its kind's mark, its title, "Page · v2 · made by Oby"; a
/// tap opens the viewer.
struct ArtifactCard: View {
    let ref: ArtifactRef
    let artifact: RunnerArtifact?
    let gone: Bool
    /// The runner its files come from, or nil (none set).
    let runner: Runner?
    /// The agent of the job that made it, when a job did.
    var agent: String?
    @State private var open = false

    private var fetch: ArtifactFetch? { ArtifactSource.fetch(ref, runner: runner) }

    var body: some View {
        Button { open = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                if fetch != nil, !gone, artifact?.kind == "html" {
                    // Its first screen, as it looks: not to touch, the card opens it.
                    ArtifactWebView(ref: ref, path: "index.html", runner: runner, scripts: false)
                        .allowsHitTesting(false)
                        .frame(height: 116)
                        .clipped()
                        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.line).frame(height: 1) }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ArtifactCard.symbol(artifact?.kind)).font(Tokens.font(13, .semibold)).frame(width: 16).padding(.top, 1)
                        .foregroundStyle(Tokens.muted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gone ? "No longer kept" : artifact.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Artifact")
                            .font(Tokens.font(Tokens.textMd, .medium)).foregroundStyle(gone ? Tokens.muted : Tokens.ink).fadeOut()
                        Text(artifact?.line(version: ref.version, agent: agent) ?? "v\(ref.version)")
                            .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).fadeOut()
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.line) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(gone || fetch == nil)
        .accessibilityLabel("Open \(artifact?.title ?? "artifact"), \(artifact?.kindName ?? "")")
        #if DEBUG
        // `-ObySampleOpenArtifact <seconds>`: the sample's viewer opens by itself, for a screenshot.
        .task {
            let after = UserDefaults.standard.double(forKey: "ObySampleOpenArtifact")
            guard ref.id == ArtifactFixture.sample.id, after > 0 else { return }
            try? await Task.sleep(for: .seconds(after))
            open = true
        }
        #endif
        .sheet(isPresented: $open) {
            ArtifactViewer(ref: ref, artifact: artifact, runner: runner, agent: agent)
        }
    }

    static func symbol(_ kind: String?) -> String {
        switch kind {
        case "html": "globe"
        case "markdown": "doc.text"
        case "image": "photo"
        case "pdf": "doc.richtext"
        case "canvas": "square.grid.2x2"
        default: "doc"
        }
    }
}

/// An artifact open, a sheet over the conversation (docs/ios-design.md): close at the left, the
/// title and "Page · made by Oby" in the middle, its version at the right (a menu of the others).
/// HTML in a web view with its scripts on and no network; Markdown in Oby's own type; an image or
/// a PDF natively; a canvas as a pannable, zoomable artboard of its frames (one web view each:
/// `frame-ancestors 'none'` forbids frames inside a page).
struct ArtifactViewer: View {
    let ref: ArtifactRef
    let artifact: RunnerArtifact?
    let runner: Runner?
    var agent: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var known: RunnerArtifact?
    @State private var version: Int?
    @State private var content: Content?
    @State private var problem: String?
    @State private var leaving: URL?
    /// Links out of this viewer's pages: offered only after a real tap, and none after a Cancel.
    @State private var links = ArtifactLinkGate()

    enum Content {
        case page(String)
        case markdown(String)
        case image(Data)
        case pdf(Data)
        case canvas([CanvasFrame])
    }

    private var shown: RunnerArtifact? { known ?? artifact }
    private var open: ArtifactRef { ArtifactRef(id: ref.id, version: version ?? ref.version) }
    private var fetch: ArtifactFetch? { ArtifactSource.fetch(open, runner: runner) }
    #if os(iOS)
    private static let device = "iPhone"
    #else
    private static let device = "Mac"
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header
            viewer.id(open)
            if case .page = content {
                Text("Runs on this \(Self.device) with no network").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
        }
        .background(Tokens.bg)
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 760, minHeight: 560)
        #endif
        .task(id: open) {
            links.ask = { ask($0) }
            await load()
        }
        .confirmationDialog("Open \(leaving?.host() ?? "this link") in your browser?", isPresented: Binding { leaving != nil } set: { if !$0 { leaving = nil } },
                            titleVisibility: .visible) {
            Button("Open") { if let leaving { openURL(leaving) } }
            Button("Cancel", role: .cancel) { links.gate.refuse() }
        } message: {
            Text(leaving?.absoluteString ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(Tokens.font(13, .semibold)).foregroundStyle(Tokens.ink)
                    .frame(width: 32, height: 32).background(Tokens.pill, in: Circle())
            }
            .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close")
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(shown?.title ?? "Artifact").font(Tokens.font(Tokens.textBase, .semibold)).foregroundStyle(Tokens.ink).lineLimit(1)
                Text(shown?.line(version: nil, agent: agent) ?? "").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                ForEach((shown?.versions ?? []).map(\.version).sorted(by: >), id: \.self) { each in
                    Button("Version \(each)") { version = each }
                }
            } label: {
                Text("v\(open.version)").font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.text)
                    .padding(.horizontal, 10).frame(height: 28).background(Tokens.pill, in: Capsule())
            }
            .menuIndicator(.hidden).fixedSize()
            .disabled((shown?.versions.count ?? 0) < 2)
            .accessibilityLabel("Version \(open.version)")
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private var viewer: some View {
        Group {
            switch content {
            case .page(let path): ArtifactWebView(ref: open, path: path, runner: runner, links: links)
            case .markdown(let text):
                ScrollView { MarkdownPage(text: text).padding(Tokens.gutter) }
                    // Its links ask first too, and only go to the web.
                    .environment(\.openURL, OpenURLAction { url in
                        guard ["http", "https"].contains(url.scheme) else { return .discarded }
                        ask(url)
                        return .handled
                    })
            case .image(let data): ScrollView([.horizontal, .vertical]) { ArtifactImage(data: data).padding(Tokens.gutter) }
            case .pdf(let data): PDFPage(data: data, onLink: ask)
            case .canvas(let frames): Artboard(ref: open, frames: frames, runner: runner, links: links)
            case nil:
                VStack(spacing: 8) {
                    if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger) } else { ProgressView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Open … in your browser?", unless a Cancel turned links from this viewer down.
    private func ask(_ url: URL) {
        guard !links.gate.refused else { return }
        leaving = url
    }

    private func load() async {
        content = nil
        problem = nil
        do {
            var artifact = shown
            // What the card knew may lack the files (an `artifact` event names none): obid lists them.
            if artifact?.files(open.version).isEmpty ?? true, let runner, let read = try? await runner.artifact(ref.id) { artifact = read }
            known = artifact
            guard let artifact else { problem = "Oby doesn't keep this artifact any more."; return }
            let files = artifact.files(open.version)
            switch artifact.kind {
            case "html": content = .page(files.contains("index.html") || files.isEmpty ? "index.html" : files[0])
            case "canvas":
                let frames = Artboards.frames(try await file("canvas.json"))
                if frames.isEmpty { problem = "The canvas has no frames to show." } else { content = .canvas(frames) }
            default:
                guard let first = files.first else { problem = "This version has no files."; return }
                switch artifact.kind {
                case "markdown": content = .markdown(String(decoding: try await file(first), as: UTF8.self))
                case "pdf": content = .pdf(try await file(first))
                case "image" where !first.lowercased().hasSuffix(".svg"): content = .image(try await file(first))
                // An SVG may hold scripts: it's a page, under obid's policy like one.
                default: content = .page(first)
                }
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func file(_ path: String) async throws -> Data {
        guard let fetch else { throw RunnerError(message: "Set the runner first.") }
        let (data, answer) = try await fetch(path)
        guard (200..<300).contains(answer.statusCode) else { throw RunnerError(message: "The runner answered \(answer.statusCode) for \(path).") }
        return data
    }
}

/// A Markdown artifact in Oby's own type (docs/ios-design.md): 22/600 the title, 15/600 headings,
/// 14 the body in `item` with lists and tokens (`SaidText`), code blocks on the code ground.
private struct MarkdownPage: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownBlocks.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let words):
                    Text(words).font(Tokens.font(level == 1 ? 22 : 15, .semibold)).foregroundStyle(Tokens.ink)
                        .padding(.top, level == 1 ? 0 : 6)
                case .code(let code):
                    ScrollView(.horizontal) {
                        Text(code).font(Tokens.mono(13)).foregroundStyle(Tokens.ink).textSelection(.enabled).padding(12)
                    }
                    .background(Tokens.pill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .text(let words): SaidText(text: words, color: Tokens.item)
                }
            }
        }
        .frame(maxWidth: Tokens.column, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

private struct ArtifactImage: View {
    let data: Data

    var body: some View {
        #if os(iOS)
        if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() } else { unreadable }
        #else
        if let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() } else { unreadable }
        #endif
    }

    private var unreadable: some View { Text("This image can't be shown.").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted) }
}

/// A canvas (docs/ios-design.md): its frames where `canvas.json` puts them on a 16-point dot grid,
/// each named over it in 11 points, the picked one ringed; pinch and drag move it, and the pill
/// at the foot zooms (−, the zoom, +, Fit). It opens fitted to the width.
private struct Artboard: View {
    let ref: ArtifactRef
    let frames: [CanvasFrame]
    let runner: Runner?
    let links: ArtifactLinkGate
    @State private var scale: CGFloat?
    @GestureState private var pinch: CGFloat = 1
    private let title: CGFloat = 20
    private let margin: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let bounds = Artboards.bounds(frames)
            let fitted = min(1, (geometry.size.width - margin * 2) / max(bounds.width, 1))
            let zoom = min(3, max(0.1, (scale ?? fitted) * pinch))
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(frames) { frame in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(frame.title ?? frame.file).font(Tokens.font(11, .medium)).foregroundStyle(Tokens.text).lineLimit(1)
                                .frame(height: title - 4)
                            ArtifactWebView(ref: ref, path: frame.file, runner: runner, zoom: zoom, links: links)
                                .frame(width: frame.w * zoom, height: frame.h * zoom)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(frame.picked == true ? Tokens.unread : Tokens.line, lineWidth: frame.picked == true ? 2 : 1)
                                }
                        }
                        .offset(x: (frame.x - bounds.minX) * zoom, y: (frame.y - bounds.minY) * zoom)
                    }
                }
                .frame(width: bounds.width * zoom, height: bounds.height * zoom + title, alignment: .topLeading)
                .padding(margin)
            }
            .background(DotGrid())
            .simultaneousGesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in scale = min(3, max(0.1, (scale ?? fitted) * value.magnification)) })
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    Button { scale = max(0.1, zoom / 1.25) } label: { Image(systemName: "minus").frame(width: 28, height: 28) }.accessibilityLabel("Zoom out")
                    Text("\(Int((zoom * 100).rounded()))%").font(Tokens.font(Tokens.textSm)).monospacedDigit().frame(minWidth: 44)
                    Button { scale = min(3, zoom * 1.25) } label: { Image(systemName: "plus").frame(width: 28, height: 28) }.accessibilityLabel("Zoom in")
                    Button("Fit") { scale = nil }.font(Tokens.font(Tokens.textSm, .medium)).padding(.horizontal, 6)
                }
                .buttonStyle(.plain).foregroundStyle(Tokens.ink)
                .padding(.horizontal, 10).frame(height: 36)
                .background(Tokens.surface, in: Capsule())
                .overlay { Capsule().strokeBorder(Tokens.surfaceEdge) }
                .padding(16)
            }
        }
    }
}

/// The artboard's ground: a dot every 16 points.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            var dots = Path()
            for x in stride(from: 8.0, to: size.width, by: 16) {
                for y in stride(from: 8.0, to: size.height, by: 16) { dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)) }
            }
            context.fill(dots, with: .color(Tokens.line))
        }
        .background(Tokens.bg)
    }
}

// MARK: The thread

/// Oby's words while they're still being written, under your message: its face and the words
/// coming in, word by word.
struct StreamingAnswer: View {
    let streamed: ConversationModel.Streamed

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Its words land: the dots run back together into the face.
            ObyFaceLive(live: false, working: true)
            // The words that came hold their place at once, so the thread scrolls to them as each
            // delta comes; the reveal fills it in.
            SaidText(text: streamed.text, color: Tokens.item).hidden().accessibilityHidden(true)
                .overlay(alignment: .topLeading) { ArrivingSaid(text: streamed.text, color: Tokens.item, since: streamed.since) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What Oby did for your words (Sangam's `.tool-line`, docs/ios-design.md): while it works, the
/// last four lines, each with its mark (the working dot and the sheen, a grey check, or `danger`),
/// the verb and what it's on as a path token. Once its words start, or nothing runs, they fold
/// into one muted line, "Read 3 files, searched the web, ran 2 commands ›", that a tap opens.
struct ToolSteps: View {
    let steps: [TurnStep]
    /// Oby's words for them have started coming.
    var words = false
    @State private var open = false

    var body: some View {
        let folded = ToolLine.folded(steps, words: words)
        VStack(alignment: .leading, spacing: 6) {
            if folded {
                Button { withAnimation(Tokens.warm) { open.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text(ToolLine.summary(steps)).font(Tokens.font(Tokens.textMd)).fadeOut()
                        Image(systemName: "chevron.right").font(Tokens.font(10, .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .foregroundStyle(Tokens.muted).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? "Open" : "Folded")
            }
            if !folded || open {
                ForEach(folded ? steps : ToolLine.shown(steps)) { step in line(step) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The verb in `muted` (`danger` when it failed), then what it's on as a path token.
    private static func styled(_ verb: String, _ detail: String?, failed: Bool) -> AttributedString {
        var line = AttributedString(verb)
        line.foregroundColor = failed ? Tokens.danger : Tokens.muted
        if let detail {
            var token = AttributedString(" " + detail)
            token.font = Tokens.mono(12)
            token.foregroundColor = Tokens.code
            line += token
        }
        return line
    }

    private func line(_ step: TurnStep) -> some View {
        let (verb, detail) = ToolLine.parts(step)
        return HStack(spacing: 8) {
            Group {
                switch step.state {
                case .running: WorkMarkView(mark: .working, dot: 6)
                case .done: Image(systemName: "checkmark").font(Tokens.font(10, .semibold)).foregroundStyle(Tokens.check)
                case .failed: Image(systemName: "xmark").font(Tokens.font(10, .semibold)).foregroundStyle(Tokens.danger)
                }
            }
            .frame(width: 12, height: 12)
            if step.state == .running {
                Sheen(text: ToolLine.text(step), size: Tokens.textMd).lineLimit(1)
            } else {
                Text(Self.styled(verb, detail, failed: step.state == .failed))
                    .font(Tokens.font(Tokens.textMd)).lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ToolLine.text(step)), \(step.state.spoken)")
    }
}

/// Under a job card's meta line (docs/ios-design.md): while it runs, its stage and latest step on
/// one line with the sheen, and the stage bar; once it ended, its result: the pull request it
/// opened, or why it failed. Each `job` event brings the latest.
struct JobCardLines: View {
    let job: Job
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let outcome = job.outcome {
            if let link = outcome.link {
                Button { openURL(link) } label: {
                    Text(outcome.text).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.text).underline()
                }
                .buttonStyle(.plain)
            } else {
                Text(outcome.text).font(Tokens.font(Tokens.textSm)).foregroundStyle(outcome.failed ? Tokens.danger : Tokens.text).fadeOut()
            }
        } else if let line = job.liveLine {
            VStack(alignment: .leading, spacing: 6) {
                Sheen(text: line, size: Tokens.textSm).lineLimit(1)
                StageBar(job: job, needs: false)
            }
        }
    }
}

#if DEBUG
/// A made-up artifact page (a page, its stylesheet, a classic and a module script), served as
/// obid serves it: for the tests and the sample screens (`-ObySampleTalk`).
enum ArtifactFixture {
    static let probeColor = "rgb(255, 138, 112)"
    /// The sample screens' artifact: its card opens these files.
    static let sample = RunnerArtifact(id: "sample-artifact", title: "Login empty state", kind: "html",
                                       versions: [.init(version: 1, files: files.keys.sorted())])
    static let files: [String: (type: String, body: String)] = [
        "index.html": ("text/html; charset=utf-8", """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="stylesheet" href="style.css"><script src="app.js"></script><script type="module" src="mod.js"></script></head>
        <body><main><p class="eyebrow" id="probe">Login screen</p><h1>Nothing here yet</h1>
        <p>Sign in with GitHub to see your repositories, or ask Oby to connect one.</p>
        <button>Sign in with GitHub</button><p class="small" id="ran">Scripts: waiting</p></main>
        <script>document.body.dataset.inline = "yes";</script></body></html>
        """),
        "style.css": ("text/css; charset=utf-8", """
        body { margin: 0; font: 16px -apple-system, system-ui; background: #0b0b0b; color: #ececec; }
        main { padding: 48px 28px; } h1 { font-size: 28px; margin: 8px 0 12px; } p { color: #a3a3a8; line-height: 1.5; }
        #probe { color: \(probeColor); font: 600 12px ui-monospace, monospace; letter-spacing: .08em; text-transform: uppercase; }
        button { margin-top: 16px; background: #ececec; color: #0b0b0b; border: 0; border-radius: 12px; padding: 12px 18px; font-weight: 600; }
        .small { font-size: 12px; color: #6e6e74; }
        """),
        "app.js": ("text/javascript; charset=utf-8", "document.title = 'classic ran';"),
        "mod.js": ("text/javascript; charset=utf-8", """
        document.documentElement.dataset.module = 'yes';
        document.getElementById('ran').textContent = 'Scripts: classic, inline and module ran · fetch is ' + (typeof fetch);
        """),
    ]

    /// `path` as obid answers it: the file with its type and obid's headers, or 404.
    static func answer(_ path: String, files: [String: (type: String, body: String)] = files) -> (Data, HTTPURLResponse) {
        let url = URL(string: "http://127.0.0.1/v1/artifacts/a1/1/\(path)")!
        guard let file = files[path] else { return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!) }
        let headers = ["Content-Type": file.type, "Content-Security-Policy": ArtifactPage.policy,
                       "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer"]
        return (Data(file.body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    /// What the page did, once it has: its title, the probe's colour, which scripts ran, its origin
    /// and whether WebRTC is there.
    static func read(_ web: WKWebView) async throws -> [String: Any] {
        let probe = """
        JSON.stringify({ready: document.readyState, title: document.title,
          color: document.getElementById('probe') ? getComputedStyle(document.getElementById('probe')).color : null,
          inline: document.body ? (document.body.dataset.inline || null) : null, module: document.documentElement.dataset.module || null,
          origin: self.origin, rtc: typeof window.RTCPeerConnection})
        """
        var last: [String: Any] = [:]
        // Up to 10 seconds: until the page loaded and its module ran (about:blank comes first).
        for _ in 0..<100 {
            if let json = try? await web.evaluateJavaScript(probe) as? String,
               let seen = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                last = seen
                if seen["ready"] as? String == "complete", seen["title"] as? String == "classic ran", seen["module"] is String { return seen }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return last
    }
}
#endif
#endif
