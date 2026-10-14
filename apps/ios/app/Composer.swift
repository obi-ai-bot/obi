import SwiftUI

/// The field where you type a task or dictate one, with Send: at the bottom of Home and of Chat,
/// one and the same. Tap the mic and what you say goes into the field as it's heard; tap Stop and
/// the words stay there to edit and send (apps/ios/app/README.md, "Voice input").
struct Composer: View {
    @Environment(Phone.self) private var phone
    @Binding var text: String
    var prompt = "Type a task, like “Review oby PR #12”"
    /// The keyboard's focus, owned by the screen so it can take it after an edit or let it go.
    var typing: FocusState<Bool>.Binding
    /// Sends the field; true when it has dictated words, so Oby may speak its reply.
    let onSend: (_ spoken: Bool) -> Void
    @State private var selection: TextSelection?
    /// The field has dictated words in it: cleared, it's typed again.
    @State private var dictated = false
    /// What dictation last put in the field. The field holding anything else means someone
    /// typed or it was filled from elsewhere, and dictation stops there.
    @State private var written: String?

    private var sendable: Bool { ChatThread.words(text) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if phone.voice.active || phone.voice.finishing {
                Text(phone.voice.finishing ? "Writing down…" : phone.voice.listening ? "Listening…" : "Getting ready…")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            if let problem = phone.voice.problem {
                Text(problem).font(.footnote).foregroundStyle(.red).padding(.horizontal, 12)
            }
            HStack(spacing: 8) {
                TextField(prompt, text: $text, selection: $selection, axis: .vertical)
                    .lineLimit(1...4)
                    .focused(typing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityAddTraits(phone.voice.listening ? .updatesFrequently : [])
                DictationMic(active: phone.voice.active, listening: phone.voice.listening,
                             finishing: phone.voice.finishing, level: phone.voice.level, toggle: toggleDictation)
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
        .onChange(of: text) {
            // Typed, sent or filled from elsewhere: the words heard so far stay, later ones don't come.
            if text != written, phone.voice.active || phone.voice.finishing { phone.voice.cancel() }
            if text.isEmpty { dictated = false }
        }
    }

    private func send() {
        guard sendable else { return }
        onSend(dictated)
    }

    /// What the field holds with `words` dictated after `prefix`: a space between, unless there's one.
    static func draft(_ prefix: String, _ words: String) -> String {
        prefix.isEmpty || prefix.last?.isWhitespace == true ? prefix + words : prefix + " " + words
    }

    /// The mic: dictation starts after what the field holds, or stops and keeps the words.
    private func toggleDictation() {
        if phone.voice.active {
            phone.voice.finish()
            return
        }
        typing.wrappedValue = false
        let prefix = text
        written = text
        phone.dictate { words in
            guard !words.isEmpty, text == written else { return }
            text = Self.draft(prefix, words)
            written = text
            dictated = true
            selection = TextSelection(insertionPoint: text.endIndex)
        }
    }
}

/// The composer's mic: Dictate, or Stop with the input's level under it while it listens.
private struct DictationMic: View {
    let active: Bool
    let listening: Bool
    let finishing: Bool
    let level: Float
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 3) {
                Image(systemName: active ? "stop.fill" : "mic.fill")
                    .font(.body)
                if listening {
                    Capsule()
                        .fill(Color.red.opacity(0.5))
                        .frame(width: 6 + CGFloat(level) * 18, height: 3)
                }
            }
            .foregroundStyle(active ? Color.red : Color.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(finishing)
        .accessibilityLabel(active ? "Stop dictating" : "Dictate")
        .accessibilityHint(active ? "Keeps your words in the field to edit and send." : "Your words go into the field as you speak.")
    }
}
