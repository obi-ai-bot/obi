import Foundation
import Testing
@testable import Oby

/// obid's accounts on the Mac (docs/mac-design.md C1): obid says whether each is signed in, and
/// its label stays null until a tool reports one (#626), so the label can't be what decides.
@MainActor
struct ObidAccountsTests {
    func status(_ accounts: String) throws -> RunnerStatus {
        let json = #"{"runner": {"version": "0.4.0", "host": "studio"}, "accounts": \#(accounts), "models": {"claude": {"model": "claude-opus-5-5", "effort": "xhigh"}, "codex": {"model": "gpt-6.1-sol", "effort": "high"}}}"#
        return try Runner.decoder.decode(RunnerStatus.self, from: Data(json.utf8))
    }

    @Test func obidsSignedInAccountWithNoLabelIsSignedIn() throws {
        let accounts = try status(#"[{"id": "personal", "agent": "claude", "name": "Personal", "label": null, "signedIn": true, "fiveHour": null, "sevenDay": null, "running": 0}]"#).accounts
        let personal = try #require(accounts.first)
        #expect(personal.signedIn)
        #expect(personal.usage.signedIn)
        #expect(Usage.notice(personal.usage) != "Signed out")
        #expect(MoveChoice.usage(signedIn: personal.signedIn, fiveHour: personal.fiveHour, sevenDay: personal.sevenDay) == "No usage yet")
    }

    @Test func obidsSignedOutAccountIsSignedOutWhateverItsLabel() throws {
        let accounts = try status(#"[{"id": "old", "agent": "codex", "name": "Old", "label": "Plus", "signedIn": false, "running": 0}]"#).accounts
        #expect(accounts.first?.signedIn == false)
        #expect(accounts.first?.usage.signedIn == false)
    }

    /// An older runner leaves `signedIn` out: then its label says, as before.
    @Test func olderRunnerFallsBackToTheLabel() throws {
        let accounts = try status(#"[{"id": "a", "agent": "claude", "name": "A", "label": "Max", "running": 0}, {"id": "b", "agent": "claude", "name": "B", "label": null, "running": 0}]"#).accounts
        #expect(accounts.map(\.signedIn) == [true, false])
    }

    /// The brain plans only onto signed-in accounts: with obid on this Mac, those are obid's.
    @Test func obidsAccountsCanTakeWork() throws {
        let accounts = try status(#"[{"id": "personal", "agent": "claude", "name": "Personal", "label": null, "signedIn": true, "running": 0}]"#).accounts
        #expect(accounts.filter(\.signedIn).map(\.account.id) == ["personal"])
    }
}

/// Sangam's usage rows on Settings › Accounts (docs/mac-design.md B2), and which accounts show (C1).
struct AccountRowsTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)
    let utc = TimeZone(identifier: "UTC")!
    let english = Locale(identifier: "en_GB")

    func snapshot(_ name: String, agent: String = "claude", week: Double?, resets: TimeInterval = 3 * 86_400, signedIn: Bool = true,
                  fiveHour: Double? = nil, running: Int = 0) -> Usage.Snapshot {
        Usage.Snapshot(agent: agent, name: name, label: nil, fiveHour: fiveHour, sevenDay: week, fiveHourResets: now + 7200,
                       sevenDayResets: now + resets, running: running, runnerSignedIn: signedIn)
    }

    @Test func mostRoomIsTheSignedInAccountWithTheMostOfItsWeekLeft() {
        let accounts = [snapshot("Personal", week: 0.82), snapshot("Deskree", agent: "codex", week: 0.12), snapshot("Old", week: 0.01, signedIn: false)]
        #expect(Usage.mostRoom(accounts, now: now) == "Most room: Deskree on Codex, 88% left this week")
        // A week past its reset is empty again.
        #expect(Usage.mostRoom([snapshot("Personal", week: 0.9, resets: -60), snapshot("Deskree", week: 0.3)], now: now)
                == "Most room: Personal on Claude Code, 100% left this week")
        #expect(Usage.mostRoom([snapshot("Personal", week: nil)], now: now) == "No usage yet: it updates after the next job.")
        #expect(Usage.mostRoom([snapshot("Personal", week: 0.2, signedIn: false)], now: now) == "No account is signed in.")
        #expect(Usage.mostRoom([], now: now) == "None yet")
    }

    @Test func rowSaysWhoPaysWhenItResetsAndHowMuchIsUsed() {
        let personal = snapshot("Personal", week: 0.36, running: 1)
        #expect(Usage.about(personal, payer: "Deskree", now: now, locale: english, timeZone: utc) == "Paid by Deskree · Resets Monday")
        // obid has no payer yet: the line starts at the reset.
        #expect(Usage.about(personal, payer: "", now: now, locale: english, timeZone: utc) == "Resets Monday")
        #expect(Usage.resetsDay(now + 4 * 3600 + 60, now: now) == "Resets in 5 h")
        #expect(Usage.usedText(personal, now: now) == "36% used")
        #expect(Usage.week(personal, now: now) == 0.36)
    }

    @Test func rowWithoutUsageSaysWhy() {
        let unknown = snapshot("Personal", week: nil)
        #expect(Usage.usedText(unknown, now: now) == nil)
        #expect(Usage.about(unknown, payer: "", now: now) == "No usage yet: it updates after its next job")
        let out = snapshot("Personal", week: 0.5, signedIn: false)
        #expect(Usage.usedText(out, now: now) == nil)
        #expect(Usage.about(out, payer: "Sam", now: now) == "Paid by Sam · Signed out")
    }

    @Test func fiveHourWindowShowsOnlyPastEightyPercent() {
        #expect(Usage.fiveHourLine(snapshot("P", week: 0.2, fiveHour: 0.8), now: now) == nil)
        #expect(Usage.fiveHourLine(snapshot("P", week: 0.2, fiveHour: 0.85), now: now) == "5-hour limit 85% used · resets in 2 h")
    }

    /// obid doesn't serve `/v1/settings/models` yet: its 404 means the Models page shows this Mac's
    /// own models, as before, with no error; any other failure is shown.
    @Test func modelsFallBackWhenTheRunnerHasNone() {
        #expect(!ModelsSettingsView.servesModels(after: RunnerError(message: "Not found", status: 404)))
        #expect(ModelsSettingsView.servesModels(after: RunnerError(message: "Bad gateway", status: 502)))
        #expect(ModelsSettingsView.servesModels(after: URLError(.timedOut)))
    }

    /// With obid on this Mac, only its accounts; with a remote runner, this Mac's and the runner's;
    /// with none, this Mac's.
    @Test func whichAccountsShow() {
        #expect(AccountPlaces.of(local: true, runner: true) == [.runner])
        #expect(AccountPlaces.of(local: false, runner: true) == [.mac, .runner])
        #expect(AccountPlaces.of(local: false, runner: false) == [.mac])
    }

    /// obid sends who pays for each account; Settings shows it.
    @Test func obidsPayerReads() throws {
        let accounts = try status(#"[{"id": "a1b2c3d4", "agent": "codex", "name": "Personal", "payer": "Wellington", "signedIn": false, "running": 0}]"#).accounts
        #expect(accounts.first?.account.payer == "Wellington")
    }

    /// The Mac opens a sign-in page obid answers only when it's https on the tool's own site, with
    /// no login or port: a runner can't send the person to a look-alike to type their code.
    @Test func onlyTheToolsOwnSignInPageOpens() throws {
        func signIn(_ url: String) -> AccountSignIn {
            AccountSignIn(account: "a1b2c3d4", url: URL(string: url)!, userCode: nil, pasteCode: true, expiresAt: nil)
        }
        #expect(signIn("https://claude.com/cai/oauth/authorize?code=true").opens(for: "claude"))
        #expect(signIn("https://auth.openai.com/codex/device").opens(for: "codex"))
        #expect(signIn("https://cursor.com/loginDeepControl?challenge=x").opens(for: "cursor"))
        #expect(!signIn("https://auth.openai.com/codex/device").opens(for: "claude"))
        #expect(!signIn("http://claude.com/cai/oauth").opens(for: "claude"))
        #expect(!signIn("https://claude.com.evil.example/x").opens(for: "claude"))
        #expect(!signIn("https://evilclaude.com/x").opens(for: "claude"))
        #expect(!signIn("https://user@claude.com/x").opens(for: "claude"))
        #expect(!signIn("https://claude.com:8443/x").opens(for: "claude"))
    }

    /// Removing one of obid's accounts says the tool's own login and the provider's account stay.
    @Test func removingSaysWhatStays() {
        let note = AccountsSettingsView.removeNote(Account(id: "a1b2c3d4", agent: "codex", name: "Personal", payer: "", home: nil))
        #expect(note.contains("Codex's own login on this Mac, and your account with OpenAI, stay as they are"))
    }
}
