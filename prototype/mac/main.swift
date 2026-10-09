import Cocoa
import WebKit

// Menu bar host for the cube mascot: a status item with a tiny blinking cube,
// and a popover that runs the web prototype (../web/index.html, bundled).

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var webView: WKWebView!
    private var blinkTimer: Timer?

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
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 470), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }

        let vc = NSViewController()
        vc.view = webView
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 380, height: 470)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)

        scheduleBlink()
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Quit Cube", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // Blink the menu bar icon every few seconds, sometimes twice.
    private func scheduleBlink() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 2.5...6), repeats: false) { [weak self] _ in
            self?.blink(times: Double.random(in: 0...1) < 0.2 ? 2 : 1)
        }
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
