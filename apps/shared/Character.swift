import Foundation
import OSLog
import WebKit

/// Sangam's character: `character/oby.html` and three.js, bundled into the app and served
/// from the `oby://` scheme so its ES modules load without file-URL tricks.
@Observable
final class ObyCharacter {
    let page: WebPage
    private let events = CharacterEvents()
    private var loaded = false
    private var paused = false

    init() {
        var config = WebPage.Configuration()
        config.urlSchemeHandlers[URLScheme("oby")!] = CharacterFiles()
        config.userContentController.add(events, name: "oby")
        page = WebPage(configuration: config)
        Task {
            do {
                for try await event in page.load(URLRequest(url: URL(string: "oby://character/oby.html?size=1.25")!))
                where event == .finished {
                    loaded = true
                    applyPause()
                }
            } catch {
                Logger.character.error("Oby's page didn't load: \(error.localizedDescription)")
            }
        }
    }

    /// What Oby does until told otherwise: idle, listening, thinking, working, quiet.
    func setState(_ state: String) { run("oby.setState(state, { now: true })", ["state": state]) }

    /// The state Oby shows whenever the island isn't closed.
    var mood = "idle" {
        didSet { if !paused, mood != oldValue { setState(mood) } }
    }

    /// One expression now, then back to the state.
    func play(_ expression: String) { run("oby.play(name)", ["name": expression]) }

    /// A paused Oby draws nothing, so a closed island costs no CPU.
    func pause(_ on: Bool) {
        guard on != paused else { return }
        paused = on
        applyPause()
    }

    private func applyPause() {
        guard paused else {
            run("oby.pause(false); oby.setState(state, { now: true })", ["state": mood])
            return
        }
        // Look ahead and settle into a calm face first: paused mid-fidget or mid-glance,
        // Oby would freeze looking away.
        run("document.dispatchEvent(new PointerEvent('pointerleave')); oby.setState('quiet', { now: true })", [:])
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if paused { run("oby.pause(true)", [:]) }
        }
    }

    /// The panel never becomes key while you work elsewhere, so the page gets no mouse
    /// events of its own: feed it the pointer, in the page's coordinates.
    func point(at p: CGPoint) {
        guard loaded else { return }
        run("dispatchEvent(new PointerEvent('pointermove', { clientX: x, clientY: y }))", ["x": p.x, "y": p.y])
    }

    private func run(_ js: String, _ arguments: [String: Any]) {
        guard loaded else { return }
        Task {
            do {
                // The page's own world: that's where oby.html put window.oby.
                let found = try await page.callJavaScript("if (!window.oby) return false; \(js); return true", arguments: arguments, contentWorld: .page)
                if found as? Bool != true { Logger.character.error("window.oby isn't on the page") }
            } catch {
                Logger.character.error("oby call failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Oby's events (state, expression, end, poke) come back here.
private final class CharacterEvents: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        Logger.character.debug("event \(String(describing: message.body), privacy: .public)")
    }
}

/// Serves the bundled character files, and nothing outside them.
nonisolated struct CharacterFiles: URLSchemeHandler {
    func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
        AsyncThrowingStream { stream in
            guard let url = request.url,
                  let root = Bundle.main.resourceURL?.appending(path: "Character").standardizedFileURL else {
                stream.finish(throwing: URLError(.badURL)); return
            }
            let file = root.appending(path: url.path).standardizedFileURL
            guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
                stream.finish(throwing: URLError(.fileDoesNotExist)); return
            }
            let mime = ["html": "text/html", "js": "text/javascript", "css": "text/css"][file.pathExtension] ?? "application/octet-stream"
            stream.yield(.response(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")))
            stream.yield(.data(data))
            stream.finish()
        }
    }
}

extension Logger {
    nonisolated static let character = Logger(subsystem: "com.deskree.oby", category: "character")
}
