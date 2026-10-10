import AVFoundation
import SwiftUI

/// Hold to talk: the microphone is open only while the button is held. The recording goes to
/// the iPhone, which writes it down (SpeechAnalyzer) and asks the brain; the plan comes back here
/// to dispatch with one tap. Without the phone in reach, dictation stands in and the request
/// waits for it.
struct TalkView: View {
    @Environment(Watch.self) private var watch
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var recorder = Recorder()
    @State private var holding = false

    var body: some View {
        switch watch.talk {
        case .none, .recording, .sending:
            holdToTalk
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

    private var holdToTalk: some View {
        VStack(spacing: 8) {
            if watch.reachable {
                Image(systemName: holding ? "waveform" : "mic.fill")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .background(holding ? Color.red : Color.accentColor, in: Circle())
                    .scaleEffect(holding ? 1.08 : 1)
                    .animation(.snappy, value: holding)
                    .gesture(
                        // Pressed and released, wherever the finger goes: the mic follows the hold.
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in if !holding { holding = true; start() } }
                            .onEnded { _ in release() }
                    )
                    .accessibilityLabel("Hold to talk")
                Text(caption).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("Your iPhone isn't in reach. Dictate, and Oby plans it when it is.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            TextFieldLink(prompt: Text("What should Oby do?")) {
                Label(watch.reachable ? "Dictate instead" : "Dictate", systemImage: "keyboard")
            } onSubmit: { watch.ask($0) }
            .disabled(watch.talk != .none)
        }
        // The permission is asked here, before any hold, so a hold starts the mic at once or not at all.
        .task { await recorder.prepare() }
        // A hold the gesture never ends (the screen left, the app went inactive) is a release.
        .onChange(of: scenePhase) { if scenePhase != .active { release() } }
        .onDisappear { release() }
    }

    private var caption: String {
        switch watch.talk {
        case .recording: "Listening… \(recorder.seconds)s"
        case .sending: "Sending to your iPhone…"
        default: recorder.problem ?? "Hold to talk"
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

    /// Synchronous: nothing waits between the hold and the microphone, so a release always finds
    /// the recorder it has to stop.
    private func start() {
        guard watch.talk == .none else { return }
        do {
            try recorder.start()
            watch.talk = .recording
        } catch {
            recorder.problem = error.localizedDescription
            holding = false
        }
    }

    private func release() {
        guard holding else { return }
        holding = false
        stop()
    }

    private func stop() {
        guard watch.talk == .recording else { return }
        guard let audio = recorder.stop() else {
            watch.talk = .none
            return
        }
        guard audio.count <= WatchWire.limit else {
            recorder.problem = "That was too long for the watch. Keep it under \(Recorder.limit) seconds."
            watch.talk = .none
            return
        }
        watch.voice(audio)
    }
}

/// AAC, mono, 16 kHz: small enough for WatchConnectivity, clear enough for speech.
@Observable
final class Recorder {
    /// Longer wouldn't fit in one message to the phone.
    static let limit = 15

    private(set) var seconds = 0
    var problem: String?
    /// Whether the microphone may be used; nil until the user has answered.
    private(set) var allowed: Bool?
    private var recorder: AVAudioRecorder?
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
        recorder.record(forDuration: TimeInterval(Self.limit))
        self.recorder = recorder
        problem = nil
        seconds = 0
        ticking = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { seconds += 1 }
            }
        }
    }

    /// Stops and hands over the recording, or nil when there's too little to send.
    func stop() -> Data? {
        ticking?.cancel()
        guard let recorder else { return nil }
        let heard = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        guard heard >= 0.4, let data = try? Data(contentsOf: file), !data.isEmpty else {
            problem = "Hold the button while you talk."
            return nil
        }
        return data
    }

    func cancel() {
        ticking?.cancel()
        recorder?.stop()
        recorder = nil
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
