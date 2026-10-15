import AVFoundation
import Synchronization
import SwiftUI

/// The round mic below Oby: tap to listen, tap again to stop. Stopping keeps the words as a draft;
/// sending is a tap of its own. Without a live line it opens the system's dictation, whose words
/// join the draft too.
struct TalkButton: View {
    @Environment(Watch.self) private var watch
    @Environment(\.scenePhase) private var scenePhase
    let size: CGFloat

    var body: some View {
        let listening = watch.talk == .recording
        // Keep lifecycle modifiers on a stable container when the mic becomes Stop.
        HStack(spacing: 0) {
            if listening || (watch.canTalk && watch.recorder.allowed != false && !watch.useDictation) {
                Button {
                    if listening { watch.stopListening() } else { watch.listen() }
                } label: {
                    circle(listening ? "stop.fill" : "mic.fill", red: listening)
                }
                .buttonStyle(.plain)
                .disabled(watch.talk == .sending)
                .accessibilityLabel(listening ? "Stop listening" : "Talk to Oby")
                .accessibilityHint(listening ? "Keeps your words. Send sends them." : "Your words appear as you speak.")
            } else {
                TextFieldLink(prompt: Text("What should Oby do?")) { circle("mic.fill", red: false) }
                    onSubmit: { watch.dictated($0) }
                    .buttonStyle(.plain)
                    .disabled(watch.talk == .sending)
                    .accessibilityLabel("Dictate to Oby")
            }
        }
        .sensoryFeedback(trigger: listening) { _, listening in listening ? .start : .stop }
        .sensoryFeedback(.warning, trigger: watch.recorder.seconds) { _, seconds in seconds >= Recorder.limit }
        .task { await watch.recorder.prepare() }
        // The screen turning off stops listening; the words stay.
        .onChange(of: scenePhase) { if scenePhase != .active { watch.stopListening() } }
        .onDisappear { watch.stopListening() }
    }

    private func circle(_ symbol: String, red: Bool) -> some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(red ? Color.red : Color.accentColor, in: Circle())
            .opacity(watch.talk == .sending ? 0.5 : 1)
    }
}

/// Lives below Oby on Home; the ScrollView takes the crown naturally. The words appear here as
/// they're said; a draft, a reply or a question stays until Send, Done, an answer or the next
/// tap that replaces it. Planned work starts by itself (#269): its jobs show in the list, with
/// nothing to confirm. No sheet takes the microphone away.
struct TalkView: View {
    @Environment(Watch.self) private var watch

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch watch.talk {
                    case .none:
                        EmptyView()
                    case .recording, .sending:
                        let listening = watch.talk == .recording
                        if listening {
                            HStack(alignment: .center, spacing: 3) {
                                ForEach(0..<9) { index in
                                    Capsule().fill(Color.accentColor)
                                        .frame(width: 4, height: 3 + 15 * max(0, watch.level - Double(abs(index - 4)) * 0.08))
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 20)
                            .accessibilityHidden(true)
                        }
                        let heard = watch.heard
                        Text(heard.isEmpty ? (listening ? "Listening…" : "Writing down…") : heard)
                            .readingText().frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.updatesFrequently)
                        if !listening, !heard.isEmpty {
                            Label("Writing down…", systemImage: "ellipsis").font(.caption2).foregroundStyle(.secondary)
                        }
                    case .draft(let words):
                        ReadingText(words).frame(maxWidth: .infinity, alignment: .leading)
                        if let notice = watch.notice {
                            Text(notice).font(.caption2).foregroundStyle(.orange)
                        }
                        Button("Send") { watch.sendDraft() }
                            .tint(.accentColor).buttonStyle(.borderedProminent)
                            .accessibilityHint("Asks Oby. The mic adds more words first.")
                        Button("Clear") { watch.cancel() }
                    case .thinking(let said):
                        waiting(said)
                    case .queued(let said):
                        Text("Your iPhone isn't in reach. Oby plans it when it is.").font(.footnote)
                        ReadingText(said)
                        Button("Dismiss") { watch.cancel() }
                    case .question(let said, let question):
                        steps
                        QuestionCard(said: said, question: question)
                    case .reply(let text):
                        steps
                        ReadingText(text).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Done") { watch.cancel() }
                    }
                }
                .padding(8)
                Color.clear.frame(height: 1).id("live-end")
            }
            .onChange(of: watch.heard) {
                if watch.talk == .recording || watch.talk == .sending { scroll.scrollTo("live-end", anchor: .bottom) }
            }
            .onChange(of: watch.talk) {
                // Send is in view as soon as the words are kept.
                if case .draft = watch.talk { scroll.scrollTo("live-end", anchor: .bottom) }
            }
        }
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func waiting(_ said: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ReadingText(said)
            if watch.steps.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                steps
            }
            if let problem = watch.stopProblem {
                Text(problem).font(.caption2).foregroundStyle(.orange)
            }
            // Stop ends the turn on the runner while steps run (#304); Cancel stops waiting for the answer.
            Button("Stop", role: .destructive) { Task { await watch.stopTurn() } }
            Button("Cancel") { watch.cancel() }
        }
    }

    /// Oby's steps, as short lines under it (#304).
    @ViewBuilder private var steps: some View {
        if !watch.steps.isEmpty {
            StepList(steps: watch.steps, compact: true)
        }
    }
}

/// Mono 16 kHz Int16 PCM (WatchWire), delivered in 1/4-second pieces. No audio file stays on the watch.
@Observable
final class Recorder {
    // One bound for capture, sender backlog and the phone's transcription stream.
    static let limit = WatchWire.voiceSeconds
    private(set) var listening = false
    private(set) var seconds = 0
    private(set) var allowed: Bool?
    private var engine: AVAudioEngine?
    private var began: Date?
    private var ticking: Task<Void, Never>?
    private var generation: UUID?
    /// Filled on the audio thread, emptied on the main actor. Tagged with its time listening, so closing
    /// the mic can take what was captured but not yet received, and a late callback can't leak into the next.
    nonisolated private let captured = Mutex<(listening: UUID?, audio: Data)>((nil, Data()))
    private var pending = Data()
    private var chunkBytes = 0
    private var deliver: ((Data, Double) -> Void)?
    /// Called once the limit closed the microphone.
    private var reachedLimit: (() -> Void)?
    private var level = 0.0

    func prepare() async { allowed = await AVAudioApplication.requestRecordPermission() }

    /// Opens the microphone now, with no await in between. `limit` is called at the limit,
    /// once the microphone is closed.
    func start(deliver: @escaping (Data, Double) -> Void, limit: @escaping () -> Void) throws -> Double {
        guard allowed == true else {
            throw RunnerError(message: allowed == nil ? "One moment: Oby is asking for the microphone." : "Allow Oby's microphone in Settings, or tap to dictate.")
        }
        cancel()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        do {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0,
                  format.commonFormat == .pcmFormatFloat32,
                  format.channelCount == 1 || !format.isInterleaved,
                  let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: WatchWire.voiceSampleRate,
                                           channels: 1, interleaved: false),
                  let made = AVAudioConverter(from: format, to: wire) else {
                throw RunnerError(message: "The microphone's audio format isn't available.")
            }
            made.downmix = true
            // Used only on the audio thread, one buffer at a time, so its resampling state carries over.
            nonisolated(unsafe) let converter = made
            let id = UUID()
            generation = id
            captured.withLock { $0 = (id, Data()) }
            chunkBytes = min(WatchWire.chunkLimit, Int(WatchWire.voiceSampleRate * 0.25) * WatchWire.voiceSampleBytes)
            self.deliver = deliver
            reachedLimit = limit
            self.engine = engine
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                guard let samples = buffer.floatChannelData?[0] else { return }
                let count = Int(buffer.frameLength)
                var power: Float = 0
                for index in 0..<count { power += samples[index] * samples[index] }
                let level = min(1, Double(sqrt(power / Float(max(1, count)))) * 8)
                // Converted and copied before AVAudioEngine reuses its buffer. Nothing from the audio
                // callback touches observed state; stale callbacks are rejected by their id.
                let capacity = AVAudioFrameCount(ceil(Double(count) * wire.sampleRate / format.sampleRate)) + 32
                guard let output = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return buffer
                }
                guard status != .error, error == nil, output.frameLength > 0,
                      let converted = output.int16ChannelData?[0] else { return }
                let audio = Data(bytes: converted, count: Int(output.frameLength) * WatchWire.voiceSampleBytes)
                let current = self.captured.withLock { state in
                    guard state.listening == id else { return false }
                    state.audio.append(audio)
                    return true
                }
                if current { Task { @MainActor in self.receive(level: level, generation: id) } }
            }
            engine.prepare()
            try engine.start()
            listening = true
            began = .now
            seconds = 0
            ticking = Task {
                while !Task.isCancelled, seconds < Self.limit {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    // Close independently of view updates at the limit.
                    if seconds + 1 == Self.limit { pending.append(closeMicrophone()) }
                    seconds += 1
                    if seconds >= Self.limit { reachedLimit?() }
                }
            }
            return WatchWire.voiceSampleRate
        } catch {
            cancel()
            try? session.setActive(false)
            throw error
        }
    }

    private func receive(level: Double, generation: UUID) {
        guard self.generation == generation else { return }
        self.level = level
        pending.append(take())
        while pending.count >= chunkBytes {
            deliver?(Data(pending.prefix(chunkBytes)), level)
            pending.removeFirst(chunkBytes)
        }
    }

    func stop() -> TimeInterval {
        let heard = began.map { min(Date.now.timeIntervalSince($0), Double(Self.limit)) } ?? 0
        // Audio captured before the stop but not yet received is the end of the last word.
        pending.append(closeMicrophone())
        if !pending.isEmpty { deliver?(pending, level) }
        cancel()
        return heard
    }

    private func take() -> Data {
        captured.withLock { state in
            defer { state.audio = Data() }
            return state.audio
        }
    }

    /// Returns what was captured and not yet received; later callbacks are dropped.
    @discardableResult
    private func closeMicrophone() -> Data {
        listening = false
        generation = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
            try? AVAudioSession.sharedInstance().setActive(false)
        }
        return captured.withLock { state in
            defer { state = (nil, Data()) }
            return state.audio
        }
    }

    func cancel() {
        closeMicrophone()
        ticking?.cancel()
        ticking = nil
        began = nil
        pending.removeAll(keepingCapacity: false)
        deliver = nil
        reachedLimit = nil
    }
}

/// The brain needs one more thing: pick an option, the recommended one first, or dictate your own.
struct QuestionCard: View {
    @Environment(Watch.self) private var watch
    let said: String
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DecisionCard(title: question.text, plan: question.plan, options: question.cardOptions,
                         onChoose: { watch.answer($0.answer, said: said, question: question) },
                         onWords: { watch.answer($0, said: said, question: question) })
            Button("Cancel") { watch.cancel() }
        }
    }
}
