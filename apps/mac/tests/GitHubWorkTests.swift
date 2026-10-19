import Foundation
import Testing
@testable import Oby

/// Your GitHub work in Review PR and Issues (`GET /v1/github/work`): what's read, where each item
/// goes, when Connect GitHub shows, and which links open. Titles are other people's words.
struct GitHubWorkTests {
    let json = #"""
    {"signedIn": true, "login": "well-prado", "checkedAt": "2026-10-18T09:12:00Z", "nextCheck": "2026-10-18T09:15:00Z", "error": null,
     "counts": {"reviews": 2, "assigned": 1, "mine": 1},
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
        #expect(work.items.map(\.id) == ["a", "b", "c", "d"])
        #expect(work.items.map(\.list) == [.reviews, .assigned, .mine, .mine])
        #expect(work.items[1].known == false && work.items[1].author == nil)
        #expect(work.items[3].job == "ab12cd34")
        let out = try Runner.decoder.decode(GitHubWork.self, from: Data(#"{"signedIn": false, "login": null, "reviews": [], "assigned": [], "mine": []}"#.utf8))
        #expect(!out.signedIn && out.items.isEmpty)
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

    @Test func connectShowsOnlyWhileSignedOut() {
        #expect(GitHubWork.Connect(nil) == .unknown)
        #expect(GitHubWork.Connect(GitHubWork(signedIn: false)) == .signedOut)
        #expect(GitHubWork.Connect(GitHubWork(signedIn: true)) == .signedIn)
    }

    @Test func chipsShowReviewAndIssuesWithWhatWaits() {
        let tasks = WorkList.Group<Int>(id: "tasks", type: .tasks, label: "Tasks", items: [], count: 2, countLabel: "open", needs: 0, fresh: false)
        let review = WorkList.Group<Int>(id: "review", type: .review, label: "Review PR", items: [], count: 1, countLabel: "open", needs: 0, fresh: false)
        // Nothing on GitHub, signed in: the chips stay as they were.
        #expect(GitHubWork.chips([tasks], waiting: { _ in 0 }, connect: .signedIn).map(\.label) == ["Tasks"])
        // Signed out: Review PR and Issues show, so Connect GitHub can be found.
        #expect(GitHubWork.chips([tasks], waiting: { _ in 0 }, connect: .signedOut).map(\.label) == ["Review PR", "Issues", "Tasks"])
        // What waits on GitHub adds to a kind's count, in Home's order.
        let chips = GitHubWork.chips([tasks, review], waiting: { $0 == .review ? 2 : 0 }, connect: .signedIn)
        #expect(chips.map(\.label) == ["Review PR", "Tasks"])
        #expect(chips.map(\.count) == [3, 2])
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
