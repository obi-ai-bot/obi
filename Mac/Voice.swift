import AVFoundation
import Foundation
import Observation
import OSLog
import Speech

/// What you say while you hold the talk key, written down on this Mac as you speak:
/// SpeechTranscriber streaming from AVAudioEngine. English only for now. The microphone is open
/// only between `start` and `finish` (or `cancel`).
@Observable
final class Voice {
    enum Phase { case idle, listening, finishing }

    private(set) var phase = Phase.idle
    private(set) var key = TalkKey.Key.fn
    var handsFree = false
    /// The words so far: the final ones, then the ones still changing.
    private(set) var words = ""
    /// The microphone's recent loudness, 0...1, oldest first: the island's waveform.
    private(set) var levels = Voice.silence
    /// Why Oby can't listen, in one sentence.
    private(set) var problem: String?

    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var downloading = false
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var input: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var results: Task<Void, Never>?

    private static let silence = [Float](repeating: 0, count: 32)
    private static let locale = Locale(identifier: "en-US")

    struct Problem: LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Fetches the English speech model with AssetInventory if this Mac doesn't have it yet.
    func prepare() {
        Task {
            do {
                let transcriber = try await Self.transcriber()
                guard await AssetInventory.status(forModules: [transcriber]) != .installed,
                      let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
                downloading = true
                defer { downloading = false }
                try await request.downloadAndInstall()
            } catch {
                Logger.voice.error("the speech model didn't install: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Opens the microphone and starts writing down. `context`: names to listen for, like repositories.
    func start(key: TalkKey.Key, context: [String]) {
        self.key = key
        handsFree = false
        words = ""
        levels = Self.silence
        problem = nil
        phase = .listening
        queue {
            do {
                try await self.open(context)
            } catch {
                self.problem = error.localizedDescription
                Logger.voice.error("listening didn't start: \(error.localizedDescription, privacy: .public)")
                _ = await self.close(cancel: true)
            }
        }
    }

    /// Closes the microphone at once, then hands over the final words (empty if there were none).
    func finish(_ done: @escaping (String) -> Void) {
        phase = .finishing
        queue {
            let said = await self.close(cancel: false)
            if self.phase == .finishing { self.phase = .idle }
            done(said)
        }
    }

    func cancel() {
        phase = .idle
        queue { _ = await self.close(cancel: true) }
    }

    /// One thing at a time: a release that comes while the microphone is still opening waits for it.
    private func queue(_ step: @escaping () async -> Void) {
        let previous = work
        work = Task {
            await previous?.value
            await step()
        }
    }

    private func open(_ context: [String]) async throws {
        // Let go (or cancelled) before the microphone could open: nothing to hear.
        guard phase == .listening else { return }
        if downloading { throw Problem("Oby is getting the English speech model. Try again in a minute.") }
        guard await Self.microphoneAllowed() else {
            throw Problem("Oby can't hear you. Allow the microphone in System Settings › Privacy & Security › Microphone.")
        }
        // The first time, you may have let go while macOS asked about the microphone.
        guard phase == .listening else { return }
        let transcriber = try await Self.transcriber()
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            prepare()
            throw Problem("Oby is getting the English speech model. Try again in a minute.")
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Problem("This Mac can't write down speech right now.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        // Repository and product names, so "tetrix front end" comes out right.
        let hints = AnalysisContext()
        hints.contextualStrings[.general] = context
        try await analyzer.setContext(hints)

        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.analyzer = analyzer
        self.input = input
        results = Task { [weak self] in
            var settled = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                    let all = [settled, text].filter { !$0.isEmpty }.joined(separator: " ")
                    if result.isFinal { settled = all }
                    self?.words = all
                }
            } catch {
                Logger.voice.error("the transcriber stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
        try await analyzer.start(inputSequence: stream)

        let engine = AVAudioEngine()
        let microphone = engine.inputNode
        let source = microphone.outputFormat(forBus: 0)
        guard let tap = Self.feed(from: source, to: format, into: input, level: { [weak self] level in
            Task { @MainActor in self?.heard(level) }
        }) else { throw Problem("Oby can't read this microphone.") }
        microphone.installTap(onBus: 0, bufferSize: 2048, format: source, block: tap)
        self.engine = engine
        engine.prepare()
        try engine.start()
    }

    /// Microphone off first, then the last words.
    private func close(cancel: Bool) async -> String {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        input?.finish()
        input = nil
        if let analyzer {
            if cancel {
                await analyzer.cancelAndFinishNow()
            } else {
                do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { await analyzer.cancelAndFinishNow() }
            }
        }
        analyzer = nil
        if cancel { results?.cancel() }
        await results?.value
        results = nil
        return cancel ? "" : words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func heard(_ level: Float) {
        guard phase == .listening else { return }
        levels = Array(levels.dropFirst()) + [level]
    }

    private static func transcriber() async throws -> SpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Problem("This Mac can't write down English yet.")
        }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// The microphone's tap, on the audio thread: converts each buffer to the analyzer's format and passes it on.
    nonisolated private static func feed(from source: AVAudioFormat, to format: AVAudioFormat,
                                         into input: AsyncStream<AnalyzerInput>.Continuation,
                                         level: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock? {
        guard let converter = AVAudioConverter(from: source, to: format) else { return nil }
        return { buffer, _ in
            level(loudness(buffer))
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / source.sampleRate).rounded(.up)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if given {
                    state.pointee = .noDataNow
                    return nil
                }
                given = true
                state.pointee = .haveData
                return buffer
            }
            guard status != .error, converted.frameLength > 0 else { return }
            input.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// The buffer's loudness, from -50 dB (0) to 0 dB (1).
    nonisolated private static func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let decibels = 10 * log10(max(sum / Float(buffer.frameLength), 1e-10))
        return max(0, min(1, (decibels + 50) / 50))
    }

    /// What to listen for: product names, and each repository's name as written and as said.
    /// The first repositories are the likeliest to be spoken: only the first 100 names are kept.
    nonisolated static func context(repos: [String]) -> [String] {
        var names = ["Oby", "Claude", "Cursor", "Gemini", "GitHub", "pull request", "PR"] + Job.agentNames.values.sorted()
        for repo in repos {
            let name = String(repo.split(separator: "/").last ?? Substring(repo))
            names.append(name)
            names.append(String(name.map { "-_.".contains($0) ? " " : $0 }))
        }
        var seen = Set<String>()
        return Array(names.filter { seen.insert($0.lowercased()).inserted }.prefix(100))
    }
}

extension Logger {
    nonisolated static let voice = Logger(subsystem: "com.deskree.oby", category: "voice")
}
