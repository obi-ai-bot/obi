import AppKit
import SwiftUI

/// The window's message box (Sangam's Composer.tsx, app.css `.composer-field`): one row of + /
/// text / voice-or-send, 46 points tall, edged like a pill. Once the text runs past a line it
/// stacks: the text full width over the + / voice-or-send row. It grows with what's typed up to
/// `maximumHeight` (#270: about half the window), then scrolls inside, and shrinks back once sent.
nonisolated enum BoxMetrics {
    static let lineHeight = Tokens.composerLine
    /// One row: 32-point buttons, 7 points from the edge (6 inside the 1-point outline).
    static let button: CGFloat = 32
    static let inset: CGFloat = 7
    static var rowHeight: CGFloat { button + 2 * inset }
    /// A line of text, centred on the row.
    static var textInset: CGFloat { (rowHeight - lineHeight) / 2 }
    /// Stacked, the text has 10 points above and below it and 12 either side.
    static let stackedPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    static let radius: CGFloat = 23

    /// The text's width on one row, between + and voice-or-send, in a box `width` wide.
    static func rowWidth(_ width: CGFloat) -> CGFloat { max(1, width - 2 * inset - 2 * button - 2 * 4 - 8) }
    /// Stacked, the text's width.
    static func stackedWidth(_ width: CGFloat) -> CGFloat { max(1, width - 2 * inset - stackedPadding.leading - stackedPadding.trailing) }

    /// Whether the box stacks: the text doesn't fit on the row's one line. Measured at the row's
    /// width whichever way it shows, so it never flips back and forth at the edge.
    @MainActor static func stacked(_ text: String, width: CGFloat) -> Bool {
        ComposerMetrics.lines(text, width: rowWidth(width)) > 1
    }

    /// The text's height: a line per line, up to what's left of `maximum` once the box's own room
    /// is taken; past that it scrolls.
    @MainActor static func textHeight(_ text: String, width: CGFloat, maximum: CGFloat) -> CGFloat {
        guard stacked(text, width: width) else { return lineHeight }
        let lines = ComposerMetrics.lines(text, width: stackedWidth(width))
        let room = maximum - 2 * inset - stackedPadding.top - stackedPadding.bottom - button
        return min(max(lineHeight, room), CGFloat(lines) * lineHeight)
    }

    /// The whole box's height for `text`.
    @MainActor static func height(_ text: String, width: CGFloat, maximum: CGFloat) -> CGFloat {
        guard stacked(text, width: width) else { return rowHeight }
        return 2 * inset + stackedPadding.top + textHeight(text, width: width, maximum: maximum) + stackedPadding.bottom + button
    }
}

struct MessageBox: View {
    @Binding var text: String
    @Binding var focused: Bool
    let tray: Tray
    var placeholder = "Message Oby"
    var label = "Message Oby"
    var maximumHeight: CGFloat = 300
    var focusRequest = 0
    let onSend: () -> Void
    let onScreenshot: () -> Void
    let onStop: () -> Bool
    @State private var width: CGFloat = 480
    @State private var hovering = false

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var stacked: Bool { BoxMetrics.stacked(text, width: width) }
    private var textHeight: CGFloat { BoxMetrics.textHeight(text, width: width, maximum: maximumHeight) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !tray.items.isEmpty { tags.padding(.bottom, 6) }
            if stacked {
                editor.padding(BoxMetrics.stackedPadding)
                HStack(spacing: 4) {
                    plus
                    Spacer(minLength: 0)
                    end
                }
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    plus
                    editor.padding(.horizontal, 4).padding(.vertical, BoxMetrics.textInset - BoxMetrics.inset)
                    end
                }
            }
        }
        .padding(BoxMetrics.inset)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay {
            RoundedRectangle(cornerRadius: BoxMetrics.radius, style: .continuous)
                .strokeBorder(hovering || focused ? Tokens.fieldEdgeOn : Tokens.line, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: BoxMetrics.radius, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Tokens.fade, value: hovering || focused)
        .overlay(alignment: .top) { problem.offset(y: -28) }
    }

    private var editor: some View {
        ComposerEditor(text: $text, focused: $focused, focusRequest: focusRequest, onSend: onSend, onStop: onStop,
                       lineHeight: BoxMetrics.lineHeight, textColor: NSColor(white: 1, alpha: 0.9), label: label)
            .frame(height: textHeight)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(Tokens.font(Tokens.textLg)).foregroundStyle(Tokens.muted)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(height: BoxMetrics.lineHeight)
                        .allowsHitTesting(false)
                }
            }
    }

    /// + : a screenshot, what you copied, or a file (Sangam's + panel's Add files; the Obys and tasks
    /// it can add come with obid).
    private var plus: some View {
        Menu {
            Button("Screenshot", action: onScreenshot).disabled(tray.capturing)
            Button("Clipboard", action: tray.pasteClipboard)
            Button("File…", action: tray.chooseFile)
        } label: {
            BoxIcon(symbol: "plus")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Add attachment")
    }

    /// Voice while the box is empty: the talk key does it, so it says how. Send once there's text.
    @ViewBuilder private var end: some View {
        ZStack {
            BoxIcon(symbol: "waveform")
                .help("Hold fn (or Control-Option) to talk")
                .accessibilityLabel("Hold fn to talk")
                .opacity(empty ? 1 : 0).scaleEffect(empty ? 1 : 0.4)
                .accessibilityHidden(!empty)
            Button(action: onSend) { BoxIcon(symbol: "arrow.up", color: Tokens.ink) }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
                .opacity(empty ? 0 : 1).scaleEffect(empty ? 0.4 : 1)
                .disabled(empty)
                .accessibilityHidden(empty)
        }
        .animation(Tokens.spring, value: empty)
    }

    /// What goes with the words, as tags over them.
    private var tags: some View {
        HStack(spacing: 6) {
            ForEach(tray.items) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.icon).font(Tokens.font(11)).foregroundStyle(Tokens.muted)
                    Text(item.label).lineLimit(1)
                    Button { tray.remove(item) } label: {
                        Image(systemName: "xmark").font(Tokens.font(9, .bold)).foregroundStyle(Tokens.muted)
                            .frame(width: 18, height: 18).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(item.label)")
                }
                .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.item)
                .padding(.leading, 6).padding(.trailing, 3).frame(height: 24)
                .background(Tokens.chipHover, in: Capsule())
            }
        }
        .padding(3)
    }

    /// Why the last screenshot or paste didn't work, over the box.
    @ViewBuilder private var problem: some View {
        switch tray.problem {
        case .screenRecording:
            Button("Oby needs Screen Recording to see your screen. Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    _ = NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.needs)
        case .other(let problem):
            Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).lineLimit(1)
        case nil:
            EmptyView()
        }
    }
}

/// One of the box's 32-point round icon buttons: muted at rest, ink with a faint fill hovered.
struct BoxIcon: View {
    let symbol: String
    var color = Tokens.muted
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol).font(Tokens.font(16, .regular))
            .foregroundStyle(hovering ? Tokens.ink : color)
            .frame(width: BoxMetrics.button, height: BoxMetrics.button)
            .background(hovering ? Tokens.hover : .clear, in: Circle())
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(Tokens.fade, value: hovering)
    }
}
