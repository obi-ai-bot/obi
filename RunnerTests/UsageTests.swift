import Foundation
import Testing
@testable import ObyEngine
@testable import ObyShared
@testable import oby_runner

/// Settings' usage cards: what they say, and where the reset times come from.
struct UsageTests {
    /// Sunday 2026-10-11 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_720_000)
    let london = Locale(identifier: "en_GB")
    let utc = TimeZone(identifier: "UTC")!

    func message(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    func snapshot(_ name: String, agent: String = "claude", label: String? = "Team · w@deskree.com", fiveHour: Double? = nil,
                  sevenDay: Double? = nil, fiveHourResets: Date? = nil, sevenDayResets: Date? = nil, running: Int = 0) -> Usage.Snapshot {
        Usage.Snapshot(agent: agent, name: name, label: label, fiveHour: fiveHour, sevenDay: sevenDay,
                       fiveHourResets: fiveHourResets, sevenDayResets: sevenDayResets, running: running)
    }

    func text(_ resets: Date, spoken: Bool = false) -> String {
        Usage.resetText(resets, now: now, spoken: spoken, locale: london, timeZone: utc)
    }

    @Test func resetTimes() {
        #expect(text(now + 2 * 3600 + 10 * 60) == "resets in 2 h 10 min")
        #expect(text(now + 2 * 3600 + 10 * 60, spoken: true) == "resets in 2 hours 10 minutes")
        #expect(text(now + 3600 + 60, spoken: true) == "resets in 1 hour 1 minute")
        #expect(text(now + 25 * 60) == "resets in 25 min")
        #expect(text(now + 2 * 3600) == "resets in 2 h")
        #expect(text(now + 30) == "resets soon")
        #expect(text(now - 3600) == "resets soon")
        // Wednesday 14:00 UTC, as the locale writes it.
        #expect(text(now + 3 * 86_400 + 2 * 3600) == "resets Wed 14:00")
        #expect(text(now + 3 * 86_400 + 2 * 3600, spoken: true) == "resets Wed 14:00")
    }

    @Test func levelsAndLines() {
        #expect(Usage.level(0.69) == .fine && Usage.level(0.7) == .warning)
        #expect(Usage.level(0.89) == .warning && Usage.level(0.9) == .critical)
        let window = Usage.Window(hours: 5, used: 0.63, resets: now + 2 * 3600 + 10 * 60)
        #expect(window.name == "5-hour" && Usage.Window(hours: 168, used: 0, resets: nil).name == "7-day")
        #expect(Usage.line(window, now: now) == "63% used · resets in 2 h 10 min")
        #expect(Usage.line(Usage.Window(hours: 168, used: 0.12, resets: nil), now: now) == "12% used")
        #expect(Usage.percent(1.4) == "100%" && Usage.percent(-0.2) == "0%")
    }

    @Test func namesAndPlans() {
        #expect(Usage.tool("claude") == "Claude Code" && Usage.tool("codex") == "Codex")
        #expect(Usage.tool("cursor") == "Cursor" && Usage.tool("gemini") == "Gemini" && Usage.tool("aider") == "Aider")
        #expect(Usage.plan("Max · well0cp@gmail.com") == "Max" && Usage.plan("Plus") == "Plus")
        #expect(Usage.plan("well0cp@gmail.com") == nil && Usage.plan(nil) == nil)
        #expect(snapshot("Deskree").title == "Deskree · Team")
        #expect(snapshot("Personal", label: "w@deskree.com").title == "Personal")
        #expect(Usage.agents(["gemini", "codex", "cursor", "claude", "codex"]) == ["claude", "codex", "cursor", "gemini"])
    }

    @Test func cardsWithoutBars() {
        #expect(Usage.notice(snapshot("Personal", label: nil)) == "Signed out")
        #expect(Usage.notice(snapshot("Work", agent: "cursor", label: "Pro")) == "Cursor doesn't report usage")
        #expect(Usage.notice(snapshot("Deskree")) == "No usage yet: it updates after its next job")
        #expect(Usage.notice(snapshot("Deskree", fiveHour: 0.1)) == nil)
        #expect(snapshot("Deskree", sevenDay: 0.4).windows == [Usage.Window(hours: 168, used: 0.4, resets: nil)])
    }

    @Test func voiceOver() {
        let codex = snapshot("Deskree", agent: "codex", label: "Team · w@deskree.com", fiveHour: 0.63, sevenDay: 0.12,
                             fiveHourResets: now + 2 * 3600, sevenDayResets: now + 3 * 86_400 + 2 * 3600, running: 1)
        // Weekday text follows the current locale, so compare up to it.
        let spoken = Usage.spoken(codex, now: now)
        #expect(spoken.hasPrefix("Codex, Deskree: 63% of the 5-hour limit used, resets in 2 hours, 12% of the 7-day limit used, resets "))
        #expect(spoken.hasSuffix(", 1 agent running"))
        #expect(Usage.spoken(snapshot("Deskree", running: 3), now: now) == "Claude Code, Deskree: No usage yet: it updates after its next job, 3 agents running")
        #expect(Usage.spoken(snapshot("Personal", label: nil), now: now) == "Claude Code, Personal: Signed out")
        #expect(Usage.runningText(1) == "1 agent running" && Usage.runningText(2) == "2 agents running")
    }

    @Test func summaryLine() {
        #expect(Usage.summary([]) == "No account is signed in.")
        #expect(Usage.summary([snapshot("Personal", label: nil)]) == "No account is signed in.")
        #expect(Usage.summary([snapshot("Deskree")]) == "No usage yet: it updates after the next job.")
        #expect(Usage.summary([snapshot("Deskree", fiveHour: 0.2, sevenDay: 0.49), snapshot("Personal", fiveHour: 0.1)]) == "All limits under 50%")
        let busy = [snapshot("Deskree", fiveHour: 0.2, sevenDay: 0.5), snapshot("Personal", agent: "codex", label: "Plus · p@example.com", fiveHour: 0.12),
                    snapshot("Old", label: nil, fiveHour: 0.01)]
        #expect(Usage.summary(busy) == "Most room: Codex, Personal · Plus (12% used)")
    }

    @Test func claudeCodeSendsResetTimes() {
        let event = message(#"{"type": "rate_limit_event", "rate_limit_info": {"unifiedWindows": {"five_hour": {"utilization": 0.33, "resetsAt": 1791593680}, "seven_day": {"utilization": 0.5, "resetsAt": 1792001242}}}}"#)
        #expect(StreamJSON.events(event) == [.usage(fiveHour: 0.33, sevenDay: 0.5, fiveHourResets: Date(timeIntervalSince1970: 1_791_593_680),
                                                    sevenDayResets: Date(timeIntervalSince1970: 1_792_001_242))])
        let bare = message(#"{"type": "rate_limit_event", "rate_limit_info": {"unifiedWindows": {"five_hour": {"utilization": 0.33}}}}"#)
        #expect(StreamJSON.events(bare) == [.usage(fiveHour: 0.33, sevenDay: nil)])
        #expect(AgentEvent.epoch(1_791_593_680_000) == Date(timeIntervalSince1970: 1_791_593_680))
        #expect(AgentEvent.epoch(0) == nil && AgentEvent.epoch("soon") == nil && AgentEvent.epoch(nil) == nil)
    }

    @Test func codexSendsResetTimes() {
        let read = message(#"{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":8,"windowDurationMins":300,"resetsAt":1791593680},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1792001242},"planType":"plus"}}"#)
        let usage = CodexRPC.usage(read["rateLimits"] as! [String: Any])
        #expect(usage == CodexRPC.Usage(fiveHour: 0.08, sevenDay: 0.4, fiveHourResets: Date(timeIntervalSince1970: 1_791_593_680),
                                        sevenDayResets: Date(timeIntervalSince1970: 1_792_001_242)))
        let update = message(#"{"method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":8,"windowDurationMins":300},"secondary":null}}}"#)
        #expect(CodexRPC.events(update) == [.usage(fiveHour: 0.08, sevenDay: nil)])
        let reserve = message(#"{"limitId":"base_model_inference","limitName":"gpt-reserve","primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1791760565},"secondary":null}"#)
        #expect(CodexRPC.usage(reserve) == nil)
    }

    @MainActor @Test func theStoreKeepsResetTimes() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AccountStore(root: folder)
        let first = Date(timeIntervalSince1970: 1_791_593_680), week = Date(timeIntervalSince1970: 1_792_001_242)
        store.record(.usage(fiveHour: 0.4, sevenDay: 0.2, fiveHourResets: first, sevenDayResets: week), for: "default")
        #expect(store.accounts[0].fiveHourResets == first && store.accounts[0].sevenDayResets == week)
        // A window reported without a reset time keeps the last one; an unreported window keeps everything.
        store.record(.usage(fiveHour: 0.5, sevenDay: nil, fiveHourResets: nil, sevenDayResets: Date()), for: "default")
        #expect(store.accounts[0].fiveHour == 0.5 && store.accounts[0].fiveHourResets == first)
        #expect(store.accounts[0].sevenDay == 0.2 && store.accounts[0].sevenDayResets == week)
        let later = first + 5 * 3600
        store.record(.usage(fiveHour: 0.01, sevenDay: 0.3, fiveHourResets: later), for: "default")
        #expect(store.accounts[0].fiveHourResets == later && store.accounts[0].sevenDayResets == week)
        store.record(.usage(fiveHour: 1, sevenDay: 1, fiveHourResets: later, sevenDayResets: later), for: "missing")
        #expect(store.accounts.count == 1)
    }

    /// The account JSON (docs/runner-api.md): reset times as ISO 8601, null when unknown.
    @MainActor @Test func accountJSONCarriesResetTimes() throws {
        var state = AccountState(account: Account(id: "default", agent: "codex", name: "Deskree", payer: "Deskree", home: nil))
        var json = object(try API.encode(AccountJSON(state: state)))
        #expect(json["fiveHourResets"] is NSNull && json["sevenDayResets"] is NSNull && json["signedIn"] as? Bool == false)
        state.label = "Team · w@deskree.com"
        state.fiveHour = 0.63
        state.fiveHourResets = Date(timeIntervalSince1970: 1_791_593_680)
        state.running = 2
        json = object(try API.encode(AccountJSON(state: state)))
        #expect(json["fiveHourResets"] as? String == "2026-10-10T00:54:40Z" && json["sevenDayResets"] is NSNull)
        #expect(json["fiveHour"] as? Double == 0.63 && json["running"] as? Int == 2 && json["agent"] as? String == "codex")
    }
}
