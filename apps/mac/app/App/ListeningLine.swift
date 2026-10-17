import SwiftUI

/// While you hold the talk key (or after fn + Space): what Oby hears, over the window's message
/// box, and how to send it. With the window closed or behind another app, the talk key's pill
/// (apps/mac/app/TalkPill.swift) says it instead.
struct ListeningLine: View {
    let voice: Voice

    private var keyName: String { voice.key == .fn ? "fn" : "Control-Option" }

    static func hint(finishing: Bool, handsFree: Bool, key: String) -> String {
        if finishing { return "Writing it down…" }
        return handsFree ? "Press \(key) to send · Oby listens until you do" : "Let go of \(key) to send · Oby only listens while you hold it"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Tokens.unread).frame(width: 6, height: 6)
                Text("Listening").font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.text)
                Spacer(minLength: 0)
            }
            if let problem = voice.problem {
                Text(problem).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.needs).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(voice.words.isEmpty ? "Say what you need…" : voice.words).font(Tokens.font(Tokens.textLg))
                    .foregroundStyle(voice.words.isEmpty ? Tokens.muted : Tokens.ink).fixedSize(horizontal: false, vertical: true)
            }
            Text(Self.hint(finishing: voice.phase == .finishing, handsFree: voice.handsFree, key: keyName))
                .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.askRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
