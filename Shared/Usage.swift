import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// What Settings says about an account's subscription usage, on the iPhone and the Mac. Foundation
/// only (the card at the end is SwiftUI, for the apps): the runner's tests build it too.
nonisolated enum Usage {
    /// How full a window is: green, amber from 70%, red from 90%.
    nonisolated enum Level: Equatable, Sendable { case fine, warning, critical }

    /// One limit window of an account, as a card shows it.
    nonisolated struct Window: Equatable, Sendable {
        var hours: Int
        var used: Double
        var resets: Date?

        /// "5-hour", "7-day".
        var name: String { hours % 24 == 0 ? "\(hours / 24)-day" : "\(hours)-hour" }
        var level: Level { Usage.level(used) }
    }

    /// One account's usage, the same on both apps.
    nonisolated struct Snapshot: Equatable, Sendable {
        var agent: String
        var name: String
        var label: String?
        var fiveHour: Double?
        var sevenDay: Double?
        var fiveHourResets: Date?
        var sevenDayResets: Date?
        var running = 0

        var tool: String { Usage.tool(agent) }
        var signedIn: Bool { label != nil }
        /// "Team" from "Team · name@example.com", or nil.
        var plan: String? { Usage.plan(label) }
        /// "Deskree · Team", or just the name while the plan is unknown.
        var title: String { plan.map { "\(name) · \($0)" } ?? name }

        /// The windows the tool reported, in order; empty while nothing has.
        var windows: [Window] {
            [fiveHour.map { Window(hours: 5, used: $0, resets: fiveHourResets) },
             sevenDay.map { Window(hours: 168, used: $0, resets: sevenDayResets) }].compactMap { $0 }
        }
        /// The busier window, or nil without usage.
        var busiest: Double? { [fiveHour, sevenDay].compactMap { $0 }.max() }
    }

    static func level(_ used: Double) -> Level { used >= 0.9 ? .critical : used >= 0.7 ? .warning : .fine }

    /// "Claude Code", "Codex", "Cursor", "Gemini", or the agent's id capitalized.
    static func tool(_ agent: String) -> String {
        ["claude": "Claude Code", "codex": "Codex", "cursor": "Cursor", "gemini": "Gemini"][agent] ?? agent.capitalized
    }

    /// The SF Symbol next to the tool's name.
    static func symbol(_ agent: String) -> String {
        ["claude": "terminal", "codex": "chevron.left.forwardslash.chevron.right", "cursor": "cursorarrow", "gemini": "sparkles"][agent] ?? "cpu"
    }

    /// The tools among these agents, as Settings groups them: Claude Code, Codex, then the rest by name.
    static func agents(_ agents: [String]) -> [String] {
        let order = ["claude", "codex"]
        return Array(Set(agents)).sorted { a, b in
            let (i, j) = (order.firstIndex(of: a) ?? order.count, order.firstIndex(of: b) ?? order.count)
            return i != j ? i < j : tool(a) < tool(b)
        }
    }

    /// Whether the tool tells Oby about its limits at all: Claude Code and Codex do.
    static func reports(_ agent: String) -> Bool { agent == "claude" || agent == "codex" }

    /// The plan from a tool's label, like "Max" from "Max · name@example.com". An email alone gives nil.
    static func plan(_ label: String?) -> String? {
        guard let first = label?.split(separator: " · ").first.map(String.init), !first.contains("@") else { return nil }
        return first
    }

    /// Why a card has no bars: signed out, a tool that never reports, or one that hasn't yet. Nil
    /// when there are bars.
    static func notice(_ snapshot: Snapshot) -> String? {
        if !snapshot.signedIn { return "Signed out" }
        if !reports(snapshot.agent) { return "\(snapshot.tool) doesn't report usage" }
        return snapshot.windows.isEmpty ? "No usage yet: it updates after its next job" : nil
    }

    /// "63%".
    static func percent(_ used: Double) -> String {
        (min(max(used, 0), 1)).formatted(.percent.precision(.fractionLength(0)))
    }

    /// "resets in 2 h 10 min" within the day, else "resets Tue 14:00" (as the locale writes times);
    /// `spoken` says "resets in 2 hours 10 minutes" for VoiceOver.
    static func resetText(_ resets: Date, now: Date = .now, spoken: Bool = false,
                          locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let seconds = Int(resets.timeIntervalSince(now).rounded())
        if seconds < 60 { return "resets soon" }
        if seconds < 24 * 3600 {
            let hours = seconds / 3600, minutes = seconds % 3600 / 60
            var parts: [String] = []
            if hours > 0 { parts.append(spoken ? "\(hours) hour\(hours == 1 ? "" : "s")" : "\(hours) h") }
            if minutes > 0 { parts.append(spoken ? "\(minutes) minute\(minutes == 1 ? "" : "s")" : "\(minutes) min") }
            return "resets in " + parts.joined(separator: " ")
        }
        let day = resets.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated).hour().minute())
        return "resets \(day)"
    }

    /// "63% used · resets in 2 h 10 min", under a bar.
    static func line(_ window: Window, now: Date = .now) -> String {
        [percent(window.used) + " used", window.resets.map { resetText($0, now: now) }].compactMap { $0 }.joined(separator: " · ")
    }

    /// What VoiceOver reads for a card: "Codex, Deskree: 63% of the 5-hour limit used, resets in
    /// 2 hours, 12% of the 7-day limit used, resets Tue 14:00, 1 agent running".
    static func spoken(_ snapshot: Snapshot, now: Date = .now) -> String {
        var parts: [String] = []
        if let notice = notice(snapshot) {
            parts.append(notice)
        } else {
            for window in snapshot.windows {
                parts.append("\(percent(window.used)) of the \(window.name) limit used")
                if let resets = window.resets { parts.append(resetText(resets, now: now, spoken: true)) }
            }
        }
        if snapshot.running > 0 { parts.append(runningText(snapshot.running)) }
        return "\(snapshot.tool), \(snapshot.name): " + parts.joined(separator: ", ")
    }

    /// "1 agent running", "3 agents running".
    static func runningText(_ count: Int) -> String { "\(count) agent\(count == 1 ? "" : "s") running" }

    /// The line above the cards: "All limits under 50%", or the account with the most room left,
    /// like "Most room: Codex, Deskree · Plus (12% used)", until some signed-in account reports usage.
    static func summary(_ snapshots: [Snapshot]) -> String {
        let known = snapshots.filter(\.signedIn).compactMap { snapshot in snapshot.busiest.map { (snapshot, $0) } }
        guard let roomiest = known.min(by: { $0.1 < $1.1 }) else {
            return snapshots.contains(where: \.signedIn) ? "No usage yet: it updates after the next job." : "No account is signed in."
        }
        if known.allSatisfy({ $0.1 < 0.5 }) { return "All limits under 50%" }
        return "Most room: \(roomiest.0.tool), \(roomiest.0.title) (\(percent(roomiest.1)) used)"
    }
}

#if canImport(SwiftUI)
/// One account's usage card, the same on the iPhone and the Mac: its tool, name and plan, a bar per
/// limit window with its reset time, and how many agents run on it. The countdowns tick every minute.
struct UsageCard: View {
    var snapshot: Usage.Snapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(snapshot.tool, systemImage: Usage.symbol(snapshot.agent))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if snapshot.running > 0 {
                        Text(Usage.runningText(snapshot.running))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                Text(snapshot.title).font(.headline)
                if let notice = Usage.notice(snapshot) {
                    Text(notice).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.windows, id: \.hours) { window in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(window.name)
                                Spacer()
                                Text(Usage.line(window, now: context.date)).monospacedDigit()
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: min(max(window.used, 0), 1)).tint(Self.color(window.level))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Usage.spoken(snapshot, now: context.date))
        }
    }

    static func color(_ level: Usage.Level) -> Color {
        switch level {
        case .fine: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}
#endif
