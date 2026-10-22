import AppKit
import SwiftUI

/// How long the splash stays: at least two seconds, and until Oby's first frame, never past `most`.
enum SplashGate {
    static let least = 2.0
    static let most = 4.5

    static func open(elapsed: TimeInterval, ready: Bool) -> Bool {
        elapsed >= most || (ready && elapsed >= least)
    }
}

/// A small panel in front of the window while Oby and its character are still coming up.
struct SplashMark: View {
    let character: ObyCharacter
    let finish: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var began = Date()

    var body: some View {
        let ready = character.ready
        VStack(spacing: 18) {
            ObyMark(size: 200)
            Text("Oby").font(Tokens.font(22, .semibold)).foregroundStyle(Tokens.ink)
            Bone(width: 56, height: 3, radius: 2)
        }
        .padding(.horizontal, 48).padding(.vertical, 36)
        .frame(width: 340)
        .background(Tokens.bg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Tokens.surfaceEdge) }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Oby")
        .onChange(of: ready) { _, ready in leave(ready) }
        .task {
            try? await Task.sleep(for: .seconds(SplashGate.least))
            leave(character.ready)
            try? await Task.sleep(for: .seconds(SplashGate.most - SplashGate.least))
            leave(true)
        }
    }

    private func leave(_ ready: Bool) {
        guard SplashGate.open(elapsed: began.timeIntervalSinceNow.magnitude, ready: ready) else { return }
        finish(reduce)
    }
}
