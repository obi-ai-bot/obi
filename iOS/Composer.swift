import SwiftUI

/// The field where you type a task or hold the mic, with Send: at the bottom of Home and of Chat,
/// one and the same. While you hold the mic, what it hears shows above the field, with the ways
/// to lock, cancel and send (iOS/README.md, "Voice input").
struct Composer: View {
    @Environment(Phone.self) private var phone
    @Binding var text: String
    var prompt = "Type a task, like “Review oby PR #12”"
    /// The keyboard's focus, owned by the screen so it can take it after an edit or let it go.
    var typing: FocusState<Bool>.Binding
    let onSend: () -> Void

    private var sendable: Bool { ChatThread.words(text) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if phone.voice.held || phone.voice.finishing {
                if phone.voice.listening {
                    Label(phone.voice.locked ? "Listening · Locked" : "Slide up to lock", systemImage: phone.voice.locked ? "lock.fill" : "arrow.up")
                        .font(.caption).padding(.horizontal, 12)
                    if phone.voice.locked {
                        HStack {
                            Button("Cancel") { phone.cancelVoice() }
                            Spacer()
                            Button("Stop and send") { phone.voice.finish() }
                        }.padding(.horizontal, 12)
                    } else {
                        Text("Slide left to cancel").font(.caption).padding(.horizontal, 12)
                    }
                }
                Text(phone.voice.words.isEmpty ? (phone.voice.finishing ? "Writing down…" : phone.voice.listening ? "Listening…" : "Getting ready…") : phone.voice.words)
                    .font(.subheadline).padding(.horizontal, 12)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let problem = phone.voice.problem {
                Text(problem).font(.footnote).foregroundStyle(.red).padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                TextField(prompt, text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .focused(typing)
                    .submitLabel(.send)
                    .onSubmit(send)
                HoldMic(listening: phone.voice.listening, locked: phone.voice.locked, enabled: !phone.voice.finishing,
                        start: { typing.wrappedValue = false; phone.holdMic() }, lock: { phone.voice.lock(); return phone.voice.locked },
                        release: { phone.releaseMic() }, cancel: { phone.cancelVoice() },
                        stop: { phone.voice.finish() })
                    .frame(width: 44, height: 44)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(sendable ? 1 : 0.4), in: Circle())
                }
                .disabled(!sendable)
                .accessibilityLabel("Send")
            }
            .padding(.leading, 18)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func send() {
        guard sendable else { return }
        onSend()
    }
}
