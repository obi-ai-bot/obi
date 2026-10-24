import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

/// Owns one tap-to-dictate session: the words go to the draft as they're heard, and Stop closes
/// the microphone before the final words replace them. Async preparation checks the session is
/// still wanted before opening the microphone; cancelling drops late words, so typing wins.
@MainActor @Observable
final class PhoneVoice {
    private(set) var active = false
    private(set) var finishing = false
    private(set) var listening = false
    /// The input level while listening, 0 to 1, for the mic's meter.
    private(set) var level: Float = 0
    private(set) var problem: String?
    /// Waiting on the microphone or speech recognition permission: iOS's prompt makes the app
    /// inactive, and that alone mustn't stop the dictation it's asking for.
    @ObservationIgnored private(set) var asking = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var speech: PhoneSpeech?
    @ObservationIgnored private var buffers: AsyncStream<AVAudioPCMBuffer>.Continuation?
    @ObservationIgnored private var feeding: Task<Void, Never>?
    @ObservationIgnored private var update: ((String) -> Void)?
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
        guard active else { return }
        fail(RunnerError(message: "Listening was interrupted. Tap the mic to try again."), token: generation)
    }

    /// `update` gets the whole transcript so far, each time it changes, then the final words.
    func start(context: [String], update: @escaping (String) -> Void) {
        guard !active, !finishing else { return }
        cancel()
        active = true
        self.update = update
        problem = nil
        let token = generation
        work = Task {
            do {
                // Fail safely if a build omitted either required privacy reason, rather than let iOS terminate it.
                guard ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"].allSatisfy({
                    !(Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "").isEmpty
                }) else { throw RunnerError(message: "Voice input isn't available in this build. You can still type.") }
                // Request each permission separately. Stop during either prompt never opens audio.
                asking = true
                let microphone = await AVAudioApplication.requestRecordPermission()
                guard active, generation == token else { asking = false; return }
                let recognition = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
                }
                asking = false
                guard active, generation == token else { return }
                guard microphone, recognition else {
                    throw RunnerError(message: "Allow Microphone and Speech Recognition for Oby in Settings to talk. You can still type.")
                }
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement)
                // The start and stop haptics happen while capturing; iOS otherwise suppresses them.
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
                // Never open the microphone for an app that isn't in front.
                guard UIApplication.shared.applicationState != .background else {
                    throw RunnerError(message: "Listening was interrupted. Tap the mic to try again.")
                }
                try session.setActive(true)
                let engine = AVAudioEngine()
                let source = engine.inputNode.outputFormat(forBus: 0)
                let speech = try await PhoneSpeech.make(request: UUID().uuidString, sampleRate: source.sampleRate,
                                                        sourceFormat: source, context: context,
                                                        onCancel: { [weak self] in
                    self?.fail(RunnerError(message: "Listening was interrupted. Tap the mic to try again."), token: token)
                }) { [weak self] words in
                    guard let self, self.generation == token else { return }
                    self.update?(words)
                }
                guard active, generation == token else {
                    speech.cancel()
                    return
                }
                self.speech = speech
                // Hold at least eight seconds of tap audio if the main actor briefly falls behind.
                let capacity = PhoneSpeech.phoneBufferCapacity(sampleRate: source.sampleRate)
                let (stream, buffers) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingOldest(capacity))
                self.buffers = buffers
                feeding = Task {
                    for await buffer in stream {
                        guard !Task.isCancelled, generation == token else { return }
                        if listening { level = Self.level(buffer) }
                        do { try speech.append(buffer) }
                        catch { fail(error, token: token); return }
                    }
                }
                engine.inputNode.installTap(onBus: 0, bufferSize: PhoneSpeech.phoneTapFrames, format: source) { buffer, _ in
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
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                timeout = Task {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, generation == token else { return }
                    finish()
                }
            } catch { fail(error, token: token) }
        }
    }

    /// Stop, or the 60-second limit: the final words go to the draft. Nothing is sent.
    func finish() {
        guard active else { return }
        active = false
        stopMicrophone()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Preparation still pending: cancel it before it can open the microphone.
        guard let speech else {
            cancel()
            return
        }
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
                // Nothing heard: the draft stays as it was.
                if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    problem = "Oby didn't catch that."
                } else { update?(transcript) }
                update = nil
            } catch { fail(error, token: token) }
        }
    }

    /// Stops listening and drops any words still to come; those already in the draft stay.
    func cancel() {
        generation += 1
        asking = false
        active = false
        update = nil
        finishing = false
        stopMicrophone()
        work?.cancel()
        feeding?.cancel()
        speech?.cancel()
        speech = nil
    }

    private func stopMicrophone() {
        listening = false
        level = 0
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        buffers?.finish()
        buffers = nil
        timeout?.cancel()
        timeout = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The buffer's loudness on a -55 to 0 dB scale.
    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return max(0, min(1, (20 * log10(max(rms, 0.00001)) + 55) / 55))
    }

    private func fail(_ error: Error, token: Int) {
        guard generation == token else { return }
        cancel()
        problem = error.localizedDescription
    }
}
