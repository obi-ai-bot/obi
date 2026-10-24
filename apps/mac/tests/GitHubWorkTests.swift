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

    /// To do groups an issue by project and board column in a fixed order (In progress, In review,
    /// Todo, Backlog, the rest by name, no board last), whenever each was updated; a board this app
    /// can't read, or none, falls back to one group with no name, and one bad field drops only itself.
    @Test func toDoGroupsByBoardColumn() throws {
        func issue(_ id: String, _ board: String, _ hour: String, job: String = "null") -> String {
            #"{"id": "\#(id)", "list": "assigned", "repo": "o/r", "number": 1, "title": "t", "url": "https://github.com/o/r/issues/1", "updated": "2026-10-18T\#(hour):00:00Z", "known": true, "job": \#(job), "board": \#(board)}"#
        }
        func on(_ column: String, _ project: String = "Oby — Roadmap") -> String { #"{"project": "\#(project)", "column": "\#(column)"}"# }
        let assigned = [issue("a", on("Todo"), "13"), issue("b", on("In progress"), "08"), issue("c", "null", "14"),
                        issue("d", on("Todo"), "09"), issue("e", #""a newer shape""#, "15"), issue("f", on("Todo"), "16", job: #""ab12cd34""#),
                        issue("g", on("Backlog"), "17"), issue("h", on("Blocked"), "18"), issue("i", on("In review"), "07"),
                        issue("j", on("Todo", "Tetrix"), "12"), issue("k", #"{"project": 7, "column": "Archive"}"#, "11")]
        let json = #"{"signedIn": true, "reviews": [], "mine": [], "assigned": ["# + assigned.joined(separator: ", ") + "]}"
        let work = try Runner.decoder.decode(GitHubWork.self, from: Data(json.utf8))
        #expect(work.items.count == 11)
        let columns = work.toDo(.issues)
        // "f" has a job: it's listed as the job, under Running, never here too. "j"'s Todo is
        // another project's; "k"'s project can't be read, but its column still is.
        #expect(columns.map(\.name) == ["In progress", "In review", "Todo", "Todo", "Backlog", "Archive", "Blocked", nil])
        #expect(columns.map(\.project) == ["Oby — Roadmap", "Oby — Roadmap", "Oby — Roadmap", "Tetrix", "Oby — Roadmap", nil, "Oby — Roadmap", nil])
        #expect(columns.map { $0.items.map(\.id) } == [["b"], ["i"], ["a", "d"], ["j"], ["g"], ["k"], ["h"], ["e", "c"]])
        #expect(work.items[0].column == "Todo" && work.items[0].board?.project == "Oby — Roadmap" && work.items[2].column == nil)
        // An older obid sends no board: one group, no name.
        let older = try Runner.decoder.decode(GitHubWork.self, from: Data(self.json.utf8))
        #expect(older.toDo(.review).map(\.name) == [nil] && older.toDo(.review)[0].items.map(\.id) == ["a", "c"])
        #expect(older.toDo(.issues, later: ["b"]).isEmpty)
    }

    /// A tap keeps one project, another tap adds one, and the last tap on brings every project back.
    /// A saved name that is no longer on the list shows everything.
    @Test func projectFilterKeepsTheOnesPicked() {
        let columns = [
            GitHubWork.Column(name: "Todo", project: "Oby Gap Map", items: []),
            GitHubWork.Column(name: "Todo", project: "Paga.eu Backend", items: []),
            GitHubWork.Column(name: nil, project: nil, items: []),
        ]
        let names = GitHubWork.projectNames(columns)
        #expect(names == ["Oby Gap Map", "Paga.eu Backend", GitHubWork.offBoard])
        var picked: Set<String> = []
        GitHubWork.toggle("Oby Gap Map", picked: &picked, among: names)
        #expect(picked == ["Oby Gap Map"])
        #expect(GitHubWork.columns(columns, picked: picked).map(\.project) == ["Oby Gap Map"])
        GitHubWork.toggle(GitHubWork.offBoard, picked: &picked, among: names)
        #expect(picked == ["Oby Gap Map", GitHubWork.offBoard])
        #expect(GitHubWork.columns(columns, picked: picked).map { $0.project ?? GitHubWork.offBoard } == ["Oby Gap Map", GitHubWork.offBoard])
        GitHubWork.toggle("Oby Gap Map", picked: &picked, among: names)
        GitHubWork.toggle(GitHubWork.offBoard, picked: &picked, among: names)
        #expect(picked.isEmpty)
        #expect(GitHubWork.columns(columns, picked: ["gone"]).count == 3)
        #expect(GitHubWork.projectSet(GitHubWork.projectRaw(["b", "a"])) == ["a", "b"])
        let oby = GitHubWork.Item(id: "a", list: .assigned, repo: "obi-ai-bot/obi", number: 60, title: "t", url: "", milestone: "F17 · Secrets")
        let blok = GitHubWork.Item(id: "b", list: .assigned, repo: "deskree-inc/blok", number: 61, title: "t", url: "", milestone: "M1")
        let filled = [GitHubWork.Column(name: nil, project: nil, items: [oby, blok])]
        #expect(GitHubWork.repoNames(filled) == ["obi-ai-bot/obi", "deskree-inc/blok"])
        #expect(GitHubWork.milestoneNames(filled) == ["F17 · Secrets", "M1"])
        #expect(GitHubWork.columns(filled, picked: [], repos: ["obi-ai-bot/obi"]).flatMap { $0.items.map(\.id) } == ["a"])
        #expect(GitHubWork.columns(filled, picked: [], milestones: ["M1"]).flatMap { $0.items.map(\.id) } == ["b"])
        #expect(GitHubWork.filterLabel("Repositories", raw: "", among: GitHubWork.repoNames(filled)) == "Repositories")
        #expect(GitHubWork.matching(["obi-ai-bot/obi", "deskree-inc/blok"], "blok") == ["deskree-inc/blok"])
        #expect(GitHubWork.matching(["obi-ai-bot/obi"], "  ") == ["obi-ai-bot/obi"])
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
        // Your own, its checks failed: Fix it, its headline where it stands.
        #expect(mine.action == "Fix it" && mine.label == "Start it?" && mine.note == nil)
        #expect(mine.headline == "Changes requested, checks failed.")
        #expect(GitHubWork.Item(id: "f", list: .mine, repo: "o/r", number: 3, title: "t", url: "").headline == "Open in r #3.")
        #expect(GitHubWork.Item(id: "e", list: .assigned, repo: "o/r", number: 2, title: "t", url: "").action == "Fix it")
    }

    /// A review in a repository obid doesn't work in: Review it, which asks for your Confirm first (#1118).
    @Test func anUnknownRepositoryReviewAddsItFirst() {
        let review = GitHubWork.Item(id: "u", list: .reviews, repo: "acme/other", number: 12, title: "t", url: "", author: "Dima", known: false)
        #expect(review.action == "Review it" && review.label == "Start it?" && review.addsRepository)
        #expect(review.note == "Oby doesn't work in acme/other yet: Review it asks you to confirm adding it.")
        let known = GitHubWork.Item(id: "k", list: .reviews, repo: "o/r", number: 1, title: "t", url: "")
        #expect(!known.addsRepository && known.note == nil)
        let issue = GitHubWork.Item(id: "i", list: .assigned, repo: "acme/other", number: 13, title: "t", url: "", known: false)
        #expect(issue.action == nil && !issue.addsRepository)
    }

    /// Your own pull request offers Fix it only when its checks failed, on a branch of the repository
    /// itself (#1119).
    @Test func yourRedPullRequestOffersFixIt() throws {
        func mine(_ checks: String?, fork: Bool = false, known: Bool = true) -> GitHubWork.Item {
            GitHubWork.Item(id: "m", list: .mine, repo: "o/r", number: 5, title: "t", url: "", checks: checks, fork: fork, known: known)
        }
        #expect(mine("FAILURE").action == "Fix it" && mine("ERROR").action == "Fix it")
        #expect(mine("SUCCESS").action == nil && mine("PENDING").action == nil && mine(nil).action == nil)
        #expect(mine("FAILURE", fork: true).action == nil && mine("FAILURE", known: false).action == nil)
        #expect(mine("SUCCESS").label == "Your pull request" && !mine("FAILURE").addsRepository)
        let json = #"{"id": "m", "list": "mine", "repo": "o/r", "number": 5, "title": "t", "url": "https://github.com/o/r/pull/5", "checks": "FAILURE", "fork": true, "head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
        #expect(try Runner.decoder.decode(GitHubWork.Item.self, from: Data(json.utf8)).fork)
        // Its inbox offer notifies the Mac (it needs you); its card is the item's, not the conversation's.
        let offer = #"{"id": "github-ci-m-aaaaaaaaaaaa", "kind": "github", "title": "CI failed: r #5", "text": "Checks failed on your pull request #5 in o/r.", "options": ["Fix CI", "Dismiss"], "created": "2026-10-23T10:00:00Z", "triage": "needs_you"}"#
        let notice = try Runner.decoder.decode(WatchNotice.self, from: Data(offer.utf8))
        #expect(WatchNotice.kinds.contains(notice.kind) && !notice.carded && notice.needsYou)
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

    /// Sangam's GitHub card (#822): Fix it or Review it filled first, then Open on GitHub, and no line
    /// under them saying what each does, where a decision with a recommended choice has one.
    @Test func gitHubCardsSayNothingUnderTheirChoices() {
        let work = GitHubWork.busy()
        for item in [work.items[0], work.items[9]] {
            let options = GitHubCard.options(item)
            #expect(options.map(\.label) == [item.list == .reviews ? "Review it" : "Fix it", "Open on GitHub"])
            #expect(options[0].recommended)
            #expect(AskCard.explained(options, explains: GitHubCard.explains).isEmpty)
        }
        #expect(!AskCard.explained([CardOption(label: "Allow once", answer: "allow", recommended: true)], explains: true).isEmpty)
    }
}
