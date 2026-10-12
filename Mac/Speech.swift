import AVFoundation
import Foundation
import Observation

/// Oby's voice: when you talked (fn), it reads its reply out loud with the most natural voice this
/// Mac has for the reply's language (`VoiceSettings.voice`, as on the iPhone; Settings › General ›
/// Voice). Pressing fn stops it at once.
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var speaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// The utterance under way, so a late delegate call for an earlier one changes nothing.
    @ObservationIgnored private var current: AVSpeechUtterance?
    /// Called when the current utterance ends: true when it was heard through, false when stopped.
    @ObservationIgnored private var done: ((Bool) -> Void)?

    /// The UserDefaults key of the setting.
    nonisolated static let setting = "speaksReplies"

    /// Whether Oby speaks its replies to what you said out loud: on until it's turned off.
    static var on: Bool {
        UserDefaults.standard.object(forKey: setting) == nil || UserDefaults.standard.bool(forKey: setting)
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Says `text`, stopping whatever it was saying. `done` hears how it ended.
    func speak(_ text: String, done: @escaping (Bool) -> Void) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceSettings.voice(for: text)
        current = utterance
        self.done = done
        speaking = true
        synthesizer.speak(utterance)
    }

    /// Quiet, now.
    func stop() {
        guard let utterance = current else { return }
        ended(ObjectIdentifier(utterance), heard: false)
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// `id` is the utterance that ended, by identity: only the current one counts.
    private func ended(_ id: ObjectIdentifier, heard: Bool) {
        guard let current, ObjectIdentifier(current) == id else { return }
        self.current = nil
        speaking = false
        let done = self.done
        self.done = nil
        done?(heard)
    }

    // The utterance isn't Sendable, so only its identity crosses to the main actor.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id, heard: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id, heard: false) }
    }
}
