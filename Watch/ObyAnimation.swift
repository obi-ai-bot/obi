import SwiftUI
import UIKit

/// Oby, animated: frames rendered from Character/oby.html (Watch/README.md) played at 15 fps,
/// since watchOS has no WebKit. It plays only while it's on screen, the app is in front,
/// the wrist is up and Reduce Motion is off; otherwise it holds the loop's first frame, Oby calm.
struct ObyAnimation: View {
    enum Loop: String, CaseIterable {
        case idle, working, needs
    }

    let loop: Loop

    @State private var onScreen = false
    /// When the loop started, so a new loop plays from its first frame.
    @State private var start = Date.now
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let fps = 15.0

    private var paused: Bool { !onScreen || scenePhase != .active || isLuminanceReduced || reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.fps, paused: paused)) { context in
            Image(Self.frame(loop, paused ? 0 : Int(context.date.timeIntervalSince(start) * Self.fps)))
                .resizable()
                .scaledToFit()
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .onChange(of: loop) { start = .now }
        .onChange(of: paused) { if !paused { start = .now } }
        .accessibilityLabel("Oby")
    }

    /// The image set of a frame, `oby-idle-007`; past the end it wraps around.
    static func frame(_ loop: Loop, _ index: Int) -> String {
        let count = counts[loop] ?? 1
        return String(format: "oby-%@-%03d", loop.rawValue, ((index % count) + count) % count)
    }

    /// How many frames each loop has in Frames.xcassets, counted once, so rendering the loops
    /// again with other lengths needs no change here.
    private static let counts: [Loop: Int] = Dictionary(uniqueKeysWithValues: Loop.allCases.map { loop in
        var count = 0
        while UIImage(named: String(format: "oby-%@-%03d", loop.rawValue, count)) != nil { count += 1 }
        return (loop, max(count, 1))
    })
}
