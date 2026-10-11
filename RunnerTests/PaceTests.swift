import Foundation
import Testing
@testable import ObyEngine
@testable import ObyShared

/// Routing by the weekly limit: an account ahead of pace ranks lower, and at 80% of its week it's
/// reserved for jobs the user sends to it by name. Settings' cards say so.
@MainActor
struct PaceTests {
    /// Sunday 2026-10-11 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_720_000)
    let week = 7 * 86_400.0
    let london = Locale(identifier: "en_GB")
    let utc = TimeZone(identifier: "UTC")!

    /// When the week resets with `gone` of it passed.
    func resets(_ gone: Double) -> Date { now.addingTimeInterval((1 - gone) * week) }

    func state(_ id: String, _ agent: String = "claude", fiveHour: Double? = nil, sevenDay: Double? = nil,
               gone: Double? = nil, running: Int = 0) -> AccountState {
        AccountState(account: Account(id: id, agent: agent, name: id, payer: "", home: nil), label: "Max", fiveHour: fiveHour,
                     sevenDay: sevenDay, sevenDayResets: gone.map(resets), running: running)
    }

    func route(_ states: [AccountState], _ agent: String? = "claude") -> String? {
        AccountStore.route(states, agent: agent, now: now)?.id
    }

    // MARK: Ranking

    @Test func anAccountAheadOfPaceRanksBelowOneOnPace() {
        let personal = state("personal", sevenDay: 0.62, gone: 0.3)
        #expect(abs(personal.weekGone(at: now)! - 0.3) < 1e-9)
        #expect(abs(personal.ahead(at: now) - 0.32) < 1e-9)
        // Work has used more of its week, but its week is further along.
        let work = state("work", sevenDay: 0.7, gone: 0.75)
        #expect(work.ahead(at: now) == 0)
        #expect(route([personal, work]) == "work")
        // Without the reset time there's no pace to go by: the busier window decides.
        #expect(route([state("personal", sevenDay: 0.62), work]) == "personal")
    }

    @Test func furtherAheadRanksLower() {
        // 0.62 + 0.32 against 0.5 + 0.2 against 0.45 + 0.15.
        let accounts = [state("a", sevenDay: 0.62, gone: 0.3), state("b", sevenDay: 0.5, gone: 0.3), state("c", sevenDay: 0.45, gone: 0.3)]
        #expect(route(accounts) == "c")
        #expect(route(Array(accounts.prefix(2))) == "b")
        let scores = accounts.map { AccountStore.score($0, now: now) }
        #expect(scores == scores.sorted(by: >))
    }

    @Test func theFiveHourWindowStillCounts() {
        // On pace for the week, but busy right now, against a little ahead and quiet.
        #expect(route([state("busy", fiveHour: 0.9, sevenDay: 0.2, gone: 0.5), state("quiet", fiveHour: 0.1, sevenDay: 0.4, gone: 0.3)]) == "quiet")
        #expect(route([state("full", fiveHour: 0.95, sevenDay: 0.1, gone: 0.5)]) == nil)
        // Running jobs still count too.
        #expect(route([state("a", sevenDay: 0.4, gone: 0.3, running: 2), state("b", sevenDay: 0.4, gone: 0.3)]) == "b")
    }

    // MARK: The reserve

    @Test func atEightyPercentOfTheWeekNoAutomaticWork() {
        let reserved = state("reserved", sevenDay: 0.8, gone: 0.9)
        #expect(reserved.isReserved(at: now) && !state("a", sevenDay: 0.79).isReserved(at: now) && !state("b").isReserved(at: now))
        // The engine and the cards keep the same share.
        #expect(AccountState.reserve == Usage.reserve)
        #expect(route([reserved]) == nil)
        #expect(route([state("a", sevenDay: 0.79, gone: 0.95)]) == "a")
        #expect(route([reserved, state("busy", fiveHour: 0.9, running: 3)]) == "busy")
        // Failover away from a full account doesn't land on a reserved one.
        var full = state("full")
        full.fullUntil = now.addingTimeInterval(3600)
        #expect(AccountStore.next([full, reserved, state("codex", "codex")], agent: "claude", now: now)?.id == "codex")
        #expect(AccountStore.next([full, reserved], agent: "claude", now: now) == nil)
    }

    /// Claude Code reports usage only during a job, so a reserved account's 80% wouldn't update by
    /// itself: the reserve ends when its week resets.
    @Test func theReserveEndsWhenTheWeekResets() {
        let reserved = state("reserved", sevenDay: 0.85, gone: 0.9)
        let later = now.addingTimeInterval(0.1 * week)
        #expect(!reserved.isReserved(at: later) && reserved.ahead(at: later) == 0)
        #expect(AccountStore.route([reserved], agent: "claude", now: later)?.id == "reserved")
        #expect(AccountStore.route([reserved], agent: "claude", now: later.addingTimeInterval(-1)) == nil)
        // Without a reset time it stays reserved.
        #expect(state("unknown", sevenDay: 0.85).isReserved(at: later))
    }

    @Test func reviewsDontUseAReservedAccount() {
        let author = Job(id: "author", request: "", agent: "claude", account: "mine", repo: "deskree-inc/oby",
                         branch: "oby/fix-author", kind: .fix, task: "")
        let codex = state("codex", "codex", sevenDay: 0.85, gone: 0.9)
        let personal = state("personal", sevenDay: 0.3, gone: 0.5)
        #expect(Review.reviewer([state("mine"), codex, personal], for: author)?.id == "personal")
        #expect(Review.reviewer([state("mine"), codex], for: author) == nil)
    }

    @Test func onlyAJobSentByNameGoesToAReservedAccount() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max", for: "default")
        accounts.record(.usage(fiveHour: 0.1, sevenDay: 0.85), for: "default")
        let desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        func plan(account: String) -> Planner.Result {
            let dispatch = Plan.Dispatch(agent: "claude", account: account, repo: "deskree-inc/oby", baseBranch: nil, pr: nil, issue: nil,
                                         epic: nil, kind: .fix, title: nil, task: "Fix it", inputs: [], rounds: 1, check: nil, complexity: .routine)
            return Planner.Result(plan: Plan(action: .dispatch, reply: "", dispatches: [dispatch], question: nil), by: "claude")
        }
        #expect(desk.card(for: plan(account: "auto"), said: "fix it")
                == .reply("No Claude Code account is signed in with room to spare. Check Settings › Accounts."))
        guard case .plan(let drafts) = desk.card(for: plan(account: "Default"), said: "fix it on Default") else {
            Issue.record("expected a plan")
            return
        }
        #expect(drafts.map(\.job.account) == ["default"])

        // The backup planner, when the brain fails, leaves the account to routing too.
        let context = BrainContext(accounts: ["auto": ["auto", "Default"], "claude": ["auto", "Default"]], repos: ["deskree-inc/oby"])
        let rules = Rules.plan("fix oby #12", context: context)
        #expect(rules.dispatches.map { "\($0.agent)/\($0.account)" } == ["auto/auto"] && rules.problems(in: context, canary: "7f3a9c").isEmpty)
        #expect(desk.card(for: Planner.Result(plan: rules, by: "rules"), said: "fix oby #12")
                == .reply("No coding tool account is signed in with room to spare. Check Settings › Accounts."))
        // Without "auto" on offer it names what the context has, and the plan still checks out.
        let named = BrainContext(accounts: ["claude": ["default"]], repos: ["deskree-inc/oby"])
        #expect(Rules.plan("fix oby", context: named).dispatches.map(\.account) == ["default"])
    }

    // MARK: Settings' cards

    func window(_ used: Double, gone: Double) -> Usage.Window { Usage.Window(hours: 168, used: used, resets: resets(gone)) }

    func line(_ window: Usage.Window) -> String { Usage.line(window, now: now, locale: london, timeZone: utc) }

    @Test func theWeeklyBarShowsThePace() {
        // 62% used with 30% of the week gone runs out Monday 18:53, days before Friday's reset.
        let personal = window(0.62, gone: 0.3)
        #expect(Usage.pace(personal, now: now)?.ahead == true)
        #expect(line(personal) == "62% used · 30% of the week gone · runs out Mon at this pace")
        #expect(line(window(0.9, gone: 0.8)) == "90% used · 80% of the week gone · runs out in 14 h 56 min at this pace")
        // On pace or behind it: when it resets.
        let work = window(0.4, gone: 0.5)
        #expect(Usage.pace(work, now: now)?.ahead == false && abs(Usage.pace(work, now: now)!.gone - 0.5) < 1e-9)
        #expect(line(work) == "40% used · 50% of the week gone · resets Thu 00:00")
        #expect(line(window(0.29, gone: 0.3)) == "29% used · 30% of the week gone · resets Fri 09:36")
        // The 5-hour bar, or a week without a reset time, has no pace.
        #expect(line(Usage.Window(hours: 5, used: 0.63, resets: now + 2 * 3600)) == "63% used · resets in 2 h")
        #expect(line(Usage.Window(hours: 168, used: 0.62, resets: nil)) == "62% used")
        #expect(Usage.pace(Usage.Window(hours: 5, used: 0.9, resets: now + 3600), now: now) == nil)
    }

    @Test func aReservedCardSaysSo() {
        let card = Usage.Snapshot(agent: "claude", name: "Personal", label: "Max · w@example.com", fiveHour: 0.1, sevenDay: 0.8,
                                  sevenDayResets: resets(0.9))
        #expect(card.reserved(at: now) && Usage.reservedText == "Reserved: only jobs you send it")
        #expect(!Usage.Snapshot(agent: "claude", name: "Work", label: "Max", sevenDay: 0.79).reserved(at: now))
        // Once its week resets the card stops saying so, though the 80% stays until a job reports again.
        let later = now.addingTimeInterval(0.1 * week)
        #expect(!card.reserved(at: later))
        #expect(!Usage.spoken(card, now: later, locale: london, timeZone: utc).contains("Reserved"))
        // An unknown reset time keeps it reserved.
        #expect(Usage.Snapshot(agent: "claude", name: "Work", label: "Max", sevenDay: 0.8).reserved(at: later))
        #expect(Usage.spoken(card, now: now, locale: london, timeZone: utc) == "Claude Code, Personal: 10% of the 5-hour limit used, "
                + "80% of the 7-day limit used, 90% of the week gone, resets in 16 hours 48 minutes, Reserved: only jobs you send it")
    }
}
