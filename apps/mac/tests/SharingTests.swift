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
        #expect(SharingSettingsView.weekLine(.init(jobs: 3, wallSeconds: 7800, costCents: 0)) == "This week: 3 jobs, 2 h 10 min.")
        #expect(SharingSettingsView.weekLine(.init(jobs: 1, wallSeconds: 600, costCents: 0)) == "This week: 1 job, 10 min.")
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

    // MARK: Sharing your usage (#809)

    static let grants = #"""
    {"grants": [{"id": "g-0123456789ab", "agent": "claude", "label": "Deskree API", "account": "deskree", "who": "sangam", "share": 30, "extra": 0,
                 "budgetCents": 40000, "resetsDay": 1, "resets": "2026-11-01T00:00:00Z", "limitCents": 12000,
                 "usedCents": {"sangam": 3600, "wellington": 9000}, "created": "2026-10-21T16:00:00Z"}],
     "accounts": [{"id": "deskree", "agent": "claude", "name": "Deskree API", "plan": "api", "why": null},
                  {"id": "personal", "agent": "claude", "name": "Personal", "plan": "personal", "why": "A personal plan is for you alone."}],
     "key": true}
    """#

    @Test func sharesOfAnAPIAccountAreReadAndSetAndKeptAccountsSayWhy() async throws {
        let obid = RunnerStub { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/obid/sharing/grants"): (200, Self.grants)
            case ("PUT", "/v1/obid/sharing/grants"):
                (200, #"{"id": "g-0123456789ab", "label": "Deskree API", "account": "deskree", "who": "everyone", "share": 50, "extra": 0, "budgetCents": 40000, "resetsDay": 1, "resets": "2026-11-01T00:00:00Z", "limitCents": 20000, "usedCents": {}}"#)
            case ("GET", "/v1/obid/sharing/shared"):
                (200, #"{"shares": [{"grant": "g-0123456789ab", "from": "obi-wellington", "owner": "wellington", "agent": "claude", "account": "Deskree API", "share": 30, "limitCents": 12000, "usedCents": 4800, "resets": "2026-11-01T00:00:00Z"}], "takesShares": true}"#)
            default: (404, "")
            }
        }
        let grants = try #require(try await obid.runner.sharingGrants())
        #expect(grants.key && grants.accounts.filter { $0.why == nil }.map(\.name) == ["Deskree API"])
        let grant = try #require(grants.grants.first)
        // 9% of the month is Sangam's ($36 of $400); Wellington's own jobs count apart.
        #expect(SharingSettingsView.usedPercent(grant) == 9)
        #expect(SharingSettingsView.usageAbout(grant, key: true, macOn: true) == "Sangam used 9% of 30% this month")
        #expect(SharingSettingsView.usageAbout(nil, key: true, macOn: true) == "Not shared")
        #expect(SharingSettingsView.whoOptions(members: [], who: "sangam").map(\.1) == ["Nobody", "Everyone", "Sangam"])
        #expect(SharingSettingsView.usageAbout(grant, key: false, macOn: false).hasSuffix("share this Mac too"))
        _ = try await obid.runner.setGrant(account: "deskree", who: "everyone", share: 50, budgetCents: 40000)
        #expect(obid.requests.last?.json?.keys.sorted() == ["account", "budgetCents", "resetsDay", "share", "who"])
        let shared = try #require(try await obid.runner.sharedWithMe())
        let share = try #require(shared.shares.first)
        #expect(share.name == "Wellington’s Deskree API" && share.left == 18)

        let swift = RunnerStub { _ in (404, #"{"error": "Not found."}"#) }
        #expect(try await swift.runner.sharingGrants() == nil)
        #expect(try await swift.runner.sharedWithMe() == nil)
    }

    @Test func aFullAccountOffersATeammatesShareAndAJobGoesOnIt() async throws {
        let share = RunnerShares.Share(grant: "g-0123456789ab", from: "obi-wellington", owner: "wellington", agent: "claude", account: "Deskree API",
                                       share: 30, limitCents: 12000, usedCents: 4800, resets: .now)
        #expect(TaskDecision.useShareLabel(share) == "Use Wellington’s share")
        #expect(TaskDecision.shareLine(share) == "Wellington shares 30% of Deskree API’s month with you, and 18% is left. It would run on Wellington’s Mac, on that account, and you get the pull request.")
        let obid = RunnerStub { request in
            (200, #"{"id": "j1", "request": "x", "agent": "claude", "account": "stub", "repo": "o/r", "branch": "b", "kind": "build", "task": "x", "status": "interrupted", "step": "", "summary": "", "created": "2026-10-21T16:00:00Z"}"#)
        }
        _ = try? await obid.runner.place("j1", on: "obi-wellington", grant: "g-0123456789ab")
        #expect(String(data: obid.requests.last?.body ?? Data(), encoding: .utf8) == #"{"runsOn":{"grant":"g-0123456789ab","obi":"obi-wellington"}}"# ||
                String(data: obid.requests.last?.body ?? Data(), encoding: .utf8) == #"{"runsOn":{"obi":"obi-wellington","grant":"g-0123456789ab"}}"#)
        _ = try? await obid.runner.place("j1", on: "obi-wellington")
        #expect(String(data: obid.requests.last?.body ?? Data(), encoding: .utf8) == #"{"runsOn":"obi-wellington"}"#)
    }

    @Test func aUsedShareIsAnOutOfUsageCardWithItsOwnAnswers() throws {
        let item = Data(#"""
        {"id": "share-used-g-1-sangam-0", "kind": "obiRequest", "job": "", "title": "Sangam used the share of Deskree API",
         "text": "All 30% of this month’s share is used ($120 of $400).", "options": ["Share 20% more this month", "Leave it"],
         "details": null, "recommended": 1, "created": "2026-10-21T16:00:00Z", "done": null, "later": null, "answer": null,
         "obi": {"type": "share_used", "grant": "g-1", "fromOwner": "sangam"}}
        """#.utf8)
        let read = try #require(InboxItem.runner(item))
        #expect(read.kind == .limit)
        #expect(read.options == ["Share 20% more this month", "Leave it"])
        #expect(read.line(now: read.created).hasPrefix("Out of usage · Sangam used the share of Deskree API"))
    }
}
