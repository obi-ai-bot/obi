import Foundation

/// One page open over Home (Sangam's Home.tsx `Step`): a kind of work's cards, a task's page, or
/// the conversation with Oby. The Mac talks to one runner, which keeps one conversation, so there's
/// no conversation list and no Obysphere until the Mac runs on obid.
nonisolated enum WindowStep: Hashable, Sendable {
    case group(WorkType)
    case job(id: String, local: Bool)
    case talk
}

/// Where you are, as the steps that got you there: the title bar's trail. Each step opens over
/// the one before; the trail follows the way you came, not a fixed hierarchy. Opening a step
/// already in the trail goes back to it rather than adding it again, so a task and its
/// conversation go back and forth. Empty: Home.
nonisolated struct WindowTrail: Equatable, Sendable {
    private(set) var steps: [WindowStep] = []

    var top: WindowStep? { steps.last }
    var isHome: Bool { steps.isEmpty }

    /// Over what's open, or back to it if it's already in the trail.
    mutating func push(_ step: WindowStep) {
        if let at = steps.firstIndex(of: step) { steps.removeSubrange((at + 1)...) } else { steps.append(step) }
    }

    /// Back to the step at `index`: everything over it leaves. Below 0 is Home.
    mutating func back(to index: Int) {
        steps = index < 0 ? [] : Array(steps.prefix(index + 1))
    }

    /// Back one: Esc, and the chevron on a page with nothing under it.
    mutating func back() { back(to: steps.count - 2) }

    /// A fresh start (from the side panel, a chip, Home's box): what was open leaves, and `steps`
    /// open in order.
    mutating func start(_ steps: WindowStep...) { self.steps = steps }

    /// Back to Home.
    mutating func closeAll() { steps = [] }

    /// A step that can't show any more (its job left every list): it goes, and what's over it.
    mutating func drop(where gone: (WindowStep) -> Bool) {
        if let at = steps.firstIndex(where: gone) { back(to: at - 1) }
    }
}

/// The side panel's width, set by dragging its edge (Sangam's Home.tsx): past its limits it gives
/// less and less (UIKit's rubber band), and on release it settles within them.
nonisolated enum PanelWidth {
    /// How far past a limit the panel can stretch, and how stiffly.
    static let stretch: CGFloat = 60
    static let stiff: CGFloat = 0.55

    private static func band(_ over: CGFloat) -> CGFloat { (1 - 1 / ((over * stiff) / stretch + 1)) * stretch }

    /// While dragging.
    static func dragging(_ width: CGFloat) -> CGFloat {
        if width > Tokens.sidebarMax { return Tokens.sidebarMax + band(width - Tokens.sidebarMax) }
        if width < Tokens.sidebarMin { return Tokens.sidebarMin - band(Tokens.sidebarMin - width) }
        return width
    }

    /// Let go: where it rests.
    static func settled(_ width: CGFloat) -> CGFloat { min(Tokens.sidebarMax, max(Tokens.sidebarMin, width.rounded())) }
}

/// What Home says over its chips (Sangam's Home.tsx `attention`): what's running and what needs
/// you; with neither, Oby asking for something to do.
nonisolated enum HomeLine {
    static func attention(running: Int, needs: Int) -> String {
        let r = "\(running) running task\(running == 1 ? "" : "s")"
        let n = "\(needs) need\(needs == 1 ? "s" : "") you"
        if running > 0 && needs > 0 { return "\(r) · \(n)" }
        if running > 0 { return "\(r) · nothing needs you" }
        if needs > 0 { return n }
        return idle
    }

    static let idle = "All quiet. Give me something to work on"

    /// Home's message box asks by your first name, as Sangam's does.
    static func placeholder(fullName: String) -> String {
        let first = fullName.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "What do you want me to work on?" : "What do you want me to work on, \(first)?"
    }

    /// The iPhone doesn't know its owner's name: the linked Mac's own name often says it
    /// ("Wellington's MacBook Pro"). Nil when it doesn't.
    static func owner(ofMac name: String?) -> String? {
        guard let name, let mark = name.firstIndex(where: { $0 == "'" || $0 == "’" }),
              name[mark...].dropFirst().hasPrefix("s ") else { return nil }
        let owner = name[..<mark].trimmingCharacters(in: .whitespaces)
        return owner.isEmpty || owner.contains(" ") ? nil : owner
    }
}

extension WindowTrail {
    /// Whether the job's page is what shows, or what the conversation on top was opened from: its
    /// row in the side panel is lit.
    func shows(job: String, local: Bool) -> Bool {
        let step = WindowStep.job(id: job, local: local)
        if top == step { return true }
        return top == .talk && steps.count > 1 && steps[steps.count - 2] == step
    }
}

extension ConversationModel {
    /// Whether a turn of the conversation started the job: its page offers the way there.
    static func started(_ job: String, in turns: [Turn]) -> Bool {
        turns.contains { $0.jobs?.contains(job) ?? false }
    }
}
