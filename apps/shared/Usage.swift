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
        /// Until when the user let it past its weekly reserve (#278), or nil.
        var reserveLiftedUntil: Date? = nil
        /// What the runner says about the login (`AccountState.runnerSignedIn`); nil: the label says.
        var runnerSignedIn: Bool? = nil

        var tool: String { Usage.tool(agent) }
        var signedIn: Bool { runnerSignedIn ?? (label != nil) }
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
        /// its week resets, unless the user lifted that (`AccountState.isReserved` in the engine).
        func reserved(at now: Date = .now) -> Bool { inReserve(at: now) && liftedUntil(at: now) == nil }
        /// At 80% of its week before the reset, lifted or not: Settings' switch shows then.
        func inReserve(at now: Date = .now) -> Bool {
            (sevenDay ?? 0) >= Usage.reserve && (sevenDayResets ?? .distantFuture) > now
        }
        /// Until when it's past its reserve, or nil.
        func liftedUntil(at now: Date = .now) -> Date? { reserveLiftedUntil.flatMap { $0 > now ? $0 : nil } }
        /// "Use Personal anyway" shows for it: reserved, signed in, and under 95% of both windows
        /// (`AccountState.mayLiftReserve`; a window past its reset is empty).
        func mayLift(at now: Date = .now) -> Bool {
            let under = { (used: Double?, resets: Date?) in (used ?? 0) < Usage.nearlyFull || (resets ?? .distantFuture) <= now }
            return signedIn && reserved(at: now) && under(fiveHour, fiveHourResets) && under(sevenDay, sevenDayResets)
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
    /// Past this share of a window an account gets nothing, its reserve lifted or not (`AccountState.nearlyFull`).
    static let nearlyFull = 0.95
    static let reservedText = "Reserved: only jobs you send it"
    /// Settings' switch on an account in its weekly reserve (#278).
    static let liftText = "Use past reserve this week"

    /// "Use Personal anyway (82% of week)": the button that lifts an account's reserve (#278).
    static func useAnyway(_ snapshot: Snapshot) -> String {
        "Use \(snapshot.name) anyway" + (snapshot.sevenDay.map { " (\(percent($0)) of week)" } ?? "")
    }

    /// The quiet line under it: "Oby keeps 20% of each week in reserve; this lifts it for Personal
    /// until Thu 7:00 PM." Without a reset time, "until its week resets".
    static func liftNote(_ snapshot: Snapshot, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let until = snapshot.sevenDayResets.map { "until " + day($0, locale: locale, timeZone: timeZone) } ?? "until its week resets"
        return "Oby keeps \(percent(1 - reserve)) of each week in reserve; this lifts it for \(snapshot.name) \(until)."
    }

    /// "Past its reserve until Thu 7:00 PM", on the card of an account whose reserve is lifted.
    static func liftedText(_ until: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        "Past its reserve until " + day(until, locale: locale, timeZone: timeZone)
    }

    /// The accounts a job waiting for room offers "Use … anyway" on (#278): the ones its `waiting`
    /// names (`reserved`) that the app knows and whose lift would help (`Snapshot.mayLift`), in
    /// that order.
    static func liftable<Item>(_ reserved: [String]?, among items: [Item], id: (Item) -> String, usage: (Item) -> Snapshot,
                               now: Date = .now) -> [Item] {
        (reserved ?? []).compactMap { wanted in items.first { id($0) == wanted } }.filter { usage($0).mayLift(at: now) }
    }

    /// "Thu 7:00 PM", as the locale writes times.
    static func day(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.abbreviated).hour().minute())
    }

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
            if snapshot.inReserve(at: now), let until = snapshot.liftedUntil(at: now) { parts.append(liftedText(until, locale: locale, timeZone: timeZone)) }
        }
        if snapshot.running > 0 { parts.append(runningText(snapshot.running)) }
        return "\(snapshot.tool), \(snapshot.name): " + parts.joined(separator: ", ")
    }

    /// "1 agent running", "3 agents running".
    static func runningText(_ count: Int) -> String { "\(count) agent\(count == 1 ? "" : "s") running" }

    /// What Settings says about an account's Tetrix (#130): "Tetrix: connected · used in 9 of 12
    /// recent jobs (75%)", "Tetrix: not connected: sign in", or "Tetrix: not checked yet".
    static func tetrix(_ connected: Bool?, jobs: Int, used: Int) -> String {
        let state = switch connected {
        case true?: "Tetrix: connected"
        case false?: "Tetrix: not connected: sign in"
        case nil: "Tetrix: not checked yet"
        }
        guard jobs > 0 else { return state }
        return state + " · used in \(used) of \(jobs) recent job\(jobs == 1 ? "" : "s") (\(percent(Double(used) / Double(jobs))))"
    }

    // MARK: Sangam's usage rows (Settings › Accounts on the Mac, docs/mac-design.md B2)

    /// How much of its week an account has used, 0...1: none once the week has reset; nil while
    /// unknown or signed out.
    static func week(_ snapshot: Snapshot, now: Date = .now) -> Double? {
        guard snapshot.signedIn, let used = snapshot.sevenDay else { return nil }
        return (snapshot.sevenDayResets ?? .distantFuture) > now ? used : 0
    }

    /// "36% used", at the row's right, or nil while its week is unknown.
    static func usedText(_ snapshot: Snapshot, now: Date = .now) -> String? {
        week(snapshot, now: now).map { percent($0) + " used" }
    }

    /// The line under the account's name, in Sangam's words: "Paid by Deskree · Resets Thursday"; why
    /// there's no meter in place of the reset ("Signed out", "No usage yet…"). With no payer (obid
    /// has none yet), it starts at the reset.
    static func about(_ snapshot: Snapshot, payer: String, now: Date = .now, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if !payer.isEmpty { parts.append("Paid by \(payer)") }
        if let notice = notice(snapshot) {
            parts.append(notice)
        } else if let resets = snapshot.sevenDayResets, resets > now, week(snapshot, now: now) != nil {
            parts.append(resetsDay(resets, now: now, locale: locale, timeZone: timeZone))
        }
        return parts.joined(separator: " · ")
    }

    /// "Resets Thursday", or "Resets in 5 h" within the day.
    static func resetsDay(_ date: Date, now: Date = .now, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 24 * 3600 { return "Resets in \(max(1, Int((seconds / 3600).rounded(.up)))) h" }
        return "Resets " + date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.wide))
    }

    /// The 5-hour window, only once it's past 80% (Sangam shows the week alone): "5-hour limit 85%
    /// used · resets in 2 h".
    static func fiveHourLine(_ snapshot: Snapshot, now: Date = .now, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard snapshot.signedIn, let used = snapshot.fiveHour, used > 0.8, (snapshot.fiveHourResets ?? .distantFuture) > now else { return nil }
        let resets = snapshot.fiveHourResets.map { " · " + resetText($0, now: now, locale: locale, timeZone: timeZone) } ?? ""
        return "5-hour limit \(percent(used)) used" + resets
    }

    /// The line over the accounts: the signed-in one with the most of its week left, "Most room:
    /// Deskree on Codex, 88% left this week", until one reports usage.
    static func mostRoom(_ snapshots: [Snapshot], now: Date = .now) -> String {
        let weeks = snapshots.compactMap { snapshot in week(snapshot, now: now).map { (snapshot, $0) } }
        guard let roomiest = weeks.min(by: { $0.1 < $1.1 }) else {
            if snapshots.isEmpty { return "None yet" }
            return snapshots.contains(where: \.signedIn) ? "No usage yet: it updates after the next job." : "No account is signed in."
        }
        return "Most room: \(roomiest.0.name) on \(roomiest.0.tool), \(percent(1 - roomiest.1)) left this week"
    }

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
                    } else if snapshot.inReserve(at: context.date), let until = snapshot.liftedUntil(at: context.date) {
                        Label(Usage.liftedText(until), systemImage: "lock.open")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
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

/// Settings' "Use past reserve this week" switch on an account in its weekly reserve (#278), with
/// the line that says until when. It turns off by itself at the reset: the account leaves its
/// reserve then. `lift` asks the engine or the runner; what it says wrong shows under the switch.
struct ReserveSwitch: View {
    var snapshot: Usage.Snapshot
    var lift: @MainActor (Bool) async throws -> Void
    @State private var problem: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if snapshot.signedIn, snapshot.inReserve(at: context.date) {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(Usage.liftText, isOn: Binding(get: { snapshot.liftedUntil(at: context.date) != nil }, set: { on in
                        Task {
                            problem = nil
                            do { try await lift(on) } catch { problem = error.localizedDescription }
                        }
                    }))
                    Text(Usage.liftNote(snapshot)).font(.caption).foregroundStyle(.secondary)
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                }
            }
        }
    }
}
#endif
