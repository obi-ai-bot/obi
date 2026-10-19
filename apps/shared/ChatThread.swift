import SwiftUI

/// What the conversation works out with no view in the way, so the tests read it
/// (apps/ios/tests/ChatTests.swift, apps/mac/tests): the words a send carries, and its echoes, the
/// words shown in the thread the instant Send is pressed until the runner lists them.
nonisolated enum ChatThread {
    /// The words a send carries: trimmed, or nil for nothing to send.
    static func words(_ text: String) -> String? {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? nil : said
    }

    /// The runner lists the user's turn soon after the send; its clock may differ from the
    /// device's by this much.
    static let tolerance: TimeInterval = 60

    /// Whether the runner's `turn` lists the words of `echo`. obid's turn takes the echo's id (the
    /// words go with it, `Runner.planned`), so only that one does: the same words said again
    /// soon after are another message. A runner with one thread, which gives no ids (its turns
    /// name no conversation), by the words: the user's, the same, said at or after it (within
    /// `tolerance`), an answer to Oby's question as its option ("… The user answered: <option>)").
    static func lists(_ turn: Turn, _ echo: Turn) -> Bool {
        if turn.id == echo.id { return true }
        guard turn.conversation == nil else { return false }
        return turn.who == .user && turn.date >= echo.date - tolerance
            && (turn.text == echo.text || turn.text.hasSuffix("The user answered: \(echo.text))"))
    }

    /// The echoes the runner hasn't listed yet.
    static func pending(_ echoes: [Turn], runner: [Turn]) -> [Turn] {
        echoes.filter { echo in !runner.contains { lists($0, echo) } }
    }
}

/// What was typed in a message box and not sent yet, by box (Home's, a conversation's, a task's
/// reply box): restored when the box shows again, kept across a relaunch, and gone once sent (the
/// box emptied), once its conversation is deleted, or a week after it was last typed in (so what
/// was pasted, a secret among it, doesn't stay for good). The user's own words, so UserDefaults
/// holds them; nothing else is kept this way.
nonisolated enum Drafts {
    static let key = "ObyDrafts"
    /// How long an untouched draft is kept.
    static let kept: TimeInterval = 7 * 86_400

    /// Home's box.
    static let home = "home"
    /// A conversation's box: `id` nil for a new one, until its first words start it.
    static func conversation(_ id: String?) -> String { "conversation:\(id ?? "new")" }
    /// A task's reply box.
    static func task(_ id: String) -> String { "task:\(id)" }

    static func text(_ box: String, in defaults: UserDefaults = .standard, now: Date = .now) -> String {
        live(defaults, now: now)[box]?["text"] as? String ?? ""
    }

    /// Keeps `text` as the box's draft, and lets go of every draft past `kept`; nothing but white
    /// space lets the box's go.
    static func keep(_ text: String, as box: String, in defaults: UserDefaults = .standard, now: Date = .now) {
        var all = live(defaults, now: now)
        all[box] = ChatThread.words(text) == nil ? nil : ["text": text, "at": now.timeIntervalSince1970]
        defaults.set(all, forKey: key)
    }

    /// The drafts still kept at `now`, each `["text": String, "at": seconds]`.
    private static func live(_ defaults: UserDefaults, now: Date) -> [String: [String: Any]] {
        let all = defaults.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
        return all.filter { _, draft in (draft["at"] as? Double).map { now.timeIntervalSince1970 - $0 < kept } ?? false }
    }
}

extension View {
    /// The box's `text` is its draft `box` (`Drafts`): restored when it shows or `box` changes,
    /// kept as it's typed.
    func keepsDraft(_ text: Binding<String>, as box: String) -> some View {
        onChange(of: box, initial: true) { text.wrappedValue = Drafts.text(box) }
            .onChange(of: text.wrappedValue) { Drafts.keep(text.wrappedValue, as: box) }
    }
}
