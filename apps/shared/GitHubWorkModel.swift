import Foundation

/// Your work on GitHub as obid finds it with its gh (docs/runner-api.md, "obid only: GitHub work"):
/// the pull requests waiting for your review, the issues assigned to you and your own open pull
/// requests, the first two with one tap that starts Oby's job on them. Titles come from other
/// people: plain text only, and only `https://github.com/…` links open.
nonisolated struct GitHubWork: Decodable, Equatable, Sendable {
    /// Whether obid's gh is installed and signed in to GitHub; signed out, the lists are empty and
    /// Connect GitHub shows.
    var signedIn: Bool
    /// Who gh is signed in as.
    var login: String?
    /// `reviews`, then `assigned`, then `mine`, each newest update first, as obid lists them.
    var items: [Item]
    /// Why the last read of GitHub failed (a rate limit, no network), said under the list; the
    /// lists stay as the last read that worked.
    var error: String?
    /// The last read of GitHub that worked, as obid says: an answer read earlier never replaces it.
    var checkedAt: Date?
    /// How many GitHub found in each list: obid lists at most 100, so more than it listed means a cut list.
    var counts: [Item.List: Int] = [:]

    nonisolated struct Item: Decodable, Identifiable, Equatable, Sendable {
        enum List: String, Decodable, Sendable {
            /// Pull requests waiting for your review.
            case reviews
            /// Issues assigned to you.
            case assigned
            /// Your own open pull requests.
            case mine
        }
        /// obid's own, the same for the same repository and number on every read.
        var id: String
        var list: List
        /// `owner/name`.
        var repo: String
        var number: Int
        var title: String
        var url: String
        /// Who opened it.
        var author: String?
        var updated: Date?
        /// On pull requests: whether it's still a draft.
        var draft: Bool = false
        /// On pull requests: `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or nil.
        var reviewDecision: String?
        /// On pull requests: the head commit's checks, `SUCCESS`, `FAILURE`, `ERROR`, `PENDING`, `EXPECTED`, or nil.
        var checks: String?
        /// Whether obid works in its repository, so work on it can start.
        var known: Bool = true
        /// The queued or running job on it: the job is listed instead.
        var job: String?
        /// Where it sits on a GitHub project board, when it's on one (a newer obid's; older ones leave it out).
        var board: Board?

        nonisolated struct Board: Decodable, Equatable, Sendable {
            /// The project's name, "Oby — Roadmap".
            var project: String?
            /// Its column there, "Todo" or "In progress".
            var column: String?

            private enum Keys: String, CodingKey { case project, column }

            init(project: String? = nil, column: String? = nil) { (self.project, self.column) = (project, column) }

            /// Each field on its own: one this app can't read is left out, not the whole board.
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                project = (try? c.decodeIfPresent(String.self, forKey: .project)) ?? nil
                column = (try? c.decodeIfPresent(String.self, forKey: .column)) ?? nil
            }
        }

        private enum Keys: String, CodingKey { case id, list, repo, number, title, url, author, updated, draft, reviewDecision, checks, known, job, board }

        init(id: String, list: List, repo: String, number: Int, title: String, url: String, author: String? = nil, updated: Date? = nil,
             draft: Bool = false, reviewDecision: String? = nil, checks: String? = nil, known: Bool = true, job: String? = nil, board: Board? = nil) {
            (self.id, self.list, self.repo, self.number, self.title, self.url, self.author, self.updated) = (id, list, repo, number, title, url, author, updated)
            self.draft = draft
            (self.reviewDecision, self.checks, self.known, self.job, self.board) = (reviewDecision, checks, known, job, board)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decode(String.self, forKey: .id)
            list = try c.decode(List.self, forKey: .list)
            repo = try c.decode(String.self, forKey: .repo)
            number = try c.decode(Int.self, forKey: .number)
            title = try c.decode(String.self, forKey: .title)
            url = try c.decode(String.self, forKey: .url)
            author = try c.decodeIfPresent(String.self, forKey: .author)
            updated = try? c.decodeIfPresent(Date.self, forKey: .updated)
            draft = (try? c.decodeIfPresent(Bool.self, forKey: .draft)) ?? false
            reviewDecision = try c.decodeIfPresent(String.self, forKey: .reviewDecision)
            checks = try c.decodeIfPresent(String.self, forKey: .checks)
            known = try c.decodeIfPresent(Bool.self, forKey: .known) ?? true
            job = try c.decodeIfPresent(String.self, forKey: .job)
            // A board this app can't read is no board: the item still shows, under To do.
            board = (try? c.decodeIfPresent(Board.self, forKey: .board)) ?? nil
        }
    }

    /// The items obid listed, less any this app can't read (a newer obid's).
    private enum Keys: String, CodingKey { case signedIn, login, error, checkedAt, counts, reviews, assigned, mine }
    private struct Counts: Decodable { var reviews, assigned, mine: Int? }
    private struct Lossy: Decodable {
        var item: Item?
        init(from decoder: Decoder) throws { item = try? Item(from: decoder) }
    }

    init(signedIn: Bool, login: String? = nil, items: [Item] = [], error: String? = nil, counts: [Item.List: Int] = [:], checkedAt: Date? = nil) {
        self.checkedAt = checkedAt
        self.signedIn = signedIn
        self.login = login
        self.items = items
        self.error = error
        self.counts = counts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        signedIn = try c.decode(Bool.self, forKey: .signedIn)
        login = try c.decodeIfPresent(String.self, forKey: .login)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        checkedAt = try? c.decodeIfPresent(Date.self, forKey: .checkedAt)
        if let found = try? c.decodeIfPresent(Counts.self, forKey: .counts) {
            counts = [.reviews: found.reviews, .assigned: found.assigned, .mine: found.mine].compactMapValues { $0 }
        }
        items = try [Keys.reviews, .assigned, .mine].flatMap { (try c.decodeIfPresent([Lossy].self, forKey: $0) ?? []).compactMap(\.item) }
    }
}

extension GitHubWork.Item {
    /// The kind of work it goes under on Home: a review under Review PR (your own pull requests
    /// too: not in Sangam's design, which has no group for them), an issue under Issues.
    var type: WorkType { list == .assigned ? .issues : .review }

    /// "tetrix-ee", as Sangam's cards name a repository.
    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    /// Who it's for, before the title (Sangam's `who`): a review's author.
    var who: String? { list == .reviews ? author.map(GitHubWork.plain) : nil }

    /// "#412 retry jitter", as Sangam's cards title them.
    var heading: String { "#\(number) \(GitHubWork.plain(title))" }

    /// The decision's headline, in Sangam's words for a review's request ("Ernesto asked you to
    /// review tetrix-ee #412.").
    var headline: String {
        switch list {
        case .reviews: "\(author.map(GitHubWork.plain) ?? "Someone") asked you to review \(repoName) #\(number)."
        case .assigned: "Assigned to you in \(repoName) #\(number)."
        case .mine: state ?? "Open in \(repoName) #\(number)."
        }
    }

    /// The one tap that starts Oby's job on it, or nil where Oby can't start one: your own pull
    /// requests (obid doesn't yet), and repositories obid doesn't work in.
    var action: String? {
        guard known, !draft else { return nil }
        switch list {
        case .reviews: return "Review it"
        case .assigned: return "Fix it"
        case .mine: return nil
        }
    }

    /// The card's label over the headline: Sangam's "Start it?" when it can start, else where it is.
    var label: String { action == nil ? (list == .mine ? "Your pull request" : "On GitHub") : "Start it?" }

    /// Where your own pull request stands: "Changes requested, checks failed."
    var state: String? {
        let review: String? = switch reviewDecision {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        case "REVIEW_REQUIRED": "Waiting for review"
        default: nil
        }
        let checks: String? = switch self.checks {
        case "SUCCESS": "checks passed"
        case "FAILURE", "ERROR": "checks failed"
        case "PENDING", "EXPECTED": "checks running"
        default: nil
        }
        let line = [review, checks].compactMap { $0 }.joined(separator: ", ")
        return line.isEmpty ? nil : line.prefix(1).uppercased() + line.dropFirst() + "."
    }

    /// Under the headline: why Oby can't start on it, when it can't.
    var note: String? {
        if list == .mine { return nil }
        if !known { return "Oby doesn't work in \(repo) yet: add it to repos in obid's configuration." }
        return draft ? "It's a draft: Oby can review it once it's ready for review." : nil
    }

    /// Its board column as one plain line ("Todo"), the small label on its card; nil off a board.
    var column: String? { board?.column.map(GitHubWork.plain).flatMap { $0.isEmpty ? nil : $0 } }

    /// Its page on GitHub, only when it's one (`GitHubWork.page`).
    var page: URL? { GitHubWork.page(url) }
}

extension GitHubWork {
    /// What Review PR and Issues say about GitHub: Connect GitHub while gh is signed out, its items
    /// once it's signed in, nothing from a runner that doesn't list GitHub work (`nil`).
    enum Connect: Equatable, Sendable {
        case unknown, signedOut, signedIn
        init(_ work: GitHubWork?) { self = work.map { $0.signedIn ? .signedIn : .signedOut } ?? .unknown }
    }

    /// What obid's answer (`ask`) does to the feed.
    enum Answer: Equatable, Sendable {
        /// Its feed, or nil from a runner without one (a 404).
        case feed(GitHubWork?)
        /// No answer (a timeout, a dropped connection, a 5xx): the feed the app has by then stays.
        case keep

        /// The feed once this answer lands on `current`, the one the app has now (not the one it
        /// had when it asked): an answer read before it (an older `checkedAt`) doesn't replace it.
        func applied(to current: GitHubWork?) -> GitHubWork? {
            guard case .feed(let work) = self else { return current }
            if let read = work?.checkedAt, let now = current?.checkedAt, read < now { return current }
            return work
        }
    }

    /// Asks obid for the feed; the caller applies the answer only if it still follows the same runner.
    static func ask(_ ask: () async throws -> GitHubWork?) async -> Answer {
        do { return .feed(try await ask()) } catch let error as RunnerError where error.status == 404 { return .feed(nil) } catch { return .keep }
    }

    /// Under a kind's cards, for each of its lists obid cut at 100: how many it shows of how many
    /// GitHub found. Not in Sangam's design.
    func cut(_ kind: WorkType) -> [String] {
        let lists: [(Item.List, String)] = switch kind {
        case .review: [(.reviews, "pull requests waiting for your review"), (.mine, "your open pull requests")]
        case .issues: [(.assigned, "issues assigned to you")]
        default: []
        }
        return lists.compactMap { list, what in
            let shown = items.count { $0.list == list }
            guard let found = counts[list], found > shown else { return nil }
            return "The latest \(shown) of \(found) \(what). The rest are on GitHub."
        }
    }

    /// The items under `kind` with no job on them, newest first: a started one is its job now,
    /// listed with the others. Not the ones put off with Later this launch.
    func waiting(_ kind: WorkType, later: Set<String> = []) -> [Item] {
        items.filter { $0.type == kind && $0.job == nil && !later.contains($0.id) }
            .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    /// One group of a kind's To do tab: the waiting items in one board column (`name`) of one
    /// project (`project`), or on no board (`name` nil).
    nonisolated struct Column: Identifiable, Equatable, Sendable {
        var name: String?
        var project: String?
        var items: [Item]
        var id: String { "\(project ?? "")\u{1F}\(name ?? "")" }

        /// Where a column goes on the tab: the work under way first, then what's next, the rest
        /// by name, items on no board last.
        static func rank(_ name: String?) -> Int {
            guard let name else { return 5 }
            return ["in progress", "in review", "todo", "backlog"].firstIndex(of: name.lowercased()) ?? 4
        }
    }

    /// A kind's To do tab: its waiting items (`waiting`, newest first) by project and board column,
    /// the columns in a fixed order (`Column.rank`, then by name and project), the items on no
    /// board last. Without boards, one group with no name.
    func toDo(_ kind: WorkType, later: Set<String> = []) -> [Column] {
        var columns: [Column] = []
        for item in waiting(kind, later: later) {
            let project = item.column == nil ? nil : item.board?.project.map(GitHubWork.plain)
            if let at = columns.firstIndex(where: { $0.name == item.column && $0.project == project }) { columns[at].items.append(item) }
            else { columns.append(Column(name: item.column, project: project, items: [item])) }
        }
        return columns.sorted {
            (Column.rank($0.name), $0.name?.lowercased() ?? "", $0.project ?? "") < (Column.rank($1.name), $1.name?.lowercased() ?? "", $1.project ?? "")
        }
    }

    /// A GitHub page to open: `https://github.com/…` and nothing else (no other host, no login in
    /// the URL, no port), since the link comes from GitHub's data, not from Oby.
    static func page(_ string: String) -> URL? {
        guard let parts = URLComponents(string: string), parts.scheme == "https", parts.host?.lowercased() == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil, let url = parts.url else { return nil }
        return url
    }

    /// Someone else's words as one plain line: no control characters or line breaks, at most 200
    /// characters. Shown with `Text(verbatim:)`, never as Markdown.
    static func plain(_ text: String) -> String {
        let line = String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}" ? " " : $0 }))
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }
}

#if DEBUG
extension GitHubWork {
    /// Debug builds launched with `-ObySampleGitHub YES` (or `signedOut`, or `busy`: 9 reviews and
    /// 51 issues on a board's columns, the owner's shape on 2026-10-21): made-up GitHub work in
    /// place of obid's, for screenshots of Review PR and Issues. Nothing is sent.
    /// ponytail: fixed items, enough for screenshots.
    static var sample: GitHubWork? {
        switch UserDefaults.standard.string(forKey: "ObySampleGitHub") {
        case "signedOut": return GitHubWork(signedIn: false)
        case nil, "NO": return nil
        case "busy":
            let now = Date.now, columns = ["In progress", "Todo", "Backlog"]
            return GitHubWork(signedIn: true, login: "well-prado", items: (0..<9).map { n in
                Item(id: "rv\(n)", list: .reviews, repo: "deskree-inc/tetrix-ee", number: 420 - n, title: "Review request \(n + 1)",
                     url: "https://github.com/deskree-inc/tetrix-ee/pull/\(420 - n)", author: ["Ernesto", "Dima", "Daniel"][n % 3],
                     updated: now.addingTimeInterval(Double(n + 1) * -1700))
            } + (0..<51).map { n in
                Item(id: "is\(n)", list: .assigned, repo: "deskree-inc/obi", number: 800 - n, title: "Roadmap issue \(n + 1)",
                     url: "https://github.com/deskree-inc/obi/issues/\(800 - n)", author: "well-prado", updated: now.addingTimeInterval(Double(n + 1) * -2400),
                     board: n < 47 ? .init(project: "Oby — Roadmap", column: columns[n < 3 ? 0 : n < 17 ? 1 : 2]) : nil)
            })
        default:
            let now = Date.now
            return GitHubWork(signedIn: true, login: "well-prado", items: [
                Item(id: "3f9a0c1d2b4e5f60", list: .reviews, repo: "deskree-inc/tetrix-ee", number: 412, title: "retry jitter",
                     url: "https://github.com/deskree-inc/tetrix-ee/pull/412", author: "Ernesto", updated: now.addingTimeInterval(-18 * 60)),
                Item(id: "3f9a0c1d2b4e5f61", list: .reviews, repo: "deskree-inc/tetrix-ee", number: 398, title: "graph tests",
                     url: "https://github.com/deskree-inc/tetrix-ee/pull/398", author: "Dima", updated: now.addingTimeInterval(-41 * 60)),
                Item(id: "3f9a0c1d2b4e5f62", list: .mine, repo: "deskree-inc/oby", number: 700, title: "Pair a device sends you to Remote access",
                     url: "https://github.com/deskree-inc/oby/pull/700", author: "well-prado", updated: now.addingTimeInterval(-50 * 60),
                     reviewDecision: "CHANGES_REQUESTED", checks: "SUCCESS"),
                Item(id: "9b1c0c1d2b4e5f60", list: .assigned, repo: "deskree-inc/oby", number: 251, title: "Attention queue",
                     url: "https://github.com/deskree-inc/oby/issues/251", author: "well-prado", updated: now.addingTimeInterval(-64 * 60)),
                Item(id: "9b1c0c1d2b4e5f61", list: .assigned, repo: "deskree-inc/tetrix-front-end", number: 402, title: "Search ignores accents",
                     url: "https://github.com/deskree-inc/tetrix-front-end/issues/402", author: "Daniel", updated: now.addingTimeInterval(-110 * 60)),
            ])
        }
    }
}
#endif
