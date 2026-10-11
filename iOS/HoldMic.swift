import SwiftUI
import UIKit

/// UIKit tracking gives touch-up and touch-cancel distinct paths, including system interruptions.
/// Sliding up locks; sliding left cancels. A locked control is Stop and send, never a toggle.
struct HoldMic: UIViewRepresentable {
    let listening: Bool
    let locked: Bool
    let enabled: Bool
    let start: () -> Void
    let lock: () -> Bool
    let release: () -> Void
    let cancel: () -> Void
    let stop: () -> Void

    func makeUIView(context: Context) -> MicControl { MicControl() }

    func updateUIView(_ view: MicControl, context: Context) {
        view.start = start
        view.lock = lock
        view.stop = stop
        view.locked = locked
        view.release = release
        view.cancel = cancel
        view.isEnabled = enabled
        view.tintColor = listening ? .systemRed : .label
        view.icon.image = UIImage(systemName: locked ? "stop.fill" : listening ? "waveform" : "mic.fill")
        view.accessibilityLabel = locked ? "Stop and send" : "Hold to talk"
        view.accessibilityHint = locked ? "Stops listening and sends your words." : "Slide up to lock. Slide left to cancel."
    }

    final class MicControl: UIControl {
        var start: () -> Void = {}
        var lock: () -> Bool = { false }
        var stop: () -> Void = {}
        var locked = false
        private var origin = CGPoint.zero
        private var resolved = false
        var release: () -> Void = {}
        var cancel: () -> Void = {}
        fileprivate let icon = UIImageView(image: UIImage(systemName: "mic.fill"))

        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            accessibilityLabel = "Hold to talk"
            accessibilityHint = "Slide up to lock. Slide left to cancel."
            accessibilityTraits = .button
            icon.contentMode = .center
            icon.isUserInteractionEnabled = false
            addSubview(icon)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); icon.frame = bounds }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard isEnabled else { return false }
            if locked { stop(); return false }
            origin = touch.location(in: self)
            resolved = false
            start()
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard !resolved else { return true }
            let point = touch.location(in: self)
            let dx = point.x - origin.x, dy = point.y - origin.y
            if dx <= -60, abs(dx) > abs(dy) {
                resolved = true
                cancel()
            } else if dy <= -50, abs(dy) >= abs(dx) {
                // Only lock an active microphone; preparation cannot become hands-free.
                resolved = lock()
            }
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            if !resolved { release() }
        }
        override func cancelTracking(with event: UIEvent?) { cancel() }
        override func accessibilityActivate() -> Bool {
            guard locked else { return false }
            stop()
            return true
        }
    }
}
