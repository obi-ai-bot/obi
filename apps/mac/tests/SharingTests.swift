import Foundation
import Testing
@testable import Oby

/// Sharing a Mac in the Obysphere (#797, #808): Settings › Sharing as obid sends it and as Sangam's
/// menus have it, Stop, the teammates' Macs for "Run on another Mac", Run it here, a job's place in
/// its extras, the ask as an inbox card, and what the job card says.
@MainActor
struct SharingTests {
    static let mac = #"""
    {"settings": {"on": true, "when": ["away", "schedule"], "who": "people", "people": ["sangam"], "allowed": [], "jobsAtOnce": 1,
                  "size": "small", "work": "any", "maxMinutes": 120},
     "ready": true,
     "jobs": [{"correlationId": "c-1", "fromOwner": "sangam", "title": "Fix the login retry", "repo": "deskree-inc/tetrix-ee",
               "agent": "claude", "started": "2026-10-21T16:00:00Z", "state": "paused"}]}
    """#

    @Test func readsAndChangesThisMacsSharingAndStopsAJob() async throws {
        let obid = RunnerStub { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/obid/sharing/mac"), ("PUT", "/v1/obid/sharing/mac"): (200, Self.mac)
            case ("POST", "/v1/obid/sharing/mac/stop"): (200, #"{"stopped": 1}"#)
            default: (404, "")
            }
        }
        let mac = try #require(try await obid.runner.sharingMac())
        #expect(mac.settings.on && mac.ready)
        #expect(mac.jobs.first?.state == "paused")
        var settings = mac.settings
        settings.jobsAtOnce = 2
        _ = try await obid.runner.setSharingMac(settings)
        #expect(obid.requests.last?.json?["jobsAtOnce"] as? Int == 2)
        #expect(obid.requests.last?.json?.keys.sorted() == ["allowed", "jobsAtOnce", "maxMinutes", "on", "people", "size", "when", "who", "work"])
        try await obid.runner.stopGuests("c-1")
        #expect(obid.requests.last?.json?["job"] as? String == "c-1")
        try await obid.runner.stopGuests()
        #expect(obid.requests.last?.json?.isEmpty == true)

        let swift = RunnerStub { _ in (404, #"{"error": "Not found."}"#) }
        #expect(try await swift.runner.sharingMac() == nil)
        #expect(try await swift.runner.macs() == [])
    }

    @Test func sangamsMenusMapToObidsSettings() {
        #expect(SharingSettingsView.when(["away"]) == "away")
        #expect(SharingSettingsView.when(["schedule"]) == "nights")
        #expect(SharingSettingsView.when(["away", "schedule"]) == "both")
        #expect(SharingSettingsView.whenList("both") == ["away", "schedule"])
        #expect(SharingSettingsView.whenList("nights") == ["schedule"])
        #expect(SharingSettingsView.who("people") == "chosen")
        #expect(SharingSettingsView.whoValue("chosen") == "people")
        #expect(SharingSettingsView.whoValue("ask") == "ask")
        #expect(RunnerSharingMac.Settings.off.on == false && RunnerSharingMac.Settings.off.size == "small" && RunnerSharingMac.Settings.off.maxMinutes == 120)
        let guest = RunnerSharingMac.Guest(correlationId: "c-1", fromOwner: "sangam", title: "Fix", repo: "deskree-inc/tetrix-ee", agent: "claude",
                                           started: Date(timeIntervalSince1970: 0), state: "paused")
        #expect(SharingSettingsView.about(guest, now: Date(timeIntervalSince1970: 12 * 60)) == "Claude Code on Sangam’s account · tetrix-ee · 12 min · Paused")
        #expect(SharingSettingsView.offFooter("Deskree").hasPrefix("Let people in Deskree run jobs on this Mac"))
    }

    @Test func teammatesMacsAreFreeOrBusyAndAJobCanComeHere() async throws {
        let obid = RunnerStub { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/obid/sharing/macs"):
                (200, #"[{"obi": "obi-wellington", "owner": "wellington", "free": true, "freeAt": null, "size": "small", "agents": ["claude"]},{"obi": "obi-dima", "owner": "dima", "free": false, "freeAt": null, "size": "small", "agents": ["claude"]}]"#)
            case ("PATCH", "/v1/jobs/j1"):
                (200, #"{"id": "j1", "request": "x", "agent": "claude", "account": "stub", "repo": "o/r", "branch": "b", "kind": "build", "task": "x", "status": "interrupted", "step": "", "summary": "", "created": "2026-10-21T16:00:00Z", "runsOn": null}"#)
            default: (404, "")
            }
        }
        let macs = try await obid.runner.macs()
        #expect(macs.map(\.name) == ["Wellington’s Mac", "Dima’s Mac"])
        #expect(MessageBox.placeLine(macs[0]) == "Wellington’s Mac · Free")
        #expect(MessageBox.placeLine(macs[1]) == "Dima’s Mac · Busy")
        _ = try? await obid.runner.place("j1", on: nil)
        // Run it here sends runsOn as null, not left out.
        #expect(String(data: obid.requests.last?.body ?? Data(), encoding: .utf8) == #"{"runsOn":null}"#)
    }

    @Test func aJobsPlaceIsInItsExtrasAndOnItsLine() throws {
        let json = Data(#"{"id": "j1", "runsOn": {"obi": "obi-wellington", "owner": "wellington"}}"#.utf8)
        let extras = try Runner.decoder.decode(RunnerJobExtras.self, from: json)
        #expect(extras.runsOn?.owner == "wellington")
        #expect(try Runner.decoder.decode(RunnerJobExtras.self, from: Data(#"{"id": "j2"}"#.utf8)).runsOn == nil)
        #expect(RunnerMac.person("wellington") == "Wellington")
    }

    @Test func aTeammatesAskIsAStartItCardWithItsOwnAnswers() throws {
        let item = Data(#"""
        {"id": "obi-c-1", "kind": "obiRequest", "job": "", "title": "Sangam asks to use this Mac while you're away",
         "text": "Sangam's Oby (obi-sangam) asks to run a job on this Mac with Sangam's own Claude Code account.",
         "options": ["Allow", "Allow Sangam from now on", "Decline"], "details": ["a", "b", "c"], "recommended": null,
         "created": "2026-10-21T16:00:00Z", "done": null, "later": null, "answer": null, "state": "open",
         "obi": {"correlationId": "c-1", "type": "run_request", "quoted": {"title": "Fix", "request": "Do it"}}}
        """#.utf8)
        let read = try #require(InboxItem.runner(item))
        #expect(read.kind == .start)
        #expect(read.options == ["Allow", "Allow Sangam from now on", "Decline"])
        #expect(read.line(now: read.created).hasPrefix("Start it? · Sangam asks to use this Mac"))
        // A review request stays out of the inbox cards (Settings › Obysphere answers it).
        let review = Data(String(decoding: item, as: UTF8.self).replacingOccurrences(of: #""type": "run_request""#, with: #""type": "review_request""#).utf8)
        #expect(InboxItem.runner(review) == nil)
    }

    @Test func eachMembersKeyFingerprintShowsAndAChangedKeyWaitsForYou() {
        var member = SphereModel.Member(obi: "obi-ernesto", owner: "ernesto", name: "Ernesto's Oby", active: true, accepts: [],
                                        fingerprint: "ed25519:abc")
        #expect(SphereSettingsView.memberAbout(member) == "ernesto · key ed25519:abc")
        member.changedTo = "ed25519:xyz"
        #expect(SphereSettingsView.memberAbout(member).hasPrefix("ernesto · their key changed to ed25519:xyz. Your Oby doesn't trust them"))
    }
}
