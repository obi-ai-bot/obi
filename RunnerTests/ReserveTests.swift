import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import ObyEngine
@testable import ObyShared
@testable import oby_runner

/// "Use anyway" (#278): the user lets an account past its weekly reserve until its week resets.
/// It's then chosen for new work, the API lifts and restores it, and when only reserves keep work
/// from starting Oby says whose, and the apps offer the button only where it would help.
@MainActor
final class ReserveTests {
    let folder: URL
    /// Sunday 2026-10-11 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_791_720_000)
    /// Thursday 2026-10-15 19:00 UTC: the week's reset.
    let resets = Date(timeIntervalSince1970: 1_792_090_800)
    let london = Locale(identifier: "en_GB")
    let utc = TimeZone(identifier: "UTC")!

    init() throws {
        folder = try temporaryFolder()
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func state(_ id: String, _ agent: String = "claude", fiveHour: Double? = 0.1, sevenDay: Double?, lifted: Date? = nil) -> AccountState {
        AccountState(account: Account(id: id, agent: agent, name: id.capitalized, payer: "", home: nil), label: "Max",
                     fiveHour: fiveHour, sevenDay: sevenDay, sevenDayResets: resets, reserveLifted: lifted)
    }

    // MARK: The engine

    @Test func aLiftedAccountIsChosenForNewWorkUntilItsReset() throws {
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max", for: "default")
        accounts.record(.usage(fiveHour: 0.1, sevenDay: 0.82, sevenDayResets: resets), for: "default")
        #expect(AccountStore.route(accounts.accounts, agent: nil, now: now) == nil)

        let lifted = try #require(accounts.liftReserve("default", true, now: now))
        #expect(lifted.reserveLifted == resets && !lifted.isReserved(at: now) && lifted.inReserve(at: now))
        #expect(AccountStore.route(accounts.accounts, agent: nil, now: now)?.id == "default")
        // Failover and the Lead's picks too, and a move with no account named.
        #expect(AccountStore.next(accounts.accounts, agent: "codex", now: now)?.id == "default")
        var states = accounts.accounts
        #expect(AccountStore.pick(&states, agent: nil, now: now)?.id == "default")
        var job = Job(id: "ab12cd34", request: "", agent: "codex", account: "gone", repo: "deskree-inc/oby", branch: "oby/fix-1", kind: .fix, task: "")
        job.status = .queued
        #expect(try Moves.choose(job, to: MoveTarget(agent: "claude"), accounts: accounts.accounts, now: now).0.id == "default")

        // A restart keeps it.
        #expect(AccountStore(root: folder).state("default")?.reserveLiftedUntil(at: now) == resets)

        // The next week reaches 82% again: the lift ended with the last one.
        accounts.record(.usage(fiveHour: 0.1, sevenDay: 0.82, sevenDayResets: resets.addingTimeInterval(7 * 86_400)), for: "default")
        let nextWeek = resets.addingTimeInterval(86_400)
        #expect(accounts.state("default")?.isReserved(at: nextWeek) == true)
        #expect(AccountStore.route(accounts.accounts, agent: nil, now: nextWeek) == nil)
    }

    @Test func undoPutsTheReserveBack() throws {
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max", for: "default")
        accounts.record(.usage(fiveHour: 0.1, sevenDay: 0.82, sevenDayResets: resets), for: "default")
        accounts.liftReserve("default", true, now: now)
        let undone = try #require(accounts.liftReserve("default", false, now: now))
        #expect(undone.reserveLifted == nil && undone.isReserved(at: now))
        #expect(AccountStore.route(accounts.accounts, agent: nil, now: now) == nil)
        #expect(AccountStore(root: folder).state("default")?.reserveLifted == nil)
        #expect(accounts.liftReserve("nobody", true, now: now) == nil)
        // Without a reset time it's lifted for a week.
        let store = AccountStore(root: folder.appending(path: "other"))
        store.setLabel("Max", for: "default")
        store.record(.usage(fiveHour: 0.1, sevenDay: 0.82), for: "default")
        #expect(store.liftReserve("default", true, now: now)?.reserveLifted == now.addingTimeInterval(7 * 86_400))
    }

    @Test func liftedOrNotAnAccountAt95PercentOrFullGetsNothing() {
        let week = state("week", sevenDay: 0.96, lifted: resets)
        let hour = state("hour", fiveHour: 0.96, sevenDay: 0.85, lifted: resets)
        var full = state("full", sevenDay: 0.85, lifted: resets)
        full.fullUntil = now.addingTimeInterval(3600)
        #expect(AccountStore.route([week, hour, full], agent: nil, now: now) == nil)
        #expect(AccountStore.route([week, hour, full], agent: nil, for: .review, now: now) == nil)
        #expect(AccountStore.route([week, hour, full, state("fine", sevenDay: 0.85, lifted: resets)], agent: nil, now: now)?.id == "fine")
    }

    // MARK: The waiting line

    @Test func theWaitingLineNamesTheReservedAccounts() async {
        let personal = state("personal", sevenDay: 0.82)
        let codex = state("codex", "codex", sevenDay: 0.8)
        #expect(AccountStore.reserveWait([personal, codex], agent: nil, now: now)
                == "Personal and Codex are in their weekly reserve: use one anyway from Settings › Accounts.")
        #expect(AccountStore.reserveWait([personal, codex], agent: "codex", now: now)
                == "Codex is in its weekly reserve: use it anyway from Settings › Accounts.")
        #expect(AccountStore.reserveLine([personal, codex, state("work", sevenDay: 0.9)]) == "Personal, Codex and Work are in their weekly reserve")
        // At 95% of its week lifting it wouldn't help; with room elsewhere nothing waits.
        #expect(AccountStore.reserveWait([state("personal", sevenDay: 0.96), codex], agent: nil, now: now)
                == "Codex is in its weekly reserve: use it anyway from Settings › Accounts.")
        #expect(AccountStore.reserveWait([personal, state("work", sevenDay: 0.3)], agent: nil, now: now) == nil)
        #expect(AccountStore.reserveWait([state("personal", sevenDay: 0.97)], agent: nil, now: now) == nil)
    }

    // MARK: The runner's API

    @Test func theAPILiftsAndRestoresTheReserve() async throws {
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max", for: "default")
        // The API goes by the clock: the week resets in two days.
        let reset = Date.now.addingTimeInterval(2 * 86_400).rounded
        accounts.record(.usage(fiveHour: 0.1, sevenDay: 0.82, sevenDayResets: reset), for: "default")
        let desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let app = Application(router: API(desk: desk, devices: Devices(file: folder.appending(path: "devices.json"))).router(owner: "well@example.com"))
        let owner: HTTPFields = [.tailscaleUserLogin: "well@example.com"]
        try await app.test(.router) { client in
            func post(_ id: String, _ body: String) async throws -> (HTTPResponse.Status, [String: Any]) {
                try await client.execute(uri: "/v1/accounts/\(id)/reserve", method: .post, headers: owner, body: ByteBuffer(string: body)) { response in
                    (response.status, object(Data(response.body.readableBytesView)))
                }
            }
            func status() async throws -> [String: Any] {
                try await client.execute(uri: "/v1/status", method: .get, headers: owner) { response in
                    (object(Data(response.body.readableBytesView))["accounts"] as? [[String: Any]])?.first ?? [:]
                }
            }
            let before = try await status()
            #expect(before["reserved"] as? Bool == true && before["reserveLiftedUntil"] is NSNull)

            let (lifted, account) = try await post("default", #"{"lift": true}"#)
            #expect(lifted == .ok && account["id"] as? String == "default" && account["reserved"] as? Bool == false)
            #expect(account["reserveLiftedUntil"] as? String == reset.formatted(.iso8601))
            #expect(try await status()["reserved"] as? Bool == false)
            #expect(await AccountStore.route(desk.accounts.accounts, agent: nil)?.id == "default")

            let (restored, back) = try await post("default", #"{"lift": false}"#)
            #expect(restored == .ok && back["reserved"] as? Bool == true && back["reserveLiftedUntil"] is NSNull)
            #expect(await AccountStore.route(desk.accounts.accounts, agent: nil) == nil)

            #expect(try await post("nobody", #"{"lift": true}"#).0 == .notFound)
            #expect(try await post("default", "{}").0 == .badRequest)
        }
    }

    // MARK: The apps' button

    func card(_ name: String, fiveHour: Double? = 0.1, sevenDay: Double?, signedIn: Bool = true, lifted: Date? = nil) -> Usage.Snapshot {
        Usage.Snapshot(agent: "claude", name: name, label: signedIn ? "Max" : nil, fiveHour: fiveHour, sevenDay: sevenDay,
                       sevenDayResets: resets, reserveLiftedUntil: lifted)
    }

    @Test func theButtonShowsOnlyForReservedAccountsUnder95() {
        let personal = card("Personal", sevenDay: 0.82)
        #expect(personal.mayLift(at: now))
        #expect(Usage.useAnyway(personal) == "Use Personal anyway (82% of week)")
        #expect(Usage.liftNote(personal, locale: london, timeZone: utc)
                == "Oby keeps 20% of each week in reserve; this lifts it for Personal until Thu 19:00.")
        // Not reserved, at 95% of a window, signed out, already lifted, or past its reset: no button.
        #expect(!card("Work", sevenDay: 0.79).mayLift(at: now))
        #expect(!card("Full", sevenDay: 0.95).mayLift(at: now))
        #expect(!card("Busy", fiveHour: 0.96, sevenDay: 0.85).mayLift(at: now))
        #expect(!card("Out", sevenDay: 0.85, signedIn: false).mayLift(at: now))
        let lifted = card("Personal", sevenDay: 0.85, lifted: resets)
        #expect(!lifted.mayLift(at: now) && !lifted.reserved(at: now) && lifted.inReserve(at: now))
        #expect(!personal.mayLift(at: resets.addingTimeInterval(1)))
        // The card says it's lifted, and until when.
        #expect(Usage.spoken(lifted, now: now, locale: london, timeZone: utc).hasSuffix("Past its reserve until Thu 19:00"))
        // The engine agrees with the apps.
        #expect(state("personal", sevenDay: 0.82).mayLiftReserve(at: now) && !state("full", sevenDay: 0.95).mayLiftReserve(at: now))
        #expect(AccountState.nearlyFull == Usage.nearlyFull)
    }
}

private extension Date {
    /// To the second, as ISO 8601 keeps it.
    var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
