import Foundation
import Testing
@testable import Oby

/// Your GitHub work in Review PR and Issues (`GET /v1/github/work`): what's read, where each item
/// goes, when Connect GitHub shows, and which links open. Titles are other people's words.
struct GitHubWorkTests {
    let json = #"""
    {"signedIn": true, "login": "well-prado", "checkedAt": "2026-10-18T09:12:00Z", "nextCheck": "2026-10-18T09:15:00Z", "error": null,
     "counts": {"reviews": 1, "assigned": 140, "mine": 2},
     "reviews": [
      {"id": "a", "list": "reviews", "repo": "deskree-inc/tetrix-ee", "number": 412, "title": "retry jitter", "url": "https://github.com/deskree-inc/tetrix-ee/pull/412",
       "author": "Ernesto", "labels": [], "updated": "2026-10-18T09:00:00Z", "state": "OPEN", "draft": false, "reviewDecision": "REVIEW_REQUIRED",
       "checks": "SUCCESS", "known": true, "job": null},
      {"id": "x", "list": "someday", "repo": "o/r", "number": 1, "title": "From a newer obid", "url": "https://github.com/o/r/pull/1"}],
     "assigned": [
      {"id": "b", "list": "assigned", "repo": "deskree-inc/oby", "number": 251, "title": "Attention queue", "url": "https://github.com/deskree-inc/oby/issues/251",
       "author": null, "labels": ["area:mac"], "updated": "2026-10-18T10:00:00Z", "state": "OPEN", "draft": null, "reviewDecision": null, "checks": null,
       "known": false, "job": null}],
     "mine": [
      {"id": "c", "list": "mine", "repo": "deskree-inc/oby", "number": 700, "title": "Pair a device", "url": "https://github.com/deskree-inc/oby/pull/700",
       "author": "well-prado", "labels": [], "updated": "2026-10-18T08:00:00Z", "state": "OPEN", "draft": false, "reviewDecision": "CHANGES_REQUESTED",
       "checks": "FAILURE", "known": true, "job": null},
      {"id": "d", "list": "mine", "repo": "deskree-inc/oby", "number": 701, "title": "Started", "url": "https://github.com/deskree-inc/oby/pull/701",
       "author": "well-prado", "updated": "2026-10-18T07:00:00Z", "known": true, "job": "ab12cd34"}]}
    """#

    @Test func decodesTheListsAndSkipsWhatItCantRead() throws {
        let work = try Runner.decoder.decode(GitHubWork.self, from: Data(json.utf8))
        #expect(work.signedIn && work.login == "well-prado" && work.error == nil)
        #expect(work.checkedAt == ISO8601DateFormatter().date(from: "2026-10-18T09:12:00Z"))
        #expect(work.items.map(\.id) == ["a", "b", "c", "d"])
        #expect(work.items.map(\.list) == [.reviews, .assigned, .mine, .mine])
        #expect(work.items[1].known == false && work.items[1].author == nil)
        #expect(work.items[3].job == "ab12cd34")
        let out = try Runner.decoder.decode(GitHubWork.self, from: Data(#"{"signedIn": false, "login": null, "reviews": [], "assigned": [], "mine": []}"#.utf8))
        #expect(!out.signedIn && out.items.isEmpty)
    }

    /// To do groups an issue by its board column, newest column first, the ones on no board last;
    /// a board this app can't read, or none, falls back to one group with no name.
    @Test func toDoGroupsByBoardColumn() throws {
        func issue(_ id: String, _ board: String, _ hour: String, job: String = "null") -> String {
            #"{"id": "\#(id)", "list": "assigned", "repo": "o/r", "number": 1, "title": "t", "url": "https://github.com/o/r/issues/1", "updated": "2026-10-18T\#(hour):00:00Z", "known": true, "job": \#(job), "board": \#(board)}"#
        }
        let todo = #"{"project": "Oby — Roadmap", "column": "Todo"}"#
        let assigned = [issue("a", todo, "10"), issue("b", #"{"project": "Oby — Roadmap", "column": "In progress"}"#, "11"), issue("c", "null", "12"),
                        issue("d", todo, "09"), issue("e", #""a newer shape""#, "08"), issue("f", todo, "13", job: #""ab12cd34""#)]
        let json = #"{"signedIn": true, "reviews": [], "mine": [], "assigned": ["# + assigned.joined(separator: ", ") + "]}"
        let work = try Runner.decoder.decode(GitHubWork.self, from: Data(json.utf8))
        #expect(work.items.count == 6)
        let columns = work.toDo(.issues)
        // "f" has a job: it's listed as the job, under Running, never here too.
        #expect(columns.map(\.name) == ["In progress", "Todo", nil])
        #expect(columns.map { $0.items.map(\.id) } == [["b"], ["a", "d"], ["c", "e"]])
        #expect(work.items[0].column == "Todo" && work.items[0].board?.project == "Oby — Roadmap" && work.items[2].column == nil)
        // An older obid sends no board: one group, no name.
        let older = try Runner.decoder.decode(GitHubWork.self, from: Data(self.json.utf8))
        #expect(older.toDo(.review).map(\.name) == [nil] && older.toDo(.review)[0].items.map(\.id) == ["a", "c"])
        #expect(older.toDo(.issues, later: ["b"]).isEmpty)
    }

    @Test func groupsByKindLeavingStartedAndPutOffOnesOut() throws {
        let work = try Runner.decoder.decode(GitHubWork.self, from: Data(json.utf8))
        // Your own pull requests go under Review PR; "d" has a job on it, which is listed instead.
        #expect(work.waiting(.review).map(\.id) == ["a", "c"])
        #expect(work.waiting(.issues).map(\.id) == ["b"])
        #expect(work.waiting(.issues, later: ["b"]).isEmpty)
        #expect(work.waiting(.tasks).isEmpty)
        let review = work.items[0], issue = work.items[1], mine = work.items[2]
        #expect(review.who == "Ernesto" && review.heading == "#412 retry jitter")
        #expect(review.label == "Start it?" && review.action == "Review it" && review.note == nil)
        #expect(review.headline == "Ernesto asked you to review tetrix-ee #412.")
        // An issue in a repository obid doesn't work in: no Fix it, and why.
        #expect(issue.who == nil && issue.headline == "Assigned to you in oby #251.")
        #expect(issue.action == nil && issue.label == "On GitHub")
        #expect(issue.note == "Oby doesn't work in deskree-inc/oby yet: add it to repos in obid's configuration.")
        // Your own: where it stands, and nothing to start (obid doesn't yet).
        #expect(mine.action == nil && mine.label == "Your pull request" && mine.note == nil)
        #expect(mine.headline == "Changes requested, checks failed.")
        #expect(GitHubWork.Item(id: "f", list: .mine, repo: "o/r", number: 3, title: "t", url: "").headline == "Open in r #3.")
        #expect(GitHubWork.Item(id: "e", list: .assigned, repo: "o/r", number: 2, title: "t", url: "").action == "Fix it")
    }

    @Test func aDraftIsntReviewedYet() {
        let draft = GitHubWork.Item(id: "g", list: .reviews, repo: "o/r", number: 4, title: "t", url: "", author: "Dima", draft: true)
        #expect(draft.action == nil && draft.label == "On GitHub")
        #expect(draft.note == "It's a draft: Oby can review it once it's ready for review.")
        let json = #"{"id": "g", "list": "reviews", "repo": "o/r", "number": 4, "title": "t", "url": "https://github.com/o/r/pull/4", "draft": true}"#
        #expect((try? Runner.decoder.decode(GitHubWork.Item.self, from: Data(json.utf8)))?.draft == true)
    }

    @Test func saysWhenAListWasCutAt100() throws {
        let work = try Runner.decoder.decode(GitHubWork.self, from: Data(json.utf8))
        #expect(work.counts == [.reviews: 1, .assigned: 140, .mine: 2])
        #expect(work.cut(.issues) == ["The latest 1 of 140 issues assigned to you. The rest are on GitHub."])
        #expect(work.cut(.review).isEmpty)
        #expect(work.cut(.tasks).isEmpty)
        #expect(GitHubWork(signedIn: true).cut(.issues).isEmpty)
    }

    /// A timeout keeps what's there by then; only a runner without the feed (404) takes it away,
    /// and an answer read before the feed the app has doesn't replace it.
    @Test func keepsTheFeedThroughATimeout() async {
        let fresh = GitHubWork(signedIn: false)
        #expect(await GitHubWork.ask { fresh } == .feed(fresh))
        #expect(await GitHubWork.ask { nil } == .feed(nil))
        #expect(await GitHubWork.ask { throw RunnerError(message: "Not found", status: 404) } == .feed(nil))
        #expect(await GitHubWork.ask { throw RunnerError(message: "The runner answered 502.", status: 502) } == .keep)
        #expect(await GitHubWork.ask { throw URLError(.timedOut) } == .keep)

        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let now = GitHubWork(signedIn: true, login: "well-prado", checkedAt: t)
        let older = GitHubWork(signedIn: true, checkedAt: t - 180), newer = GitHubWork(signedIn: true, checkedAt: t + 180)
        #expect(GitHubWork.Answer.keep.applied(to: now) == now)
        #expect(GitHubWork.Answer.keep.applied(to: nil) == nil)
        #expect(GitHubWork.Answer.feed(nil).applied(to: now) == nil)
        #expect(GitHubWork.Answer.feed(older).applied(to: now) == now)
        #expect(GitHubWork.Answer.feed(newer).applied(to: now) == newer)
        #expect(GitHubWork.Answer.feed(fresh).applied(to: now) == fresh)
    }

    /// Another runner: the last one's GitHub cards and what was put off go with it.
    @MainActor @Test func anotherRunnerForgetsTheFeed() {
        let feed = RunnerFeed()
        feed.apply(GitHubWork(signedIn: true, items: [.init(id: "a", list: .reviews, repo: "o/r", number: 1, title: "t", url: "")]))
        feed.gitHubLater.insert("a")
        feed.forget()
        #expect(feed.gitHubWork == nil && feed.gitHubLater.isEmpty)
    }

    @Test func connectShowsOnlyWhileSignedOut() {
        #expect(GitHubWork.Connect(nil) == .unknown)
        #expect(GitHubWork.Connect(GitHubWork(signedIn: false)) == .signedOut)
        #expect(GitHubWork.Connect(GitHubWork(signedIn: true)) == .signedIn)
    }

    @Test func opensOnlyGitHubPages() {
        #expect(GitHubWork.page("https://github.com/deskree-inc/oby/pull/700")?.absoluteString == "https://github.com/deskree-inc/oby/pull/700")
        #expect(GitHubWork.page("https://GitHub.com/a/b/issues/1") != nil)
        for bad in ["http://github.com/a/b", "https://github.com.evil.example/a", "https://evil.example/github.com",
                    "https://user:pass@github.com/a", "https://github.com:8443/a", "javascript:alert(1)", "file:///etc/passwd",
                    "https://gist.github.com/a", ""] {
            #expect(GitHubWork.page(bad) == nil, "\(bad)")
        }
    }

    @Test func titlesArePlainOneLiners() {
        #expect(GitHubWork.plain("Fix **this**\nnow\u{2028}please\t ok") == "Fix **this** now please ok")
        #expect(GitHubWork.plain(String(repeating: "a", count: 300)).count == 200)
        let item = GitHubWork.Item(id: "x", list: .reviews, repo: "o/r", number: 1, title: "line\nbreak", url: "", author: "Eve\n[click](https://evil.example)")
        #expect(item.heading == "#1 line break")
        #expect(item.headline == "Eve [click](https://evil.example) asked you to review r #1.")
        #expect(item.page == nil)
    }

    @Test func theRunnerSaysWhenTheListChanges() {
        var parser = EventParser()
        _ = parser.feed("event: github")
        _ = parser.feed(#"data: {"signedIn": false, "reviews": [], "assigned": [], "mine": []}"#)
        #expect(parser.feed("") == .github(GitHubWork(signedIn: false)))
    }
}
