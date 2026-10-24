import Foundation
import Testing
@testable import Oby

/// Your GitHub work on the iPhone's Review PR and Issues (the shared rules are in the Mac's
/// GitHubWorkTests): the list and its event read the same here, and only GitHub pages open.
struct GitHubWorkTests {
    @Test func readsTheListAndItsEvent() throws {
        let json = #"{"signedIn": true, "reviews": [{"id": "a", "list": "reviews", "repo": "o/r", "number": 3, "title": "t", "url": "https://github.com/o/r/pull/3", "author": "Dima", "updated": "2026-10-18T09:00:00Z", "known": true, "job": null}], "assigned": [], "mine": []}"#
        let work = try Runner.decoder.decode(GitHubWork.self, from: Data(json.utf8))
        #expect(work.waiting(.review).map(\.headline) == ["Dima asked you to review r #3."])
        var parser = EventParser()
        _ = parser.feed("event: github")
        _ = parser.feed("data: \(json)")
        #expect(parser.feed("") == .github(work))
    }

    /// Issues' To do on the iPhone: by board column, and one group when obid sends no board.
    @Test func toDoGroupsByBoardColumn() throws {
        let json = #"{"signedIn": true, "reviews": [], "mine": [], "assigned": [{"id": "a", "list": "assigned", "repo": "o/r", "number": 3, "title": "t", "url": "https://github.com/o/r/issues/3", "known": true, "job": null, "board": {"project": "Oby — Roadmap", "column": "In progress"}}, {"id": "b", "list": "assigned", "repo": "o/r", "number": 4, "title": "t", "url": "https://github.com/o/r/issues/4", "known": true, "job": null}]}"#
        let work = try Runner.decoder.decode(GitHubWork.self, from: Data(json.utf8))
        #expect(work.toDo(.issues).map(\.name) == ["In progress", nil])
        #expect(work.items[0].column == "In progress" && work.items[1].board == nil)
        #expect(WorkList.counts([WorkList.Item<String>](), toDo: 2)[.running] == 0)
    }

    /// A review in a repository obid doesn't work in: Review it on the iPhone too, asking for your Confirm first (#1118).
    @Test func anUnknownRepositoryReviewAddsItFirst() throws {
        let json = #"{"signedIn": true, "reviews": [{"id": "u", "list": "reviews", "repo": "acme/other", "number": 12, "title": "t", "url": "https://github.com/acme/other/pull/12", "known": false, "job": null}], "assigned": [], "mine": []}"#
        let review = try Runner.decoder.decode(GitHubWork.self, from: Data(json.utf8)).items[0]
        #expect(review.action == "Review it" && review.addsRepository)
        #expect(review.note == "Oby doesn't work in acme/other yet: Review it asks you to confirm adding it.")
    }

    @Test func connectAndLinks() {
        #expect(GitHubWork.Connect(GitHubWork(signedIn: false)) == .signedOut)
        #expect(GitHubWork.page("https://github.com/o/r/issues/1") != nil)
        #expect(GitHubWork.page("https://evil.example/o/r") == nil)
    }
}
