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
        /// At 80% of its weekly limit the account takes only jobs the user sends to it by name, until
        /// its week resets (`AccountState.isReserved` in the engine).
        func reserved(at now: Date = .now) -> Bool {
            (sevenDay ?? 0) >= Usage.reserve && (sevenDayResets ?? .distantFuture) > now
        }
    }

    /// How the weekly window is going against the clock.
    nonisolated struct Pace: Equatable, Sendable {
        /// The share of the week gone, 0...1.
        var gone: Double
        /// When the limit runs out at this rate, before it resets; nil when it lasts the week.
        var runsOut: Date?

        /// Using the week faster than it passes.
        var ahead: Bool { runsOut != nil }
    }

    /// The share of the weekly limit kept for jobs sent to the account by name, as routing keeps it
    /// (`AccountState.reserve`; a test keeps the two equal).
    static let reserve = 0.8
    static let reservedText = "Reserved: only jobs you send it"

    /// How the 7-day window is paced, or nil for another window or one without a reset time. At
    /// this rate, used/gone of the limit is gone by the reset, so it runs out early when used > gone.
    static func pace(_ window: Window, now: Date = .now) -> Pace? {
        guard window.hours == 168, let resets = window.resets else { return nil }
        let length = Double(window.hours) * 3600
        let elapsed = min(max(length - resets.timeIntervalSince(now), 0), length)
        let gone = elapsed / length
        // In the week's first minute there's no rate to go by yet.
        guard window.used > gone, elapsed >= 60 else { return Pace(gone: gone, runsOut: nil) }
        let runsOut = window.used >= 1 ? now : now.addingTimeInterval(elapsed * (1 - window.used) / window.used)
        return Pace(gone: gone, runsOut: runsOut)
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
        when(resets, now: now, spoken: spoken, locale: locale, timeZone: timeZone).map { "resets \($0)" } ?? "resets soon"
    }

    /// "in 2 h 10 min" within the day, else "Tue 14:00"; `weekday` gives just "Tue".
    private static func when(_ date: Date, now: Date, spoken: Bool, weekday: Bool = false,
                              locale: Locale, timeZone: TimeZone) -> String? {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        if seconds < 60 { return nil }
        if seconds < 24 * 3600 {
            let hours = seconds / 3600, minutes = seconds % 3600 / 60
            var parts: [String] = []
            if hours > 0 { parts.append(spoken ? "\(hours) hour\(hours == 1 ? "" : "s")" : "\(hours) h") }
            if minutes > 0 { parts.append(spoken ? "\(minutes) minute\(minutes == 1 ? "" : "s")" : "\(minutes) min") }
            return "in " + parts.joined(separator: " ")
        }
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated)
        return date.formatted(weekday ? style : style.hour().minute())
    }

    /// "30% of the week gone · runs out Tue at this pace" when ahead of pace, else "50% of the week
    /// gone · resets Wed 14:00". Nil for a window without pace.
    static func paceText(_ window: Window, now: Date = .now, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        paceParts(window, now: now, locale: locale, timeZone: timeZone)?.joined(separator: " · ")
    }

    private static func paceParts(_ window: Window, now: Date, spoken: Bool = false, locale: Locale, timeZone: TimeZone) -> [String]? {
        guard let pace = pace(window, now: now), let resets = window.resets else { return nil }
        let gone = "\(percent(pace.gone)) of the week gone"
        guard let runsOut = pace.runsOut else {
            return [gone, resetText(resets, now: now, spoken: spoken, locale: locale, timeZone: timeZone)]
        }
        let at = when(runsOut, now: now, spoken: spoken, weekday: true, locale: locale, timeZone: timeZone)
        return [gone, at.map { "runs out \($0) at this pace" } ?? "runs out now"]
    }

    /// "63% used", then the reset time ("resets in 2 h 10 min") or, on the weekly bar, the pace.
    static func used(_ window: Window) -> String { percent(window.used) + " used" }

    /// "63% used · resets in 2 h 10 min" under a bar; the weekly one says "62% used · 30% of the
    /// week gone · runs out Tue at this pace".
    static func line(_ window: Window, now: Date = .now, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let after = paceText(window, now: now, locale: locale, timeZone: timeZone)
            ?? window.resets.map { resetText($0, now: now, locale: locale, timeZone: timeZone) }
        return [used(window), after].compactMap { $0 }.joined(separator: " · ")
    }

    /// What VoiceOver reads for a card: "Codex, Deskree: 63% of the 5-hour limit used, resets in
    /// 2 hours, 12% of the 7-day limit used, 30% of the week gone, resets Tue 14:00, 1 agent running".
    static func spoken(_ snapshot: Snapshot, now: Date = .now, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if let notice = notice(snapshot) {
            parts.append(notice)
        } else {
            for window in snapshot.windows {
                parts.append("\(percent(window.used)) of the \(window.name) limit used")
                if let pace = paceParts(window, now: now, spoken: true, locale: locale, timeZone: timeZone) {
                    parts += pace
                } else if let resets = window.resets {
                    parts.append(resetText(resets, now: now, spoken: true, locale: locale, timeZone: timeZone))
                }
            }
            if snapshot.reserved(at: now) { parts.append(reservedText) }
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
/// limit window with its reset time (the weekly one with its pace), whether the account is reserved,
/// and how many agents run on it. The countdowns tick every minute.
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
                            HStack(alignment: .firstTextBaseline) {
                                Text(window.name)
                                Spacer()
                                Self.line(window, now: context.date).monospacedDigit().multilineTextAlignment(.trailing)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: min(max(window.used, 0), 1)).tint(Self.color(window.level))
                        }
                    }
                    if snapshot.reserved(at: context.date) {
                        Label(Usage.reservedText, systemImage: "lock")
                            .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    }
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Usage.spoken(snapshot, now: context.date))
        }
    }

    /// `Usage.line`, with the pace in amber while the week is used faster than it passes.
    static func line(_ window: Usage.Window, now: Date) -> Text {
        guard let pace = Usage.paceText(window, now: now) else { return Text(Usage.line(window, now: now)) }
        let ahead = Usage.pace(window, now: now)?.ahead == true
        return Text("\(Usage.used(window)) · \(Text(pace).foregroundStyle(ahead ? Color.orange : Color.secondary))")
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
