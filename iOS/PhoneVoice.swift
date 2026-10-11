import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

/// Owns the microphone for a held touch or an explicitly locked recording. Async preparation
/// checks the hold before opening it. Release or Stop closes hardware before finalizing words.
@MainActor @Observable
final class PhoneVoice {
    private(set) var held = false
    private(set) var finishing = false
    private(set) var listening = false
    private(set) var locked = false
    private(set) var words = ""
    private(set) var problem: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var speech: PhoneSpeech?
    @ObservationIgnored private var buffers: AsyncStream<AVAudioPCMBuffer>.Continuation?
    @ObservationIgnored private var feeding: Task<Void, Never>?
    @ObservationIgnored private var done: ((String) -> Void)?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var audioObservers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        audioObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.interrupted() }
        })
        audioObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory else { return }
            MainActor.assumeIsolated { self?.interrupted() }
        })
        audioObservers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            guard let changed = notification.object as? AVAudioEngine else { return }
            MainActor.assumeIsolated {
                guard let self, self.listening, self.engine === changed else { return }
                self.interrupted()
            }
        })
        for name in [AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
            audioObservers.append(center.addObserver(forName: name, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interrupted() }
            })
        }
    }

    deinit {
        for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private func interrupted() {
        guard held else { return }
        fail(RunnerError(message: "Listening was interrupted. Hold the mic to try again."), token: generation)
    }

    func start(context: [String], done: @escaping (String) -> Void) {
        guard !held, !finishing else { return }
        cancel()
        held = true
        self.done = done
        words = ""
        problem = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let token = generation
        work = Task {
            do {
                // Fail safely if a build omitted either required privacy reason, rather than let iOS terminate it.
                guard ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"].allSatisfy({
                    !(Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "").isEmpty
                }) else { throw RunnerError(message: "Voice input isn't available in this build. You can still type.") }
                // Request each permission separately. A release during either prompt never opens audio.
                let microphone = await AVAudioApplication.requestRecordPermission()
                let recognition = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
                }
                guard held, generation == token else { return }
                guard microphone, recognition else {
                    throw RunnerError(message: "Allow Microphone and Speech Recognition for Oby in Settings to talk. You can still type.")
                }
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement)
                // Lock feedback happens while capturing; iOS otherwise suppresses haptics.
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
                try session.setActive(true)
                let engine = AVAudioEngine()
                let source = engine.inputNode.outputFormat(forBus: 0)
                let speech = try await PhoneSpeech.make(request: UUID().uuidString, sampleRate: source.sampleRate,
                                                        sourceFormat: source, context: context,
                                                        onCancel: { [weak self] in
                    self?.fail(RunnerError(message: "Listening was interrupted. Hold the mic to try again."), token: token)
                }) { [weak self] words in
                    guard let self, self.generation == token else { return }
                    self.words = words
                }
                guard held, generation == token else {
                    speech.cancel()
                    return
                }
                self.speech = speech
                let (stream, buffers) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingOldest(16))
                self.buffers = buffers
                feeding = Task {
                    for await buffer in stream {
                        guard !Task.isCancelled, generation == token else { return }
                        do { try speech.append(buffer) }
                        catch { fail(error, token: token); return }
                    }
                }
                engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
                    // The tap's buffer is reused by AVAudioEngine. Own a copy before leaving its thread.
                    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
                    copy.frameLength = buffer.frameLength
                    let from = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                    let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                    for (source, target) in zip(from, to) {
                        if let src = source.mData, let dst = target.mData { memcpy(dst, src, Int(source.mDataByteSize)) }
                    }
                    if case .dropped = buffers.yield(copy) {
                        Task { @MainActor in
                            self.fail(RunnerError(message: "Oby couldn't keep up with the audio. Try again."), token: token)
                        }
                    }
                }
                self.engine = engine
                engine.prepare()
                try engine.start()
                listening = true
                timeout = Task {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, generation == token else { return }
                    finish()
                }
            } catch { fail(error, token: token) }
        }
    }

    func lock() {
        guard listening, held, !locked else { return }
        locked = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func release() {
        guard !locked else { return }
        finish()
    }

    /// Stop (or the 60-second limit) sends, including when the touch already ended after locking.
    func finish() {
        guard held else { return }
        let done = self.done
        self.done = nil
        held = false
        locked = false
        stopMicrophone()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Preparation still pending: cancel it, and discard this hold.
        guard let speech else { cancel(); return }
        finishing = true
        let token = generation
        let feeding = feeding
        work = Task {
            await feeding?.value
            do {
                let transcript = try await speech.finish()
                guard generation == token else { return }
                self.speech = nil
                finishing = false
                words = ""
                if !transcript.isEmpty { done?(transcript) }
            } catch { fail(error, token: token) }
        }
    }

    func cancel() {
        let wasHeld = held
        generation += 1
        held = false
        locked = false
        done = nil
        finishing = false
        stopMicrophone()
        if wasHeld { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        work?.cancel()
        feeding?.cancel()
        speech?.cancel()
        speech = nil
        words = ""
    }

    private func stopMicrophone() {
        listening = false
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        buffers?.finish()
        buffers = nil
        timeout?.cancel()
        timeout = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fail(_ error: Error, token: Int) {
        guard generation == token else { return }
        cancel()
        problem = error.localizedDescription
    }
}

/// One synthesizer for the conversation. Enhanced/premium installed voices are preferred;
/// availability varies by phone and language, so the system voice is the fallback.
@MainActor
final class PhoneSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func stop() {
        // Invalidate before stopping: a late completion must not deactivate a new mic session.
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func say(_ text: String) {
        stop()
        let locale = PhoneSpeech.locale.identifier.replacingOccurrences(of: "_", with: "-")
        let language = locale.split(separator: "-").first.map(String.init) ?? "en"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice)
                && ($0.quality == .enhanced || $0.quality == .premium)
        }
        let exact = voices.filter { $0.language == locale }
        let preferred = (exact.isEmpty ? voices : exact).sorted { $0.quality.rawValue > $1.quality.rawValue }.first
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferred ?? AVSpeechSynthesisVoice(language: locale)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        current = utterance
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finished(utterance) }
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        guard current === utterance else { return }
        current = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
