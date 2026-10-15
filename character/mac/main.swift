import Cocoa
import WebKit

// Sample menu bar host for Oby: a status item with a tiny blinking Oby, and a
// popover that runs oby.html (bundled with vendor/). Shows how an app drives
// Oby: call oby.setState / oby.play with evaluateJavaScript, and hear back
// from it through the "oby" message handler. Right-click the icon to try it.

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var webView: WKWebView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.cubeIcon(eyesOpen: true)
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.userContentController.add(self, name: "oby")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 470), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        if let page = Bundle.main.url(forResource: "oby", withExtension: "html", subdirectory: "web") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }

        let vc = NSViewController()
        vc.view = webView
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 380, height: 470)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        scheduleBlink()
    }

    // Talking to Oby: any line of its API, e.g. oby("setState('thinking')").
    private func oby(_ call: String) {
        webView.evaluateJavaScript("window.oby && oby.\(call)")
    }

    // Oby's events: { oby: "state" | "expression" | "end" | "poke", ... }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        print("oby:", message.body)
    }

    // The page only animates while the popover is open; closed, it draws nothing.
    private func setPaused(_ paused: Bool) { oby("pause(\(paused))") }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { setPaused(!popover.isShown) }
    // If the page's process dies, the popover would stay blank: load it again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
    func popoverWillShow(_ notification: Notification) { setPaused(false) }
    func popoverDidClose(_ notification: Notification) { setPaused(true) }

    @objc private func pickState(_ item: NSMenuItem) {
        guard let state = item.representedObject as? String else { return }
        oby("setState('\(state)', { now: true })")
        showPopover()
    }
    // "Hi Oby": wave, then listen
    @objc private func sayHi() {
        oby("play('Hello')")
        oby("setState('listening')")
        showPopover()
    }
    private func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            for state in ["idle", "listening", "thinking", "working", "quiet"] {
                let item = menu.addItem(withTitle: state.capitalized, action: #selector(pickState(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = state
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Say hi", action: #selector(sayHi), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Oby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    // Blink the menu bar icon every few seconds, sometimes twice.
    private func scheduleBlink() {
        let timer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 2.5...6), repeats: false) { [weak self] _ in
            self?.blink(times: Double.random(in: 0...1) < 0.2 ? 2 : 1)
        }
        timer.tolerance = 0.5  // lets the system batch the wakeups
    }

    private func blink(times: Int) {
        statusItem.button?.image = Self.cubeIcon(eyesOpen: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
            guard let self else { return }
            self.statusItem.button?.image = Self.cubeIcon(eyesOpen: true)
            if times > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { self.blink(times: times - 1) }
            } else {
                self.scheduleBlink()
            }
        }
    }

    // Menu bar icon: matches the default mascot, a wide soft block (0.93 x 0.75)
    // with just the two eyes.
    static func cubeIcon(eyesOpen: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3, width: 15, height: 12.1), xRadius: 5, yRadius: 5).fill()

            // eyes are cut out of the body
            ctx.compositingOperation = .clear
            let eyeH: CGFloat = eyesOpen ? 3.8 : 0.9
            let eyeY: CGFloat = eyesOpen ? 8.0 : 9.45
            for x in [4.9, 11.1] {
                NSBezierPath(roundedRect: NSRect(x: x, y: eyeY, width: 2.0, height: eyeH), xRadius: 1.0, yRadius: min(1.0, eyeH / 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
