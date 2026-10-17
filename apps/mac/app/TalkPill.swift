import AppKit
import SwiftUI

/// Where a turn started with the talk key is (#528): listening while you hold it, thinking while
/// Oby works out the answer, speaking while it reads the answer out.
nonisolated enum TalkStage: Equatable, Sendable {
    case listening, thinking, speaking

    var word: String {
        switch self {
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        }
    }

    /// Whether the pill shows: while the window isn't showing the turn itself (the conversation, with
    /// its Listening line and Oby's thread), and a turn is under way.
    static func shows(_ stage: TalkStage?, windowShowsTalk: Bool) -> Bool { stage != nil && !windowShowsTalk }
}

/// A small pill over the screen while the talk key's turn is under way and the Oby window isn't
/// showing it (#528): "Listening" while fn is held or hands-free is on, then "Thinking", then
/// "Speaking", and gone. It never takes a click or the keyboard, and it doesn't open the microphone:
/// that's the talk key's (apps/mac/app/TalkKey.swift) and Voice's alone.
final class TalkPillPanel: NSPanel {
    init(model: IslandModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: TalkPill(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Under the menu bar, centered on the screen with the mouse.
    func place() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let size = frame.size
        setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12))
    }
}

struct TalkPill: View {
    let model: IslandModel

    /// What it says: the stage, or why Oby can't listen.
    private var line: String {
        if model.turn == .listening, let problem = model.voice.problem { return problem }
        return model.turn?.word ?? ""
    }

    var body: some View {
        let stage = model.turn
        HStack(spacing: 10) {
            if stage == .listening { Waveform(levels: model.voice.levels) }
            else { Circle().fill(.white.opacity(0.7)).frame(width: 7, height: 7) }
            Text(line)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(.black.opacity(0.88), in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stage?.word ?? "")
    }
}

/// The microphone's loudness, one bar per moment, newest on the right.
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.suffix(12).indices, id: \.self) { index in
                Capsule().frame(width: 2.5, height: 3 + 13 * CGFloat(levels[index]))
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}
