import SwiftUI
import UIKit

/// UIKit tracking gives touch-up and touch-cancel distinct paths, including system interruptions.
/// Accessibility users hold with the system's double-tap-and-hold gesture; activation cannot latch it on.
struct HoldMic: UIViewRepresentable {
    let held: Bool
    let enabled: Bool
    let start: () -> Void
    let release: () -> Void
    let cancel: () -> Void

    func makeUIView(context: Context) -> MicControl { MicControl() }

    func updateUIView(_ view: MicControl, context: Context) {
        view.start = start
        view.release = release
        view.cancel = cancel
        view.isEnabled = enabled
        view.tintColor = held ? .systemRed : .label
        view.setNeedsDisplay()
    }

    final class MicControl: UIControl {
        var start: () -> Void = {}
        var release: () -> Void = {}
        var cancel: () -> Void = {}
        private let icon = UIImageView(image: UIImage(systemName: "mic.fill"))

        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            accessibilityLabel = "Hold to talk"
            accessibilityHint = "Hold while speaking. Release to send."
            accessibilityTraits = .button
            icon.contentMode = .center
            icon.isUserInteractionEnabled = false
            addSubview(icon)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); icon.frame = bounds }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard isEnabled else { return false }
            start()
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) { release() }
        override func cancelTracking(with event: UIEvent?) { cancel() }
        override func accessibilityActivate() -> Bool { false }
    }
}
