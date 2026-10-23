import Foundation

/// One page open over Home (Sangam's Home.tsx `Step`): a kind of work's cards, a task's page, a
/// runner job's live session (#785), the conversation with Oby, or a Settings page. The Swift runner keeps one conversation, so the
/// conversation list (#493) shows only when the runner on this Mac is obid; there's no Obysphere yet.
nonisolated enum WindowStep: Hashable, Sendable {
    case group(WorkType)
    /// Archived (Sangam's ArchiveView): the done tasks that left Home.
    case archived
    case job(id: String, local: Bool)
    case session(id: String)
    case talk
    case settings(SettingsPage)
}

/// Settings' pages, in the side panel's Settings section in this order (Sangam's SettingsView.tsx
/// `SETTINGS_PAGES`, with Memory, docs/onboarding.md section 5, which his design doesn't have yet).
nonisolated enum SettingsPage: String, CaseIterable, Hashable, Sendable {
    case general, runner, sharing, remote, accounts, models, connectors, memory, sphere, vault, about

    var label: String {
        switch self {
        case .general: "General"
        case .runner: "Runner"
        case .sharing: "Sharing"
        case .remote: "Remote access"
        case .accounts: "Accounts"
        case .models: "Models"
        case .connectors: "Connectors"
        case .memory: "Memory"
        case .sphere: "Obysphere"
        case .vault: "Vault"
        case .about: "About"
        }
    }

    /// The pages the side panel lists: the launch build leaves out Sharing and Remote access (`Launch`).
    static func shown(everything: Bool = Launch.everything) -> [SettingsPage] {
        everything ? allCases : allCases.filter { $0 != .sharing && $0 != .remote }
    }
}

/// The launch build (AGENTS.md, the owner's decision of 2026-10-23): Mac share, Runner share, Remote
/// access and every connector but GitHub and Slack are hidden on the Mac and the iPhone, not deleted.
/// `showEverything`, a default with no UI, shows them on Deskree's own Macs:
/// `defaults write <bundle id> showEverything -bool YES`.
nonisolated enum Launch {
    static let everythingKey = "showEverything"
    static var everything: Bool { UserDefaults.standard.bool(forKey: everythingKey) }
    /// The connectors Settings › Connectors lists.
    static let connectors: Set<String> = ["github", "slack"]
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
