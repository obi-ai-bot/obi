import SwiftUI
import UIKit

/// Oby, animated: frames rendered from character/oby.html (apps/watch/README.md) played at 15 fps,
/// since watchOS has no WebKit. It plays only while it's on screen, the app is in front,
/// the wrist is up and Reduce Motion is off; otherwise it holds the loop's first frame, Oby calm.
/// A reaction plays once over the loop, then the loop starts again from its first frame: both
/// end and start calm.
struct ObyAnimation: View {
    enum Loop: String, CaseIterable {
        case idle, working, needs
    }

    /// A reaction to play once. `tap` tells one tap from the next, so a tap during a reaction
    /// starts it again.
    struct Once: Equatable {
        let reaction: Pokes.Reaction
        let tap: Int
    }

    let loop: Loop
    var once: Once?
    /// Home gives the frames their own square inside its safe area.
    var contentMode: ContentMode = .fit

    @State private var onScreen = false
    /// When the loop's first frame plays: now, or when the reaction playing ends.
    @State private var start = Date.now
    /// When the reaction started; nil once Oby stopped moving.
    @State private var began: Date?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let fps = 15.0

    private var paused: Bool { !onScreen || scenePhase != .active || isLuminanceReduced || reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.fps, paused: paused)) { context in
            Image(paused ? Self.frame(loop, 0) : image(at: context.date))
                .resizable()
                .aspectRatio(contentMode: contentMode)
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: loop) { if playing(at: .now) == nil { start = .now } }
        .onChange(of: once) {
            guard let once, !paused else { return }
            let now = Date.now
            began = now
            start = now.addingTimeInterval(Double(Self.count(once.reaction.rawValue)) / Self.fps)
        }
        // Oby stopped moving: the reaction is dropped, and the loop starts again when he moves.
        .onChange(of: paused) {
            began = nil
            if !paused { start = .now }
        }
        .accessibilityLabel("Oby")
    }

    private func image(at date: Date) -> String {
        if let once, let index = playing(at: date) {
            return Self.image(once.reaction.rawValue, index)
        }
        return Self.frame(loop, Int(date.timeIntervalSince(start) * Self.fps))
    }

    /// The reaction's frame at `date`, or nil when none is playing.
    private func playing(at date: Date) -> Int? {
        guard let once, let began else { return nil }
        let index = max(0, Int(date.timeIntervalSince(began) * Self.fps))
        return index < Self.count(once.reaction.rawValue) ? index : nil
    }

    /// The image set of a frame, `oby-idle-007`; past the end it wraps around.
    static func frame(_ loop: Loop, _ index: Int) -> String {
        let count = Self.count(loop.rawValue)
        return Self.image(loop.rawValue, ((index % count) + count) % count)
    }

    private static func image(_ sequence: String, _ index: Int) -> String {
        String(format: "oby-%@-%03d", sequence, index)
    }

    private static func count(_ sequence: String) -> Int { counts[sequence] ?? 1 }

    /// How many frames each loop and reaction has in Frames.xcassets, counted once, so rendering
    /// them again with other lengths needs no change here.
    private static let counts: [String: Int] = Dictionary(uniqueKeysWithValues:
        (Loop.allCases.map(\.rawValue) + Pokes.Reaction.allCases.map(\.rawValue)).map { sequence in
            var count = 0
            while UIImage(named: Self.image(sequence, count)) != nil { count += 1 }
            return (sequence, max(count, 1))
        })
}
