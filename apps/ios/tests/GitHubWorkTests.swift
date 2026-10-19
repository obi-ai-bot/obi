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

    @Test func connectAndLinks() {
        #expect(GitHubWork.Connect(GitHubWork(signedIn: false)) == .signedOut)
        #expect(GitHubWork.page("https://github.com/o/r/issues/1") != nil)
        #expect(GitHubWork.page("https://evil.example/o/r") == nil)
    }
}
