import AVFoundation
import Foundation
import Observation

/// Oby's voice: when you talked (fn), it reads its reply out loud with the most natural English
/// voice this Mac has (Settings › General › Oby speaks its replies). Pressing fn stops it at once.
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
        utterance.voice = Self.voice
        current = utterance
        self.done = done
        speaking = true
        synthesizer.speak(utterance)
    }

    /// Quiet, now.
    func stop() {
        guard let utterance = current else { return }
        ended(utterance, heard: false)
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func ended(_ utterance: AVSpeechUtterance, heard: Bool) {
        guard utterance === current else { return }
        current = nil
        speaking = false
        let done = self.done
        self.done = nil
        done?(heard)
    }

    /// The most natural English voice installed: a premium one (the Siri-quality downloads), then
    /// an enhanced one, then whatever the system has, US English first.
    static let voice: AVSpeechSynthesisVoice? = {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int) {
            (voice.quality == .premium ? 0 : voice.quality == .enhanced ? 1 : 2, voice.language == "en-US" ? 0 : 1)
        }
        return voices.min { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.ended(utterance, heard: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.ended(utterance, heard: false) }
    }
}
