import SwiftUI

/// A single accessible toggle; the meter reflects input volume only during capture.
struct DictationMic: View {
    let active: Bool
    let listening: Bool
    let finishing: Bool
    let level: Float
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 3) {
                Image(systemName: active ? "stop.fill" : "mic.fill")
                    .font(.body)
                if listening {
                    Capsule()
                        .fill(Color.red.opacity(0.5))
                        .frame(width: 6 + CGFloat(level) * 18, height: 3)
                }
            }
            .foregroundStyle(listening ? Color.red : Color.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(finishing)
        .accessibilityLabel(active ? "Stop dictating" : "Dictate")
        .accessibilityHint(active ? "Keeps your words in the text field for editing." : "Tap to add spoken words to your draft.")
    }
}
