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
    /// conversation page show what you say (their Listening line); only the conversation the words
    /// went to shows Oby's reply, so while a reply shows that's all that keeps the pill away.
    static func shows(_ stage: TalkStage?, reply: Bool, windowShowsTalk: Bool, windowShowsReply: Bool) -> Bool {
        stage != nil && !(reply ? windowShowsReply : windowShowsTalk)
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

/// The talk key's turn as `IslandController` keeps it, which does what it says: whether Oby's reply
/// listens again, whether VoiceOver has the reply, and whether Oby listens again by itself.
nonisolated struct TalkTurn: Equatable, Sendable {
    /// The words Oby is answering were asked hands-free (fn + Space): their reply listens again.
    /// Only words that were asked set it, their reply uses it up, and any press ends it: hands-free
    /// lasts until the next press (AGENTS.md).
    private(set) var handsFreeAsk = false
    /// A key went down since the last send, while its words are written down: they end hands-free too.
    private(set) var pressedSinceSend = false
    /// Oby listens again by itself after its reply: a press with no words ends that quietly.
    private(set) var relistening = false
    /// VoiceOver was given the reply: the next press cuts it off.
    private(set) var announced = false

    enum AfterReply: Equatable {
        /// Nothing to show: the turn ends, and nothing listens again.
        case end
        /// Oby listens again at once, the reply above.
        case listenAgain
        /// The reply shows on its own; VoiceOver reads it unless a key is going down.
        case show(announce: Bool)
        /// You're talking again already: that turn carries on, the reply above it.
        case carryOn
    }

    /// Oby's reply came. `keyDown`: a talk key is down or a turn it started is under way, so the
    /// press is yours and isn't taken over. `talking`: the microphone is open for your next words.
    mutating func replied(_ text: String, keyDown: Bool, talking: Bool) -> AfterReply {
        let handsFree = handsFreeAsk
        handsFreeAsk = false
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .end }
        if talking { return .carryOn }
        if handsFree, !keyDown {
            relistening = true
            return .listenAgain
        }
        announced = !keyDown
        return .show(announce: !keyDown)
    }

    /// A talk key went down: hands-free is over, and whether VoiceOver has to be cut off the reply.
    mutating func pressed() -> Bool {
        handsFreeAsk = false
        pressedSinceSend = true
        defer { announced = false }
        return announced
    }

    /// A turn of yours started: what Oby listened for by itself is over.
    mutating func started() { relistening = false }

    /// The microphone closed to send (after the press that ends hands-free, if any): whether it was
    /// Oby listening again by itself.
    mutating func closed() -> Bool {
        pressedSinceSend = false
        defer { relistening = false }
        return relistening
    }

    /// Escape: nothing is sent.
    mutating func cancelled() { relistening = false }

    /// Stop all, by its keys or the menu: the words waiting don't listen again once their reply shows.
    mutating func end() { handsFreeAsk = false }

    /// The words were written down. Words asked decide whether their reply listens again; a bare
    /// "stop" or "never mind", nothing heard, or a press while they were written down ends hands-free. True when nothing heard is worth
    /// saying ("Oby didn't catch that"): not when the press only ended Oby's listening again by
    /// itself, unless something went wrong (`problem`).
    mutating func heard(_ said: String, handsFree: Bool, again: Bool, problem: Bool) -> Bool {
        handsFreeAsk = handsFree && !pressedSinceSend && !said.isEmpty && !Conversation.cancels(said)
        return said.isEmpty && (problem || !again)
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
