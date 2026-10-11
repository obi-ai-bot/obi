import AVFoundation
import SwiftUI

/// Hold to talk, on Home: the microphone is open only while the button is held. The recording
/// goes to the iPhone, which writes it down (SpeechAnalyzer) and asks the brain; the plan comes
/// back in Home's sheet (TalkView) to dispatch with one tap. Without the phone in reach, or
/// without the microphone, the button dictates instead; the request waits for the phone if it must.
struct TalkButton: View {
    @Environment(Watch.self) private var watch
    @Environment(\.scenePhase) private var scenePhase
    /// Home's sheet, brought back when an ask is already under way (one waiting for the phone).
    @Binding var talking: Bool
    @State private var recorder = Recorder()
    /// True only while the finger is down: SwiftUI resets it when the gesture ends or is
    /// cancelled, so every hold has a release.
    @GestureState private var pressing = false
    @State private var holding = false

    var body: some View {
        Group {
            if watch.talk != .none, !holding {
                // An ask is under way (one waiting for the phone, its sheet closed): it comes back.
                Button { talking = true } label: { circle("mic.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show the request")
            } else if holding || (watch.reachable && recorder.allowed != false) {
                // Drawn while held too, so the gesture that opened the mic is still there to close it.
                circle(holding ? "waveform" : "mic.fill")
                    .gesture(
                        // Pressed and released, wherever the finger goes: the mic follows the hold.
                        DragGesture(minimumDistance: 0)
                            .updating($pressing) { _, pressing, _ in pressing = true }
                    )
                    .onChange(of: pressing) { if pressing { start() } else { release() } }
                    .accessibilityLabel("Hold to talk")
            } else {
                TextFieldLink(prompt: Text("What should Oby do?")) {
                    circle("mic.fill")
                } onSubmit: { watch.ask($0) }
                .buttonStyle(.plain)
                .accessibilityLabel("Dictate to Oby")
            }
        }
        .sensoryFeedback(trigger: holding) { _, held in held ? .start : .stop }
        // At the limit the recorder stops itself: the wrist is told to let go.
        .sensoryFeedback(.warning, trigger: recorder.seconds) { _, seconds in seconds >= Recorder.limit }
        // The permission is asked here, before any hold, so a hold starts the mic at once or not at all.
        .task { await recorder.prepare() }
        // A hold the gesture never ends (the screen left, the app went inactive) is a release.
        .onChange(of: scenePhase) { if scenePhase != .active { release() } }
        // The phone went out of reach mid-hold: there's nowhere to send it, so the mic closes.
        .onChange(of: watch.reachable) { if !watch.reachable { release() } }
        .onDisappear {
            release()
            // Whatever state the talk is in, the microphone doesn't outlive the screen.
            recorder.cancel()
        }
    }

    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(holding ? Color.red : Color.accentColor, in: Circle())
            .scaleEffect(holding ? 1.08 : 1)
            .animation(.snappy, value: holding)
    }

    /// Synchronous: nothing waits between the hold and the microphone, so a release always finds
    /// the recorder it has to stop.
    private func start() {
        guard !holding, watch.talk == .none else { return }
        holding = true
        do {
            try recorder.start()
            watch.talk = .recording
        } catch {
            holding = false
            watch.talk = .reply(error.localizedDescription)
        }
    }

    /// The hold ended, however it ended: the microphone closes now. The recording is sent only
    /// when the talk is still the one it was made for (a notification tapped meanwhile cancels it).
    private func release() {
        guard holding else { return }
        holding = false
        if watch.talk == .recording { stop() } else { recorder.cancel() }
    }

    private func stop() {
        guard let audio = recorder.stop() else {
            // Too short to send: the sheet says why ("Hold the button while you talk.").
            if let problem = recorder.problem { watch.talk = .reply(problem) } else { watch.talk = .none }
            return
        }
        guard audio.count <= WatchWire.limit else {
            watch.talk = .reply("That was too long for the watch. Keep it under \(Recorder.limit) seconds.")
            return
        }
        watch.voice(audio)
    }
}

/// Home's sheet for a talk under way: sending, thinking, waiting for the phone, then the plan to
/// dispatch with one tap, a question from the brain, or its reply.
struct TalkView: View {
    @Environment(Watch.self) private var watch

    var body: some View {
        switch watch.talk {
        case .none, .recording:
            // The sheet is on its way out.
            EmptyView()
        case .sending:
            VStack(spacing: 8) {
                ProgressView()
                Text("Sending to your iPhone…").font(.footnote).multilineTextAlignment(.center)
            }
        case .thinking(let said):
            waiting("Thinking…", said: said)
        case .queued(let said):
            waiting("Your iPhone isn't in reach. Oby plans it when it is.", said: said)
        case .plan(let drafts):
            ScrollView { PlanCard(drafts: drafts) }
        case .question(let said, let question):
            ScrollView { QuestionCard(said: said, question: question) }
        case .reply(let text):
            ScrollView {
                VStack(spacing: 10) {
                    Text(text).font(.footnote).multilineTextAlignment(.center)
                    Button("Done") { watch.cancel() }
                }
            }
        }
    }

    private func waiting(_ title: String, said: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(title).font(.footnote).multilineTextAlignment(.center)
            Text("“\(said)”").font(.caption2).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.center)
            Button("Cancel") { watch.cancel() }
        }
    }
}

/// AAC, mono, 16 kHz: small enough for WatchConnectivity, clear enough for speech.
@Observable
final class Recorder {
    /// Longer wouldn't fit in one message to the phone.
    static let limit = 15

    /// How long the hold has lasted, up to the limit, where the counter stops.
    private(set) var seconds = 0
    var problem: String?
    /// Whether the microphone may be used; nil until the user has answered.
    private(set) var allowed: Bool?
    private var recorder: AVAudioRecorder?
    /// When the recording began. The length is measured from here: once the recorder has stopped
    /// itself at the limit, it reports no time of its own.
    private var began: Date?
    private var ticking: Task<Void, Never>?
    private let file = FileManager.default.temporaryDirectory.appending(path: "talk.m4a")

    /// Asks for the microphone, once, before any hold.
    func prepare() async {
        allowed = await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        guard allowed == true else {
            throw RunnerError(message: allowed == nil ? "One moment: Oby is asking for the microphone." : "Oby needs the microphone to hear you. Allow it in Settings.")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000,
        ]
        let recorder = try AVAudioRecorder(url: file, settings: settings)
        // The recorder stops itself at the limit; what it recorded until then is kept and sent on release.
        guard recorder.record(forDuration: TimeInterval(Self.limit)) else {
            throw RunnerError(message: "The microphone didn't start.")
        }
        self.recorder = recorder
        began = .now
        problem = nil
        seconds = 0
        ticking = Task {
            while !Task.isCancelled, seconds < Self.limit {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { seconds += 1 }
            }
        }
    }

    /// Stops and hands over the recording, or nil when there's too little to send.
    func stop() -> Data? {
        guard let began else { cancel(); return nil }
        let heard = min(Date.now.timeIntervalSince(began), TimeInterval(Self.limit))
        cancel()
        // Handed over, the recording doesn't stay on the watch.
        defer { try? FileManager.default.removeItem(at: file) }
        guard heard >= 0.4, let data = try? Data(contentsOf: file), !data.isEmpty else {
            problem = "Hold the button while you talk."
            return nil
        }
        return data
    }

    /// Closes the microphone, whatever was going on. Safe to call again.
    func cancel() {
        ticking?.cancel()
        ticking = nil
        began = nil
        guard let recorder else { return }
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
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
