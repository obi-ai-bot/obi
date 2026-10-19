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

    /// Whether the runner's `turn` lists the words of `echo`: the user's, the same, said at or after
    /// it (within `tolerance`; an older turn with the same words is another message). An answer to
    /// Oby's question shows as its option, which obid lists after the words and the question
    /// ("… The user answered: <option>)").
    static func lists(_ turn: Turn, _ echo: Turn) -> Bool {
        turn.who == .user && turn.date >= echo.date - tolerance
            && (turn.text == echo.text || turn.text.hasSuffix("The user answered: \(echo.text))"))
    }

    /// The echoes the runner hasn't listed yet.
    static func pending(_ echoes: [Turn], runner: [Turn]) -> [Turn] {
        echoes.filter { echo in !runner.contains { lists($0, echo) } }
    }
}

/// What was typed in a message box and not sent yet, by box (Home's, a conversation's, a task's
/// reply box): restored when the box shows again, kept across a relaunch, and gone once sent (the
/// box emptied). The user's own words, so UserDefaults holds them; nothing else is kept this way.
nonisolated enum Drafts {
    static let key = "ObyDrafts"

    /// Home's box.
    static let home = "home"
    /// A conversation's box: `id` nil for a new one, until its first words start it.
    static func conversation(_ id: String?) -> String { "conversation:\(id ?? "new")" }
    /// A task's reply box.
    static func task(_ id: String) -> String { "task:\(id)" }

    static func text(_ box: String, in defaults: UserDefaults = .standard) -> String {
        (defaults.dictionary(forKey: key) as? [String: String])?[box] ?? ""
    }

    /// Keeps `text` as the box's draft; nothing but white space lets it go.
    static func keep(_ text: String, as box: String, in defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let kept = ChatThread.words(text) == nil ? nil : text
        guard all[box] != kept else { return }
        all[box] = kept
        defaults.set(all, forKey: key)
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
