import SwiftUI

/// Oby's face at rest, drawn still: Sangam's soft block with two eyes, as the menu bar icon and
/// the character have it. The window shows it beside Oby's words and in the sidebar; the live
/// character (Shared/Character.swift) stays in the notch, where one is enough.
struct ObyFace: View {
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(Color(white: 0.2))
            .overlay {
                HStack(spacing: size * 0.16) {
                    eye
                    eye
                }
            }
            .frame(width: size, height: size * 0.82)
            .accessibilityHidden(true)
    }

    private var eye: some View {
        Capsule().fill(.white).frame(width: size * 0.11, height: size * 0.22)
    }
}
