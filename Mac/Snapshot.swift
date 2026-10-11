import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

/// A file the user attached to their next request: a screenshot, or what they copied.
struct Attachment: Identifiable, Equatable {
    enum Kind { case screenshot, clipboardImage, clipboardText }
    var kind: Kind
    var file: URL
    var id: URL { file }

    var label: String {
        switch kind {
        case .screenshot: "Screenshot"
        case .clipboardImage: "Clipboard image"
        case .clipboardText: "Clipboard text"
        }
    }

    var icon: String {
        switch kind {
        case .screenshot: "camera.viewfinder"
        case .clipboardImage, .clipboardText: "doc.on.clipboard"
        }
    }
}

/// The chips by the field: what goes with the request, until its jobs are dispatched. Oby looks at
/// the screen only when you click the camera, and reads the clipboard only when you click its chip.
@Observable
final class Tray {
    enum Problem: Equatable {
        /// Screen Recording is off for Oby: the island says how to turn it on.
        case screenRecording
        case other(String)
    }

    private(set) var items: [Attachment] = []
    /// Why the last capture or paste didn't work, until one does.
    var problem: Problem?
    private(set) var capturing = false

    /// Where attachments wait for their jobs: Workspace.prepare copies them into the job's worktree.
    static let folder = Workspace.root.appending(path: "attachments")

    init() {
        // ponytail: a job copies its attachments when its worktree is ready, so they're kept a week
        // rather than tracked; a request dispatched later than that goes without them.
        let old = Date.now.addingTimeInterval(-7 * 24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now) < old {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The line the brain reads with your words, so "fix this" has something to point at.
    var note: String? {
        guard !items.isEmpty else { return nil }
        let screenshots = items.filter { $0.kind == .screenshot }.count
        var parts: [String] = []
        if screenshots > 0 { parts.append(screenshots == 1 ? "a screenshot" : "\(screenshots) screenshots") }
        if items.contains(where: { $0.kind != .screenshot }) { parts.append("what they copied") }
        return "(The user attached \(parts.joined(separator: " and ")).)"
    }

    /// The draft's job with the attachments, for Dispatch.
    func attach(_ draft: Desk.Draft) -> Desk.Draft {
        var draft = draft
        draft.job.attachments = items.isEmpty ? nil : items.map(\.file.path)
        return draft
    }

    /// The request went out: the chips go, and the files stay for its jobs.
    func clear() {
        items = []
        problem = nil
    }

    func remove(_ item: Attachment) {
        items.removeAll { $0 == item }
        try? FileManager.default.removeItem(at: item.file)
    }

    /// The camera: drag over part of any screen, or click for a whole one. Without Screen Recording,
    /// macOS asks the first time, and the island says how to turn it on.
    func screenshot() async {
        guard !capturing else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            problem = .screenRecording
            return
        }
        capturing = true
        defer { capturing = false }
        guard let pick = await SelectionOverlay.pick() else { return }
        do {
            // The overlay is gone from the screen before anything is captured.
            try await Task.sleep(for: .milliseconds(150))
            let image = try await ScreenShot.capture(pick)
            try add(.screenshot, png: image)
        } catch let error as SCStreamError where error.code == .userDeclined {
            problem = .screenRecording
        } catch {
            problem = .other("Oby couldn't capture the screen: \(error.localizedDescription)")
        }
    }

    /// The clipboard chip: reads what you copied now, and only now. Text first: a copied paragraph
    /// often carries a picture of itself too.
    func pasteClipboard() {
        let board = NSPasteboard.general
        do {
            if let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try add(.clipboardText, data: Data(text.utf8), extension: "txt")
            } else if let image = NSImage(pasteboard: board)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                try add(.clipboardImage, png: ScreenShot.fitted(image))
            } else {
                problem = .other("The clipboard has no text or image to attach.")
            }
        } catch {
            problem = .other("Oby couldn't attach the clipboard: \(error.localizedDescription)")
        }
    }

    private func add(_ kind: Attachment.Kind, png image: CGImage) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Shell.Failure(message: "the image couldn't be saved.")
        }
        try add(kind, data: data, extension: "png")
    }

    private func add(_ kind: Attachment.Kind, data: Data, extension ext: String) throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let name = kind == .screenshot ? "screenshot" : "clipboard"
        let file = Self.folder.appending(path: "\(name)-\(UUID().uuidString.prefix(6).lowercased()).\(ext)")
        try data.write(to: file)
        items.append(Attachment(kind: kind, file: file))
        problem = nil
    }
}

/// A screen and the part of it the user picked: points from its top-left corner, nil for all of it.
struct ScreenPick {
    var screen: NSScreen
    var rect: CGRect?
}

/// ScreenCaptureKit's one-shot capture, without Oby's own windows.
enum ScreenShot {
    /// The longest side an image keeps: about what Claude looks at, and still sharp enough to read.
    static let maxSide: CGFloat = 1568

    static func capture(_ pick: ScreenPick) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = pick.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == id }) else {
            throw Shell.Failure(message: "that screen isn't there any more.")
        }
        let oby = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: oby, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let rect = pick.rect ?? CGRect(origin: .zero, size: pick.screen.frame.size)
        if pick.rect != nil { configuration.sourceRect = rect }
        let scale = min(pick.screen.backingScaleFactor, maxSide / max(rect.width, rect.height))
        configuration.width = max(1, Int(rect.width * scale))
        configuration.height = max(1, Int(rect.height * scale))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The image, scaled down to `maxSide` if it's bigger.
    static func fitted(_ image: CGImage) -> CGImage {
        let scale = maxSide / CGFloat(max(image.width, image.height))
        guard scale < 1 else { return image }
        let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

/// A dimmed window on every screen: drag over part of one, or click for all of it. Escape cancels.
final class SelectionOverlay {
    private static var current: SelectionOverlay?
    private var windows: [NSPanel] = []
    private var done: ((ScreenPick?) -> Void)?

    /// What the user picked, or nil when they pressed Escape.
    static func pick() async -> ScreenPick? {
        current?.finish(nil)
        return await withCheckedContinuation { continuation in
            let overlay = SelectionOverlay()
            overlay.done = { continuation.resume(returning: $0) }
            current = overlay
            overlay.show()
        }
    }

    private func show() {
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onPick = { [weak self] rect in self?.finish(ScreenPick(screen: screen, rect: rect)) }
            view.onCancel = { [weak self] in self?.finish(nil) }
            panel.contentView = view
            panel.orderFrontRegardless()
            windows.append(panel)
        }
        // The screen under the pointer takes Escape.
        let mouse = NSEvent.mouseLocation
        if let key = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first {
            key.makeKey()
            _ = key.makeFirstResponder(key.contentView)
        }
    }

    private func finish(_ pick: ScreenPick?) {
        guard let done else { return }
        self.done = nil
        for window in windows { window.orderOut(nil) }
        windows = []
        Self.current = nil
        done(pick)
    }
}

/// Above everything, the menu bar and the island included, without activating Oby.
private final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

/// The dimmed screen, the rectangle being dragged, and how to use it.
private final class SelectionView: NSView {
    var onPick: (CGRect?) -> Void = { _ in }
    var onCancel: () -> Void = {}
    private var start: CGPoint?
    private var rect: CGRect?

    // Top-left origin, as ScreenCaptureKit's sourceRect.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        rect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // A click, or a drag too small to mean a part: the whole screen.
        if let rect, rect.width >= 8, rect.height >= 8 { onPick(rect) } else { onPick(nil) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let rect {
            rect.fill(using: .clear)
            NSColor.white.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return
        }
        let hint = "Drag over what Oby should see · Click for the whole screen · Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        let size = hint.size(withAttributes: attributes)
        let box = CGRect(x: bounds.midX - size.width / 2 - 16, y: bounds.midY - size.height / 2 - 10, width: size.width + 32, height: size.height + 20)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        hint.draw(at: CGPoint(x: box.minX + 16, y: box.minY + 10), withAttributes: attributes)
    }
}

/// The chips, each with a way to take it off, and why the last capture didn't work: without Screen
/// Recording, how to turn it on.
struct TrayRow: View {
    let tray: Tray

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tray.items.isEmpty {
                HStack(spacing: 8) {
                    ForEach(tray.items) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.icon)
                            Text(item.label)
                            Button { tray.remove(item) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(item.label)")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(.white.opacity(0.12), in: Capsule())
                    }
                }
            }
            switch tray.problem {
            case .screenRecording:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Oby needs Screen Recording to see your screen. In System Settings › Privacy & Security › Screen & System Audio Recording, turn on Oby, then click the camera again. macOS may ask you to reopen Oby first.")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            _ = NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(.white.opacity(0.12), in: Capsule())
                }
            case .other(let problem):
                Text(problem).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
            case nil:
                EmptyView()
            }
        }
    }
}
