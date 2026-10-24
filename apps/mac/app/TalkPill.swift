import AppKit
import SwiftUI

/// Where a turn started with the talk key is (#528): listening while you hold it, thinking while
/// Oby works out the answer, then its reply, in writing (the owner's decision of 2026-10-23: Oby
/// answers in text, never aloud).
nonisolated enum TalkStage: Equatable, Sendable {
    case listening, thinking, replied

    /// How long the pill shows Oby's reply, unless the next press comes first.
    static let replyShows: Duration = .seconds(8)

    /// Whether the pill shows: a turn is under way and the window isn't showing it. Home and the
    /// conversation page show what you say (their Listening line), but only the conversation shows
    /// Oby's reply: while a reply shows, Home in front doesn't keep the pill away.
    static func shows(_ stage: TalkStage?, reply: Bool, windowShowsTalk: Bool, windowShowsConversation: Bool) -> Bool {
        stage != nil && !(reply ? windowShowsConversation : windowShowsTalk)
    }

    /// Where the turn goes once Oby's reply shows: after hands-free words (fn + Space) Oby listens
    /// again at once, the reply still above, unless a talk key is down (that press is yours: the
    /// reply shows and your own turn starts); while you're talking again already, that turn
    /// carries on (nil); else the reply shows on its own.
    static func afterReply(handsFree: Bool, keyDown: Bool, talking: Bool) -> TalkStage? {
        talking ? nil : handsFree && !keyDown ? .listening : .replied
    }

    /// The pill's line under the reply: your words as you talk (or why Oby can't listen), then
    /// "Thinking"; none once only the reply shows.
    static func line(_ stage: TalkStage?, words: String, problem: String?) -> String? {
        switch stage {
        case .listening: problem ?? (words.isEmpty ? "Listening" : words)
        case .thinking: "Thinking"
        case .replied, nil: nil
        }
    }
}

/// A small pill over the screen while the talk key's turn is under way and the Oby window isn't
/// showing it (#528): your words as you say them while fn is held or hands-free is on, then
/// "Thinking", then the first lines of Oby's reply for a few seconds, and gone. It never takes a
/// click or the keyboard, and it doesn't open the microphone: that's the talk key's
/// (apps/mac/app/TalkKey.swift) and Voice's alone.
final class TalkPillPanel: NSPanel {
    init(model: IslandModel) {
        // Room for a reply's first lines; what the pill doesn't draw is clear and takes no click.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 160), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // The pill draws its own shadow: the window's would keep the shape of an earlier stage.
        hasShadow = false
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
        // The pill keeps 12 points of its own room on top (`TalkPill`'s padding).
        setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 4))
    }
}

struct TalkPill: View {
    let model: IslandModel

    var body: some View {
        let stage = model.turn
        VStack(alignment: .leading, spacing: 8) {
            if let reply = model.reply {
                Text(reply)
                    .font(.system(size: 13))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = TalkStage.line(stage, words: model.voice.words, problem: model.voice.problem) {
                HStack(spacing: 10) {
                    if stage == .listening { Waveform(levels: model.voice.levels) }
                    else { Circle().fill(.white.opacity(0.7)).frame(width: 7, height: 7) }
                    // The newest words stay in sight.
                    Text(line)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 36)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
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
