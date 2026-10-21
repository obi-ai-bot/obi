import Foundation
import Testing
@testable import Oby

/// obid's Slack, its watcher and its channel listener, as the Mac reads them (docs/runner-api.md,
/// "obid only: Slack", "the watcher", "the channel listener").
struct SlackTests {
    func events(_ name: String, _ json: String) -> RunnerEvent? {
        var parser = EventParser()
        for line in ["event: \(name)", "data: \(json)"] { #expect(parser.feed(line) == nil) }
        return parser.feed("")
    }

    /// The watcher's and the listener's items come as notices; Engine's kinds stay inbox items.
    @Test func watchAndListenItemsAreNotices() throws {
        let watch = #"{"id":"watch-1","kind":"watch","job":"","title":"Dmitry on Slack, in #x","text":"Dmitry wrote in #x.","options":["Dismiss"],"created":"2026-10-21T15:00:00Z","done":null,"later":null,"answer":null,"watch":{"source":"slack","url":"https://deskree.slack.com/archives/C1/p1","quoted":{"text":"[click](https://evil.example)"}}}"#
        guard case .watchNotice(let notice) = events("inbox", watch) else { Issue.record("not a notice"); return }
        #expect(notice.title == "Dmitry on Slack, in #x" && notice.options == ["Dismiss"])
        #expect(notice.url == URL(string: "https://deskree.slack.com/archives/C1/p1"))
        let listen = watch.replacingOccurrences(of: #""kind":"watch""#, with: #""kind":"listen""#)
        guard case .watchNotice(let review) = events("inbox", listen) else { Issue.record("not a notice"); return }
        #expect(review.kind == "listen")
        let question = #"{"id":"j1-question-0","kind":"question","job":"j1","title":"t","text":"Which?","options":["A","B"],"created":"2026-10-21T15:00:00Z","done":null,"later":null,"answer":null}"#
        guard case .inbox(let item, _) = events("inbox", question) else { Issue.record("not an inbox item"); return }
        #expect(item.id == "j1-question-0")
    }

    /// Only a link on slack.com or github.com over https, with nothing that ends it early, opens.
    @Test func onlySlackAndGitHubLinksOpen() {
        #expect(WatchNotice.link("https://deskree.slack.com/archives/C1/p1") != nil)
        #expect(WatchNotice.link("https://github.com/obi-ai-bot/obi/pull/835") != nil)
        for bad in ["http://deskree.slack.com/x", "https://slack.com.evil.example/x", "https://evilslack.com/x",
                    "https://deskree.slack.com/x|y", "https://user@github.com/x", "javascript:alert(1)"] {
            #expect(WatchNotice.link(bad) == nil, "\(bad)")
        }
    }

    /// A notification shows once, for an open notice from the last hour that isn't put off.
    @Test func aNotificationShowsOnceForWhatsNew() {
        let now = Date(timeIntervalSince1970: 1_792_501_200)
        let fresh = WatchNotice(id: "w1", title: "t", text: "x", created: now.addingTimeInterval(-60))
        #expect(WatchNotice.shows(fresh, told: [], now: now))
        #expect(!WatchNotice.shows(fresh, told: ["w1"], now: now), "shown already")
        var done = fresh
        done.done = now
        #expect(!WatchNotice.shows(done, told: [], now: now))
        var later = fresh
        later.later = now.addingTimeInterval(600)
        #expect(!WatchNotice.shows(later, told: [], now: now))
        let old = WatchNotice(id: "w2", title: "t", text: "x", created: now.addingTimeInterval(-7200))
        #expect(!WatchNotice.shows(old, told: [], now: now), "a replay after a reconnect")
    }

    /// `GET /v1/slack`'s whole body, and the `slack` and `watch` events.
    @Test func slackStatusReadsTheSpecsBody() throws {
        let body = #"{"connected":true,"team":"Deskree","user":"U02MX5VJKQU","bot":"U0BOT1234","socket":true,"connectedAt":"2026-10-21T14:02:11Z","error":null}"#
        let status = try Runner.decoder.decode(SlackStatus.self, from: Data(body.utf8))
        #expect(status == SlackStatus(connected: true, team: "Deskree"))
        #expect(events("slack", #"{"connected":false,"error":"Slack refused Oby's tokens: paste new ones in Settings › Connectors › Slack."}"#)
                == .slack(SlackStatus(error: "Slack refused Oby's tokens: paste new ones in Settings › Connectors › Slack.")))
        #expect(events("watch", #"{"rules":{"name":"Dmitry watcher","live":false,"enabled":true,"zone":"UTC"},"nextRun":null,"runs":[]}"#)
                == .watch(WatchStatus(rules: .init(name: "Dmitry watcher", live: false, enabled: true))))
    }

    /// The inbox's answer: the notices among Engine's items, open or not.
    @Test func noticesFromTheInboxAnswer() {
        let answer = #"[{"id":"watch-1","kind":"watch","job":"","title":"t","text":"x","options":["Dismiss"],"created":"2026-10-21T15:00:00Z","done":null,"later":null},{"id":"j1-question-0","kind":"question","job":"j1","title":"t","text":"x","options":[],"created":"2026-10-21T15:00:00Z","done":null}]"#
        #expect(WatchNotice.list(Data(answer.utf8)).map(\.id) == ["watch-1"])
    }

    /// A token is printable ASCII with no space, as obid takes it.
    @Test func tokensArePrintableASCII() {
        let user = "xoxp-" + "1111-2222-3333-7c41e09b2fd8a365"
        #expect(SlackStatus.isToken(user, "xoxp-"))
        #expect(!SlackStatus.isToken(user + "é", "xoxp-") && !SlackStatus.isToken(user + "\u{7F}", "xoxp-"))
    }
}
