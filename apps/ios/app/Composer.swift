import SwiftUI

/// The message box (Sangam's Composer.tsx): a 46-point pill with a thin edge, the words growing to
/// five lines, and at its end the mic, which turns into Send ↑ once there's text. The same box on
/// Home, in a conversation and on a task's page. Tap the mic and what you say goes into the field
/// as it's heard; tap Stop and the words stay there to edit and send (apps/ios/app/README.md,
/// "Voice input"). Before them, the usage gauge whenever there's an account. There's no + : the
/// iPhone sends no attachments yet.
struct Composer: View {
    @Environment(Phone.self) private var phone
    @Binding var text: String
    var prompt = "Reply to Oby…"
    /// The keyboard's focus, owned by the screen so it can take it after an edit or let it go.
    var typing: FocusState<Bool>.Binding
    /// Sends the field; true when it has dictated words ("You, by voice").
    let onSend: (_ spoken: Bool) -> Void
    /// While Oby works on a turn: Stop takes the end slot until there's something to send.
    var onStop: (() -> Void)? = nil
    @State private var selection: TextSelection?
    /// The field has dictated words in it: cleared, it's typed again.
    @State private var dictated = false
    /// What dictation last put in the field. The field holding anything else means someone
    /// typed or it was filled from elsewhere, and dictation stops there.
    @State private var written: String?

    private var sendable: Bool { ChatThread.words(text) != nil }
    private var dictating: Bool { phone.voice.active || phone.voice.finishing }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dictating {
                Text(phone.voice.finishing ? "Writing down…" : phone.voice.listening ? "Listening…" : "Getting ready…")
                    .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.horizontal, 16)
            }
            if let problem = phone.voice.problem {
                Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.horizontal, 16)
            }
            HStack(alignment: .bottom, spacing: 2) {
                TextField("", text: $text, selection: $selection, prompt: Text(prompt).foregroundStyle(Tokens.muted), axis: .vertical)
                    .lineLimit(1...5)
                    .font(Tokens.font(Tokens.textLg))
                    .foregroundStyle(Tokens.openTitle)
                    .tint(Tokens.ink)
                    .focused(typing)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(minHeight: 32)
                    .accessibilityAddTraits(phone.voice.listening ? .updatesFrequently : [])
                if !phone.accounts.isEmpty { UsageGauge() }
                end
            }
            .padding(6)
            .frame(minHeight: 46)
            .overlay {
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .strokeBorder(typing.wrappedValue ? Tokens.fieldEdgeOn : Tokens.line)
            }
            .contentShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
            .onTapGesture { typing.wrappedValue = true }
            .animation(Tokens.fade, value: typing.wrappedValue)
        }
        .padding(.horizontal, Tokens.gutter)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Tokens.bg)
        .onChange(of: text) {
            // Typed, sent or filled from elsewhere: the words heard so far stay, later ones don't come.
            if text != written, dictating { phone.voice.cancel() }
            if text.isEmpty { dictated = false }
        }
    }

    /// The mic while the box is empty (Stop while it listens), Send once there's text.
    @ViewBuilder private var end: some View {
        ZStack {
            if let onStop, !dictating, !sendable {
                // A filled square on a `hover` circle (docs/ios-design.md): ends the turn under way.
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(Tokens.font(11, .semibold)).foregroundStyle(Tokens.ink)
                        .frame(width: 32, height: 32).background(Tokens.hover, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
                .accessibilityHint("Ends what Oby is doing")
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else if dictating || !sendable {
                DictationMic(active: phone.voice.active, listening: phone.voice.listening,
                             finishing: phone.voice.finishing, level: phone.voice.level, toggle: toggleDictation)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                // A plain arrow, like the mic it takes the place of (Sangam's `.composer-send`).
                Button(action: send) {
                    Image(systemName: "arrow.up").font(Tokens.font(18, .medium))
                        .foregroundStyle(Tokens.ink)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 32, height: 32)
        .animation(Tokens.spring, value: sendable)
        .animation(Tokens.spring, value: onStop == nil)
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

/// The box's mic: Dictate, or a red Stop with the input's level under it while it listens.
private struct DictationMic: View {
    let active: Bool
    let listening: Bool
    let finishing: Bool
    let level: Float
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 2) {
                Image(systemName: active ? "stop.fill" : "waveform")
                    .font(Tokens.font(active ? 13 : 16, .regular))
                if listening {
                    Capsule()
                        .fill(Tokens.danger.opacity(0.6))
                        .frame(width: 6 + CGFloat(level) * 14, height: 2)
                }
            }
            .foregroundStyle(active ? Tokens.danger : Tokens.muted)
            .frame(width: 32, height: 32)
            .background(active ? Tokens.active : .clear, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(finishing)
        .accessibilityLabel(active ? "Stop dictating" : "Dictate")
        .accessibilityHint(active ? "Keeps your words in the field to edit and send." : "Your words go into the field as you speak.")
    }
}

/// How much the accounts have used this week (Sangam's UsageGauge): a gauge with a dot while any is
/// past 80% (yellow) or 90% (red); a tap shows each account's week, and the way to Settings.
private struct UsageGauge: View {
    @Environment(Phone.self) private var phone
    @State private var open = false

    var body: some View {
        let weeks = phone.accounts.map { Usage.week($0.usage) }
        let dot = UsageDot.of(weeks: weeks)
        Button { open.toggle() } label: {
            Image(systemName: "gauge.with.dots.needle.33percent").font(Tokens.font(17))
                .foregroundStyle(open ? Tokens.ink : Tokens.muted)
                .frame(width: 32, height: 32)
                .background(open ? Tokens.active : .clear, in: Circle())
                .overlay(alignment: .topTrailing) {
                    if dot != .none {
                        Circle().fill(dot == .over ? Tokens.over : Tokens.full).frame(width: 6, height: 6).offset(x: -4, y: 5)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Usage this week" + (dot == .none ? "" : ", an account is nearly full"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            panel.presentationCompactAdaptation(.popover)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Usage this week").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.label)
                Spacer()
                Button { open = false; phone.panel = nil; phone.homePath.append(.settings) } label: {
                    Image(systemName: "gearshape").font(Tokens.font(15)).foregroundStyle(Tokens.muted).frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manage accounts")
            }
            .padding(.leading, 8)
            ForEach(phone.accounts) { account in
                let week = Usage.week(account.usage)
                let level = UsageDot.of(weeks: [week])
                HStack(alignment: .top, spacing: 10) {
                    AgentMark(agent: account.agent).font(Tokens.font(13)).frame(width: 16).foregroundStyle(Tokens.muted)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(Usage.tool(account.agent)) · \(account.name)").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.ink).fadeOut()
                            if let resets = account.sevenDayResets {
                                Text(Usage.resetText(resets)).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).fixedSize()
                            }
                            Text(week.map(Usage.percent) ?? "–").font(Tokens.font(Tokens.textBase)).monospacedDigit()
                                .foregroundStyle(level == .over ? Tokens.over : level == .high ? Tokens.full : Tokens.text)
                                .frame(minWidth: 32, alignment: .trailing)
                        }
                        SetMeter(used: (week ?? 0) * 100)
                    }
                }
                .padding(8)
            }
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 20)
        .frame(width: 340)
        .background(Tokens.surface)
    }
}
