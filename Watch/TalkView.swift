import AVFoundation
import SwiftUI

/// A stable bottom-row control, including while a reply is pending. A new hold replaces it.
struct TalkButton: View {
    @Environment(Watch.self) private var watch
    @Environment(\.scenePhase) private var scenePhase
    let size: CGFloat
    @State private var recorder = Recorder()
    @GestureState private var pressing = false
    @State private var holding = false

    var body: some View {
        Group {
            if holding || (watch.reachable && recorder.allowed != false && !watch.useDictation) {
                circle(holding ? "waveform" : "mic.fill")
                    .gesture(DragGesture(minimumDistance: 0)
                        .updating($pressing) { _, pressing, _ in pressing = true })
                    .onChange(of: pressing) { if pressing { start() } else { release() } }
                    .accessibilityLabel("Hold to talk")
            } else {
                TextFieldLink(prompt: Text("What should Oby do?")) { circle("mic.fill") }
                    onSubmit: { watch.cancel(); watch.ask($0) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dictate to Oby")
                    .simultaneousGesture(TapGesture().onEnded { watch.cancel() })
            }
        }
        .sensoryFeedback(trigger: holding) { _, held in held ? .start : .stop }
        .sensoryFeedback(.warning, trigger: recorder.seconds) { _, seconds in seconds >= Recorder.limit }
        .task { await recorder.prepare() }
        .onChange(of: recorder.seconds) { if recorder.seconds >= Recorder.limit { release() } }
        .onChange(of: watch.talk) { if watch.talk != .recording, holding { abort() } }
        .onChange(of: scenePhase) { if scenePhase != .active { abort() } }
        .onChange(of: watch.reachable) {
            if !watch.reachable, holding {
                abort()
                watch.useDictation = true
                watch.talk = .reply("Your iPhone isn't in reach. Tap the mic to dictate instead.")
            }
        }
        .onDisappear { abort() }
    }

    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(holding ? Color.red : Color.accentColor, in: Circle())
    }

    private func start() {
        guard !holding else { return }
        watch.cancel()
        do {
            // No await between the press and capture: a release can always close the mic.
            let rate = try recorder.start { audio, level in watch.stream(audio, level: level) }
            watch.beginVoice(sampleRate: rate)
            holding = true
        } catch {
            recorder.cancel()
            if recorder.allowed == true { watch.useDictation = true }
            watch.talk = .reply(error.localizedDescription)
        }
    }

    private func release() {
        guard holding else { return }
        holding = false
        let heard = recorder.stop()
        if watch.talk == .recording {
            if heard >= 0.4 { watch.endVoice() }
            else {
                watch.cancel()
                watch.talk = .reply("Hold the button while you talk.")
            }
        }
    }

    private func abort() {
        recorder.cancel()
        if holding {
            holding = false
            if watch.talk == .recording { watch.cancel() }
        }
    }
}

/// Lives below Oby on Home; the ScrollView takes the crown naturally. Replies stay until Done,
/// dispatch, or the next hold. No sheet takes the microphone away.
struct TalkView: View {
    @Environment(Watch.self) private var watch

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch watch.talk {
                    case .none:
                        EmptyView()
                    case .recording:
                        HStack(alignment: .center, spacing: 3) {
                            ForEach(0..<9) { index in
                                Capsule().fill(Color.accentColor)
                                    .frame(width: 4, height: 3 + 15 * max(0, watch.level - Double(abs(index - 4)) * 0.08))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .accessibilityLabel("Microphone level")
                        Text(watch.words.isEmpty ? "…" : watch.words)
                            .font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(watch.words.isEmpty ? "Listening" : watch.words)
                    case .sending:
                        ProgressView().frame(maxWidth: .infinity)
                        if !watch.words.isEmpty { Text(watch.words).font(.footnote) }
                        Button("Cancel") { watch.cancel() }
                    case .thinking(let said):
                        waiting(said)
                    case .queued(let said):
                        Text("Your iPhone isn't in reach. Oby plans it when it is.").font(.footnote)
                        Text(said).font(.footnote)
                        Button("Dismiss") { watch.cancel() }
                    case .plan(let drafts):
                        PlanCard(drafts: drafts)
                    case .question(let said, let question):
                        QuestionCard(said: said, question: question)
                    case .reply(let text):
                        Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Done") { watch.cancel() }
                    }
                }
                .padding(8)
                Color.clear.frame(height: 1).id("live-end")
            }
            .onChange(of: watch.words) {
                if watch.talk == .recording { scroll.scrollTo("live-end", anchor: .bottom) }
            }
        }
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func waiting(_ said: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView().frame(maxWidth: .infinity)
            Text(said).font(.footnote)
            Button("Cancel") { watch.cancel() }
        }
    }
}

/// Mono Float32 PCM, batched into roughly 1/4-second messages. No audio file stays on the watch.
@Observable
final class Recorder {
    static let limit = WatchWire.voiceSeconds
    private(set) var seconds = 0
    private(set) var allowed: Bool?
    private var engine: AVAudioEngine?
    private var began: Date?
    private var ticking: Task<Void, Never>?
    private var generation: UUID?
    private var pending = Data()
    private var chunkBytes = 0
    private var deliver: ((Data, Double) -> Void)?
    private var level = 0.0

    func prepare() async { allowed = await AVAudioApplication.requestRecordPermission() }

    func start(deliver: @escaping (Data, Double) -> Void) throws -> Double {
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
                  format.channelCount == 1 || !format.isInterleaved else {
                throw RunnerError(message: "The microphone's audio format isn't available.")
            }
            let id = UUID()
            generation = id
            chunkBytes = min(WatchWire.chunkLimit, Int(format.sampleRate * 0.25) * MemoryLayout<Float>.size)
            self.deliver = deliver
            self.engine = engine
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                guard let samples = buffer.floatChannelData?[0] else { return }
                // Copy before AVAudioEngine reuses its buffer. Nothing from the audio callback
                // touches observed state; stale callbacks are rejected by the generation below.
                let count = Int(buffer.frameLength)
                let audio = Data(bytes: samples, count: count * MemoryLayout<Float>.size)
                var power: Float = 0
                for index in 0..<count { power += samples[index] * samples[index] }
                let level = min(1, Double(sqrt(power / Float(max(1, count)))) * 8)
                Task { @MainActor in self.receive(audio, level: level, generation: id) }
            }
            engine.prepare()
            try engine.start()
            began = .now
            seconds = 0
            ticking = Task {
                while !Task.isCancelled, seconds < Self.limit {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    seconds += 1
                    // Close independently of view updates at the limit.
                    if seconds == Self.limit { closeMicrophone() }
                }
            }
            return format.sampleRate
        } catch {
            cancel()
            try? session.setActive(false)
            throw error
        }
    }

    private func receive(_ audio: Data, level: Double, generation: UUID) {
        guard self.generation == generation else { return }
        self.level = level
        pending.append(audio)
        while pending.count >= chunkBytes {
            deliver?(Data(pending.prefix(chunkBytes)), level)
            pending.removeFirst(chunkBytes)
        }
    }

    func stop() -> TimeInterval {
        let heard = began.map { min(Date.now.timeIntervalSince($0), Double(Self.limit)) } ?? 0
        closeMicrophone()
        if !pending.isEmpty { deliver?(pending, level) }
        cancel()
        return heard
    }

    private func closeMicrophone() {
        generation = nil
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func cancel() {
        closeMicrophone()
        ticking?.cancel()
        ticking = nil
        began = nil
        pending.removeAll(keepingCapacity: false)
        deliver = nil
    }
}

/// The plan, before anything runs: what Oby will do, where, and Dispatch with one tap.
struct PlanCard: View {
    @Environment(Watch.self) private var watch
    let drafts: [Draft]
    @State private var sending = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if drafts.count == 1 {
                Text(drafts[0].reply).font(.headline)
            } else {
                Text("Oby will start \(drafts.count) jobs.").font(.headline)
            }
            ForEach(drafts, id: \.job.id) { draft in
                VStack(alignment: .leading, spacing: 1) {
                    if drafts.count > 1 { Text(draft.job.heading).font(.footnote.weight(.semibold)).lineLimit(2) }
                    Text("\(draft.job.repoName) · \(draft.job.branch)").font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    Text("\(draft.job.agentName) · \(watch.account(draft.job.account))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if !draft.job.extras.isEmpty {
                        Text(draft.job.extras).font(.caption2).foregroundStyle(.secondary)
                    }
                    if watch.jobs.contains(where: { $0.id == draft.job.id }) {
                        Label("Sent", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                    }
                }
            }
            if drafts.contains(where: \.guessed) {
                Label("The brain didn't answer: this plan is a guess.", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let problem { Text(problem).font(.caption2).foregroundStyle(.red) }
            Button(sending ? "Dispatching…" : drafts.count == 1 ? "Dispatch" : "Dispatch all \(drafts.count)", action: dispatch)
                .tint(.accentColor).buttonStyle(.borderedProminent).disabled(sending)
            Button("Cancel") { watch.cancel() }.disabled(sending)
        }
    }

    private func dispatch() {
        sending = true
        Task {
            defer { sending = false }
            do {
                if drafts.count == 1 { try await watch.dispatch(drafts[0]) } else { try await watch.dispatch(all: drafts) }
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The brain needs one more thing: pick an option.
struct QuestionCard: View {
    @Environment(Watch.self) private var watch
    let said: String
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.text).font(.footnote.weight(.semibold))
            ForEach(question.options, id: \.self) { option in
                Button(option) { watch.answer(option, said: said, question: question) }
            }
            Button("Cancel") { watch.cancel() }
        }
    }
}
