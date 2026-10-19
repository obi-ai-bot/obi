import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

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

        private enum Keys: String, CodingKey { case id, list, repo, number, title, url, author, updated, draft, reviewDecision, checks, known, job }

        init(id: String, list: List, repo: String, number: Int, title: String, url: String, author: String? = nil, updated: Date? = nil,
             draft: Bool = false, reviewDecision: String? = nil, checks: String? = nil, known: Bool = true, job: String? = nil) {
            (self.id, self.list, self.repo, self.number, self.title, self.url, self.author, self.updated) = (id, list, repo, number, title, url, author, updated)
            self.draft = draft
            (self.reviewDecision, self.checks, self.known, self.job) = (reviewDecision, checks, known, job)
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

    /// What the start button does, said under the choices as obid's own inbox item says it.
    var actionDetail: String? {
        switch list {
        case .reviews: "Starts Oby's review of it. Nothing is posted on GitHub."
        case .assigned: "Starts a fix job on it, which opens a pull request when its check passes."
        case .mine: nil
        }
    }

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

    /// Home's chips with GitHub's: Review PR and Issues show while GitHub has something there, or
    /// while it's signed out (so Connect GitHub can be found); each chip's count holds what waits to start.
    static func chips<J>(_ groups: [WorkList.Group<J>], waiting: (WorkType) -> Int, connect: Connect) -> [WorkList.Group<J>] {
        var list = groups
        for kind in [WorkType.review, .issues] {
            let count = waiting(kind)
            if let index = list.firstIndex(where: { $0.type == kind }) {
                list[index].count += count
            } else if count > 0 || connect == .signedOut {
                list.append(WorkList.Group(id: kind.id, type: kind, label: kind.label, items: [], count: count, countLabel: "open", needs: 0, fresh: false))
            }
        }
        return list.sorted { order($0.type) < order($1.type) }
    }

    private static func order(_ type: WorkType?) -> Int {
        switch type { case .review: 0; case .issues: 1; case .teammate: 2; case .tasks, nil: 3 }
    }
}

#if DEBUG
extension GitHubWork {
    /// Debug builds launched with `-ObySampleGitHub YES` (or `signedOut`): made-up GitHub work in
    /// place of obid's, for screenshots of Review PR and Issues. Nothing is sent.
    /// ponytail: fixed items, enough for screenshots.
    static var sample: GitHubWork? {
        switch UserDefaults.standard.string(forKey: "ObySampleGitHub") {
        case "signedOut": return GitHubWork(signedIn: false)
        case nil, "NO": return nil
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

#if os(iOS) || os(macOS)
/// A GitHub item waiting to start, as a card in Review PR or Issues (Sangam's TaskCard with its
/// "Start it?" decision): GitHub's mark, who and what, the repository, then the headline and the
/// one tap that starts Oby's job, Open on GitHub, and Later.
struct GitHubCard: View {
    let item: GitHubWork.Item
    let start: () async throws -> Void
    let later: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image("GitHub").resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(Tokens.muted)
                    .accessibilityLabel("GitHub")
                (Text(verbatim: item.who.map { $0 + "  " } ?? "").foregroundStyle(Tokens.muted)
                    + Text(verbatim: item.heading).foregroundStyle(Tokens.ink))
                    .font(Tokens.font(Tokens.textLg, .semibold)).lineLimit(2)
                Spacer(minLength: 8)
                if let updated = item.updated {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(TaskFacts.duration(context.date.timeIntervalSince(updated))).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
                    }
                }
            }
            Text(verbatim: item.repoName).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted)
                .lineLimit(1).padding(.leading, 26).padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                AskCard(kind: item.label, title: item.headline, happened: item.note,
                        options: (item.action.map { [CardOption(label: $0, answer: $0, detail: item.actionDetail, recommended: true)] } ?? [])
                            + (item.page == nil ? [] : [CardOption(label: "Open on GitHub", answer: "open")]),
                        busy: busy,
                        onChoose: { option in
                            if option.answer == "open" { item.page.map { openURL($0) }; return }
                            busy = true
                            Task {
                                defer { busy = false }
                                do { try await start(); problem = nil } catch { problem = error.localizedDescription }
                            }
                        },
                        onLater: later)
                if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 8) }
            }
            .padding(.top, 14)
            .overlay(alignment: .top) { Tokens.divider.frame(height: 1) }
            .padding(.top, 16)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(item.who.map { $0 + ", " } ?? "")\(item.heading), \(item.label)"))
    }
}

/// Connect GitHub, at the top of Review PR and Issues while obid's gh is signed out: why, then the
/// one way in (`connect`; nil where it can't be done, as on the iPhone). Not in Sangam's design.
struct ConnectGitHubCard: View {
    let line: String
    let connect: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("GitHub").resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(Tokens.muted)
                Text("Connect GitHub").font(Tokens.font(Tokens.textLg, .semibold)).foregroundStyle(Tokens.ink)
            }
            Text(line).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            if let connect {
                Button("Connect GitHub", action: connect).buttonStyle(.set).padding(.top, 14)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
#endif
