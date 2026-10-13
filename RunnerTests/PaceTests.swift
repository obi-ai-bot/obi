import Foundation
import Testing
@testable import ObyEngine
@testable import ObyShared

/// Routing by the weekly limit: new work goes to accounts on pace, with the most weekly room per
/// day left; reviews to accounts ahead of it; and at 80% of its week an account is reserved for
/// jobs the user sends to it by name. Settings' cards say so.
@MainActor
struct PaceTests {
    /// Sunday 2026-10-11 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_720_000)
    let week = 7 * 86_400.0
    let london = Locale(identifier: "en_GB")
    let utc = TimeZone(identifier: "UTC")!

    /// When the week resets with `gone` of it passed.
    func resets(_ gone: Double) -> Date { now.addingTimeInterval((1 - gone) * week) }

    func state(_ id: String, _ agent: String = "claude", name: String? = nil, fiveHour: Double? = nil, sevenDay: Double? = nil,
               gone: Double? = nil, running: Int = 0) -> AccountState {
        AccountState(account: Account(id: id, agent: agent, name: name ?? id, payer: "", home: nil), label: "Max", fiveHour: fiveHour,
                     sevenDay: sevenDay, sevenDayResets: gone.map(resets), running: running)
    }

    func route(_ states: [AccountState], _ agent: String? = "claude", for work: AccountStore.Work = .new) -> String? {
        AccountStore.route(states, agent: agent, for: work, now: now)?.id
    }

    /// Every account past 80% of its week, Deskree's Claude stopped at its limit (2026-10-12): new
    /// work goes nowhere, but the brain still thinks, on the Claude account with room.
    @Test func theBrainThinksWhenEveryAccountIsInItsReserve() {
        var full = state("deskree", fiveHour: 1.02, sevenDay: 0.82, gone: 0.6)
        full.fullUntil = now.addingTimeInterval(3600)
        let accounts = [full, state("personal", fiveHour: 0.06, sevenDay: 0.83, gone: 0.6), state("codex", "codex", fiveHour: 0.27, sevenDay: 0.87, gone: 0.2)]
        #expect(route(accounts) == nil)
        #expect(AccountStore.thinker(accounts, now: now)?.id == "personal")
        // Past even a review's 95%: any Claude account that isn't stopped still answers.
        let spent = [full, state("personal", fiveHour: 0.5, sevenDay: 0.97, gone: 0.6)]
        #expect(AccountStore.thinker(spent, now: now)?.id == "personal")
        #expect(AccountStore.thinker([full], now: now) == nil)
    }

    /// The accounts on 2026-10-11 at 19:29 UTC, when "Fix it" sent two failure fixes to Codex (#176).
    var october11: [AccountState] {
        [state("codex", "codex", name: "Deskree", sevenDay: 0.33, gone: 0.076),
         state("deskree", name: "Deskree", sevenDay: 0.43, gone: 0.318, running: 4),
         state("personal", name: "Personal", sevenDay: 0.75, gone: 0.414)]
    }

    // MARK: Ranking

    @Test func theMeasuresOfPace() {
        let personal = state("personal", sevenDay: 0.62, gone: 0.3)
        #expect(abs(personal.weekGone(at: now)! - 0.3) < 1e-9)
        #expect(abs(personal.pace(at: now)! - 0.62 / 0.3) < 1e-9 && personal.isAhead(at: now))
        // 38% left with 4.9 days to go.
        #expect(abs(personal.roomPerDay(at: now)! - 0.38 / 4.9) < 1e-9)
        #expect(!state("work", sevenDay: 0.7, gone: 0.75).isAhead(at: now))
        // Unknown usage has no pace and no room; without a reset time, the whole week is left.
        #expect(state("new").pace(at: now) == nil && state("new").roomPerDay(at: now) == nil && !state("new").isAhead(at: now))
        #expect(state("a", sevenDay: 0.3).pace(at: now) == nil && abs(state("a", sevenDay: 0.3).roomPerDay(at: now)! - 0.1) < 1e-9)
        // A week about to reset counts at least a quarter of a day left.
        #expect(abs(state("a", sevenDay: 0.5, gone: 0.999).roomPerDay(at: now)! - 2) < 1e-9)
    }

    @Test func newWorkGoesToAnAccountOnPace() {
        // Work has used more of its week, but its week is further along.
        let personal = state("personal", sevenDay: 0.62, gone: 0.3)
        let work = state("work", sevenDay: 0.7, gone: 0.75)
        #expect(route([personal, work]) == "work")
        // Work on pace with little room left still beats Personal ahead of pace with more.
        #expect(route([state("personal", sevenDay: 0.35, gone: 0.3), state("work", sevenDay: 0.78, gone: 0.8)]) == "work")
        // Only when none is on pace, the most room per day left.
        #expect(route([state("a", sevenDay: 0.62, gone: 0.3), state("b", sevenDay: 0.5, gone: 0.3), state("c", sevenDay: 0.45, gone: 0.3)]) == "c")
    }

    @Test func theNumbersOfOctober11SendNewWorkToClaudeDeskree() {
        let accounts = october11
        #expect(accounts.allSatisfy { $0.isAhead(at: now) })
        // A fix job, a dispatch and the Lead's picks (any tool), even with 4 jobs running on it.
        #expect(route(accounts, nil) == "deskree")
        var states = accounts
        #expect(AccountStore.pick(&states, agent: nil, now: now)?.id == "deskree")
        #expect(AccountStore.pick(&states, agent: nil, now: now)?.id == "deskree")
        // Failover from Personal's limit.
        var full = accounts
        full[2].fullUntil = now.addingTimeInterval(3600)
        #expect(AccountStore.next(full, agent: "claude", now: now)?.id == "deskree")
        // From Claude · Deskree's, Personal (the same tool) before Codex.
        full = accounts
        full[1].fullUntil = now.addingTimeInterval(3600)
        #expect(AccountStore.next(full, agent: "claude", now: now)?.id == "personal")
        // It says why, once.
        #expect(AccountStore.choose(accounts, agent: nil, now: now)?.why
                == "On Claude Code · Deskree: most weekly room per day left (0.12/day), though 1.4× ahead of pace: none is on pace; "
                + "Codex · Deskree is 2.3× ahead of pace.")
    }

    @Test func aReviewTakesAnAccountAheadOfPace() {
        let ahead = state("ahead", sevenDay: 0.6, gone: 0.3)
        let onPace = state("onPace", sevenDay: 0.2, gone: 0.5)
        #expect(route([onPace, ahead], for: .review) == "ahead")
        #expect(route([onPace, ahead]) == "onPace")
        // Not one near its 5-hour limit, nor one reserved.
        #expect(route([onPace, state("ahead", fiveHour: 0.96, sevenDay: 0.6, gone: 0.3)], for: .review) == "onPace")
        #expect(route([onPace, state("ahead", sevenDay: 0.85, gone: 0.3)], for: .review) == "onPace")
        // The other tool still comes first.
        let author = Job(id: "author", request: "", agent: "claude", account: "mine", repo: "deskree-inc/oby",
                         branch: "oby/fix-author", kind: .fix, task: "")
        let codex = state("codex", "codex", sevenDay: 0.2, gone: 0.5)
        #expect(Review.reviewer([state("mine"), ahead, codex], for: author, now: now)?.id == "codex")
        #expect(Review.reviewer([state("mine"), onPace, ahead], for: author, now: now)?.id == "ahead")
        #expect(Review.reviewer([state("mine"), onPace, ahead], for: author, now: now)?.why.contains("so a short review suits it") == true)
    }

    @Test func theFiveHourWindowStillCounts() {
        // Similar weekly room: 85% of the 5-hour window loses to 20%.
        #expect(route([state("busy", fiveHour: 0.85, sevenDay: 0.3, gone: 0.5), state("quiet", fiveHour: 0.2, sevenDay: 0.31, gone: 0.5)]) == "quiet")
        // Even with more weekly room, or ahead of pace.
        #expect(route([state("busy", fiveHour: 0.85, sevenDay: 0.1, gone: 0.5), state("quiet", fiveHour: 0.2, sevenDay: 0.6, gone: 0.3)]) == "quiet")
        // Above 80% still takes work when every account is.
        #expect(route([state("busy", fiveHour: 0.85, sevenDay: 0.3, gone: 0.5)]) == "busy")
        #expect(route([state("full", fiveHour: 0.95, sevenDay: 0.1, gone: 0.5)]) == nil)
    }

    @Test func runningJobsOnlyBreakTies() {
        // Within 0.01/day of each other, the fewer running jobs wins.
        #expect(route([state("a", sevenDay: 0.4, gone: 0.5, running: 2), state("b", sevenDay: 0.41, gone: 0.5)]) == "b")
        // Further apart, the room decides, however many are running.
        #expect(route([state("a", sevenDay: 0.3, gone: 0.5, running: 6), state("b", sevenDay: 0.45, gone: 0.5)]) == "a")
        // All even: list order.
        #expect(route([state("a", sevenDay: 0.4, gone: 0.5), state("b", sevenDay: 0.4, gone: 0.5)]) == "a")
    }

    @Test func unknownUsageRanksAfterKnownOnPace() {
        let fresh = state("fresh")
        let onPace = state("onPace", sevenDay: 0.7, gone: 0.75)
        #expect(route([fresh, onPace]) == "onPace")
        // Before an account ahead of pace, for new work; after it, for a review.
        let ahead = state("ahead", sevenDay: 0.6, gone: 0.3)
        #expect(route([ahead, fresh]) == "fresh")
        #expect(route([fresh, ahead], for: .review) == "ahead")
        // Among unknown ones (right after a restart), the fewer running jobs, then list order.
        #expect(route([state("a", running: 1), state("b")]) == "b")
        #expect(route([state("a"), state("b")]) == "a")
        #expect(AccountStore.choose([fresh], agent: nil, now: now)?.why == "On Claude Code · fresh: its usage isn't known yet.")
    }

    @Test func theFirstHoursOfAWeekDontFlipAnAccountAhead() {
        // 5% used in the first 2% of the week counts against a seventh of it.
        let early = state("early", sevenDay: 0.05, gone: 0.02)
        #expect(!early.isAhead(at: now) && abs(early.pace(at: now)! - 0.35) < 1e-9)
        #expect(route([state("ahead", sevenDay: 0.3, gone: 0.2), early]) == "early")
        // 20% that early is ahead.
        #expect(state("burning", sevenDay: 0.2, gone: 0.02).isAhead(at: now))
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
        #expect(!reserved.isReserved(at: later) && !reserved.isAhead(at: later))
        #expect(AccountStore.route([reserved], agent: "claude", now: later)?.id == "reserved")
        #expect(AccountStore.route([reserved], agent: "claude", now: later.addingTimeInterval(-1)) == nil)
        // Without a reset time it stays reserved.
        #expect(state("unknown", sevenDay: 0.85).isReserved(at: later))
    }

    @Test func reviewsUseAReservedAccountOnlyLastAndUnder95() {
        let author = Job(id: "author", request: "", agent: "claude", account: "mine", repo: "deskree-inc/oby",
                         branch: "oby/fix-author", kind: .fix, task: "")
        let codex = state("codex", "codex", sevenDay: 0.85, gone: 0.9)
        let personal = state("personal", sevenDay: 0.3, gone: 0.5)
        // At the fixtures' time: codex's week resets at `now + 0.1 week`.
        // An account outside its reserve comes first.
        #expect(Review.reviewer([state("mine"), codex, personal], for: author, now: now)?.id == "personal")
        // When every other account is in its reserve, a review still runs on one under 95% of its week.
        #expect(Review.reviewer([state("mine"), codex], for: author, now: now)?.id == "codex")
        // At 95% of its week it doesn't, and the wait says when that week resets.
        let full = state("codex", "codex", sevenDay: 0.96, gone: 0.9)
        #expect(Review.reviewer([state("mine"), full], for: author, now: now) == nil)
        #expect(Review.roomAt([state("mine"), full], for: author, now: now).map { $0 > now } == true)
        // New work still never goes to a reserved account.
        #expect(AccountStore.choose([codex], agent: nil, for: .new, now: now) == nil)
    }

    @Test func onlyAJobSentByNameGoesToAReservedAccount() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max", for: "default")
        accounts.record(.usage(fiveHour: 0.1, sevenDay: 0.85), for: "default")
        let desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.prepare = { $0 }
        desk.makeAgent = { _, _, _ in ConversationTests.IdleAgent() }
        func plan(account: String) -> Planner.Result {
            let dispatch = Plan.Dispatch(agent: "claude", account: account, repo: "deskree-inc/oby", baseBranch: nil, pr: nil, issue: nil,
                                         epic: nil, kind: .fix, title: nil, task: "Fix it", inputs: [], rounds: 1, check: nil, complexity: .routine)
            return Planner.Result(plan: Plan(action: .dispatch, reply: "", dispatches: [dispatch], question: nil), by: "claude")
        }
        // Only its reserve keeps it from the job: it starts, waiting for room on it (#278,
        // RunnerTests/ReserveTests.swift), and the reply says so.
        guard case .reply(let held) = await desk.card(for: plan(account: "auto"), said: "fix it") else {
            Issue.record("expected a reply")
            return
        }
        #expect(held == "On it. Claude Code will fix oby on Default once what it waits for has happened. "
                + "Waiting: Default is in its weekly reserve. Use it anyway to start it now; otherwise it starts when an account has room.")
        #expect(desk.jobs.map(\.startWhen) == [[.room(agent: "claude")]] && desk.jobs.map(\.account) == ["default"])
        // Named, it starts there (#269), and the reply says so.
        #expect(await desk.card(for: plan(account: "Default"), said: "fix it on Default") == .reply("On it. Claude Code is fixing oby on Default."))
        #expect(desk.jobs.map(\.account) == ["default", "default"] && desk.jobs.first?.startWhen == nil)

        // The backup planner, when the brain fails, leaves the account to routing too.
        let context = BrainContext(accounts: ["auto": ["auto", "Default"], "claude": ["auto", "Default"]], repos: ["deskree-inc/oby"])
        let rules = Rules.plan("fix oby #12", context: context)
        #expect(rules.dispatches.map { "\($0.agent)/\($0.account)" } == ["auto/auto"] && rules.problems(in: context, canary: "7f3a9c").isEmpty)
        // A guess starts nothing (#269): the job it proposes in the inbox waits for room the same way.
        _ = await desk.card(for: Planner.Result(plan: rules, by: "rules"), said: "fix oby #12")
        #expect(desk.inbox.compactMap(\.proposed).map(\.startWhen) == [[.room(agent: nil)]])
        // At 95% of its week lifting its reserve wouldn't help: no account has room, and nothing waits.
        accounts.record(.usage(fiveHour: 0.1, sevenDay: 0.96), for: "default")
        #expect(await desk.card(for: plan(account: "auto"), said: "fix it")
                == .reply("No Claude Code account is signed in with room to spare. Check Settings › Accounts."))
        #expect(await desk.card(for: Planner.Result(plan: rules, by: "rules"), said: "fix oby #12")
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
