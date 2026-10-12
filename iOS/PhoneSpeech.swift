import AVFoundation
import Speech
import UIKit

/// One on-device analyzer for a hold. Input and result streams live independently; an explicit
/// end finalizes them. Expiration, cancellation and a lost sender close them without planning.
@MainActor
final class PhoneSpeech {
    let request: String
    private let sourceFormat: AVAudioFormat
    private let analyzerFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var results: Task<String, Error>?
    private var expiry: Task<Void, Never>?
    private var background = UIBackgroundTaskIdentifier.invalid
    private var nextSequence = 0
    private var frames = 0
    private var ending = false
    private var onCancel: (() -> Void)?
    private(set) var cancelled = false

    private init(request: String, sourceFormat: AVAudioFormat, analyzerFormat: AVAudioFormat,
                 converter: AVAudioConverter, analyzer: SpeechAnalyzer,
                 input: AsyncStream<AnalyzerInput>.Continuation) {
        self.request = request
        self.sourceFormat = sourceFormat
        self.analyzerFormat = analyzerFormat
        self.converter = converter
        self.analyzer = analyzer
        self.input = input
    }

    /// Explicit English/Portuguese settings override the system language. Keep the Watch's
    /// existing system-language behavior for every locale SpeechTranscriber supports.
    static var locale: Locale { VoiceSettings.locale }

    static func context(repos: [String]) -> [String] {
        var names = ["Oby", "Claude", "Claude Code", "Codex", "Cursor", "Gemini", "GitHub", "PR", "pull request"]
        for repo in repos {
            let name = String(repo.split(separator: "/").last ?? Substring(repo))
            names += [repo, name, String(name.map { "-_.".contains($0) ? " " : $0 })]
        }
        var seen = Set<String>()
        return Array(names.filter { seen.insert($0.lowercased()).inserted }.prefix(100))
    }

    private static var downloading = false

    private static func transcriber() async throws -> SpeechTranscriber {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw RunnerError(message: "Your iPhone can't transcribe this language yet.")
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                           reportingOptions: [.volatileResults], attributeOptions: [])
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            if !downloading, let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                downloading = true
                Task {
                    defer { downloading = false }
                    // Give a model download time to continue if a Watch request wakes the phone.
                    nonisolated(unsafe) var background = UIBackgroundTaskIdentifier.invalid
                    background = UIApplication.shared.beginBackgroundTask(withName: "speech model") {
                        UIApplication.shared.endBackgroundTask(background)
                        background = .invalid
                    }
                    defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
                    try? await download.downloadAndInstall()
                }
            }
            throw RunnerError(message: "Your iPhone is getting the speech model. Try again in a minute.")
        }
        return transcriber
    }

    /// Older Watch recordings use the same on-device model and recognition context as live holds.
    static func transcribe(_ audio: Data, context: [String]) async throws -> String {
        let file = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString).m4a")
        try audio.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transcriber = try await transcriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let hints = AnalysisContext()
        hints.contextualStrings[.general] = context
        try await analyzer.setContext(hints)
        let recording = try AVAudioFile(forReading: file)
        async let text = try transcriber.results.reduce(into: AttributedString()) { result, next in
            if next.isFinal { result += next.text }
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: recording) {
                try await analyzer.finalizeAndFinish(through: last)
            } else { await analyzer.cancelAndFinishNow() }
            let written = try await text
            return String(written.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { await analyzer.cancelAndFinishNow(); throw error }
    }

    static let phoneTapFrames: AVAudioFrameCount = 2048

    /// Tap size is ~43 ms at 48 kHz, much smaller than the Watch's 250 ms packets.
    /// Use a duration budget for phone buffers, rather than reuse the Watch's packet count.
    static func phoneBufferCapacity(sampleRate: Double) -> Int {
        max(128, Int(ceil(sampleRate * 8 / Double(phoneTapFrames))))
    }

    static func make(request: String, sampleRate: Double, sourceFormat: AVAudioFormat? = nil, context: [String] = [], onCancel: (() -> Void)? = nil, partial: @escaping (String) -> Void) async throws -> PhoneSpeech {
        let transcriber = try await transcriber()
        guard let source = sourceFormat ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                                          channels: 1, interleaved: false),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: source, to: format) else {
            throw RunnerError(message: "Your iPhone can't use this audio format.")
        }
        converter.primeMethod = .none
        // Phone conversion can yield more than one analyzer buffer per tap; allow twice
        // the capture queue's budget. Watch packets keep their separate 64-chunk (~16 s) bound.
        let capacity = sourceFormat == nil ? 64 : phoneBufferCapacity(sampleRate: source.sampleRate) * 2
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(capacity))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let hints = AnalysisContext()
        hints.contextualStrings[.general] = context
        try await analyzer.setContext(hints)
        let live = PhoneSpeech(request: request, sourceFormat: source, analyzerFormat: format,
                               converter: converter, analyzer: analyzer, input: input)
        live.onCancel = onCancel
        live.results = Task {
            var finalized = AttributedString()
            var volatile = AttributedString()
            for try await result in transcriber.results {
                try Task.checkCancellation()
                if result.isFinal { finalized += result.text; volatile = AttributedString() }
                else { volatile = result.text }
                partial(String((finalized + volatile).characters).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(finalized.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do { try await analyzer.start(inputSequence: stream) }
        catch { live.cancel(); throw error }
        if sourceFormat == nil {
            // UIKit requires the expired task ended inside this callback, before async cleanup.
            // Hand off ownership synchronously to avoid ending the id twice.
            nonisolated(unsafe) var background = UIBackgroundTaskIdentifier.invalid
            live.background = UIApplication.shared.beginBackgroundTask(withName: "watch live speech") { [weak live] in
                UIApplication.shared.endBackgroundTask(background)
                background = .invalid
                Task { @MainActor in
                    live?.background = .invalid
                    live?.cancel()
                }
            }
            background = live.background
        }
        live.armExpiry()
        return live
    }

    /// Closes the stream if the watch vanishes without an end/cancel packet: 30 seconds with no
    /// new chunk, counted again on each one, so a slow connection doesn't cut a long hold.
    /// Finalization gets its own 30 seconds.
    private func armExpiry() {
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    func append(_ audio: Data, sequence: Int) throws {
        guard !cancelled, !ending, sequence == nextSequence, !audio.isEmpty,
              audio.count <= WatchWire.chunkLimit, audio.count.isMultiple(of: WatchWire.voiceSampleBytes) else {
            throw RunnerError(message: "The watch's audio stream was interrupted. Try again.")
        }
        let count = audio.count / WatchWire.voiceSampleBytes
        guard frames + count <= Int(sourceFormat.sampleRate * Double(WatchWire.voiceSeconds + 1)),
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count)),
              let samples = buffer.int16ChannelData?[0] else {
            throw RunnerError(message: "The watch's audio stream was too long.")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        audio.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: audio.count))
        try convert(buffer)
        frames += count
        nextSequence += 1
        armExpiry()
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard !cancelled, !ending else { throw CancellationError() }
        try convert(buffer)
        armExpiry()
    }

    /// Phone input has no Watch packet sequence, and reports interruptions as phone listening errors.
    func finish() async throws -> String {
        guard !cancelled, !ending else {
            throw RunnerError(message: "Listening was interrupted. Tap the mic to try again.")
        }
        do { return try await finish(sequence: nextSequence) }
        catch is CancellationError {
            throw RunnerError(message: "Listening was interrupted. Tap the mic to try again.")
        }
    }

    /// A persistent converter preserves resampling across chunk boundaries; drain it at end.
    private func convert(_ buffer: AVAudioPCMBuffer?) throws {
        let capacity = buffer.map { Int(ceil(Double($0.frameLength) * analyzerFormat.sampleRate / sourceFormat.sampleRate)) + 32 } ?? 1024
        var supplied = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: AVAudioFrameCount(capacity)) else {
                throw RunnerError(message: "Your iPhone couldn't convert the audio.")
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                guard let buffer else { status.pointee = .endOfStream; return nil }
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            if status == .error { throw RunnerError(message: "Your iPhone couldn't convert the audio.") }
            if output.frameLength > 0 {
                if case .dropped = input.yield(AnalyzerInput(buffer: output)) {
                    throw RunnerError(message: "Your iPhone couldn't keep up with the audio.")
                }
            }
            if status != .haveData { return }
        }
    }

    func finish(sequence: Int) async throws -> String {
        guard !cancelled, !ending, sequence == nextSequence else {
            cancel()
            throw RunnerError(message: "The watch's audio stream was interrupted. Try again.")
        }
        ending = true
        armExpiry()
        defer { cleanup() }
        do {
            try convert(nil)
            input.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let text = try await results?.value ?? ""
            guard !cancelled else { throw CancellationError() }
            return text
        } catch { cancel(); throw error }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        input.finish()
        results?.cancel()
        Task { await analyzer.cancelAndFinishNow() }
        cleanup()
        let notify = onCancel
        onCancel = nil
        notify?()
    }

    private func cleanup() {
        expiry?.cancel()
        expiry = nil
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
    }
}
