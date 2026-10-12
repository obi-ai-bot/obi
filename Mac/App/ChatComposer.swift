import AppKit
import SwiftUI

/// The text's layout controls growth, including wrapped and pasted lines; the viewport caps it.
nonisolated enum ComposerMetrics {
    static let lineHeight: CGFloat = 22
    static func height(lines: Int, maximum: CGFloat) -> CGFloat {
        min(max(lineHeight, maximum), CGFloat(max(1, lines)) * lineHeight)
    }

    @MainActor static func lines(_ text: String, width: CGFloat) -> Int {
        guard !text.isEmpty else { return 1 }
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        var count = 0
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in count += 1 }
        // AppKit lays out the empty line after a final newline separately.
        if text.hasSuffix("\n") { count += 1 }
        return max(1, count)
    }
}

/// One composer on both Mac chat surfaces. Text is plain, preserving pasted line breaks.
struct ChatComposer: View {
    @Binding var text: String
    @Binding var focused: Bool
    let tray: Tray
    var maximumHeight: CGFloat = 300
    let onSend: () -> Void
    let onScreenshot: () -> Void
    let onStop: () -> Void
    @State private var width: CGFloat = 300

    private var lines: Int { ComposerMetrics.lines(text, width: width) }
    private var editorHeight: CGFloat { ComposerMetrics.height(lines: lines, maximum: maximumHeight - 28) }
    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: OBYStyle.Space.sm) {
            TrayRow(tray: tray)
            HStack(alignment: .bottom, spacing: OBYStyle.Space.sm) {
                Menu {
                    Button("Screenshot", action: onScreenshot).disabled(tray.capturing)
                    Button("Clipboard", action: tray.pasteClipboard)
                    Button("File", action: tray.chooseFile)
                } label: {
                    Image(systemName: "plus").font(OBYStyle.body.weight(.medium)).frame(width: 30, height: 34)
                }
                .menuStyle(.borderlessButton).fixedSize().padding(.bottom, 9)
                .accessibilityLabel("Add attachment")
                ComposerEditor(text: $text, focused: $focused, onSend: onSend, onStop: onStop)
                    .frame(height: editorHeight)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Message Oby").font(OBYStyle.body).foregroundStyle(OBYStyle.tertiary)
                                .padding(.top, 2).allowsHitTesting(false)
                        }
                    }
                    .padding(.vertical, 14)
                if empty {
                    Image(systemName: "mic").font(OBYStyle.body.weight(.medium))
                        .foregroundStyle(OBYStyle.userText).frame(width: 34, height: 34)
                        .background(OBYStyle.userBubble, in: Circle()).padding(.bottom, 9)
                        .help("Hold fn (or Control-Option) to talk")
                        .accessibilityLabel("Hold fn to talk")
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up").font(OBYStyle.body.weight(.bold))
                            .foregroundStyle(OBYStyle.userText).frame(width: 34, height: 34)
                            .background(OBYStyle.userBubble, in: Circle())
                    }
                    .buttonStyle(.plain).padding(.bottom, 9).accessibilityLabel("Send")
                }
            }
            .padding(.leading, OBYStyle.Space.md).padding(.trailing, OBYStyle.Space.sm)
            .frame(minHeight: 52)
            .background(OBYStyle.composer, in: RoundedRectangle(cornerRadius: lines > 1 ? OBYStyle.expandedComposer : 26))
        }
    }
}

private struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    final class Editor: NSTextView {
        var send: () -> Void = {}
        var stop: () -> Void = {}
        override func keyDown(with event: NSEvent) {
            // Let the input method finish composing before interpreting Return as Send.
            if event.keyCode == 36, !hasMarkedText(), !event.modifierFlags.contains(.shift) { send(); return }
            if event.keyCode == 53, !hasMarkedText() { stop(); return }
            super.keyDown(with: event)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        var requestedFocus = false
        init(_ parent: ComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused = false }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = Editor(frame: .zero)
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.isGraphicsImportAllowed = false
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 300, height: .greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Message Oby")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        context.coordinator.parent = self
        editor.send = onSend
        editor.stop = onStop
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
        }
        if focused && !context.coordinator.requestedFocus {
            DispatchQueue.main.async { if let window = editor.window { window.makeFirstResponder(editor) } }
        }
        context.coordinator.requestedFocus = focused
    }
}
