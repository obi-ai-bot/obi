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
