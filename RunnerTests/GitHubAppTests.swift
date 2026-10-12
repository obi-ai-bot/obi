import Foundation
import Synchronization
import Testing
@testable import ObyEngine
@testable import oby_runner

/// The runner's own GitHub calls as the Oby by Deskree app, pushes and pull requests as the owner (#151).
@MainActor
struct GitHubAppTests {
    /// GitHub's side: the installations, and a new token each time one is asked for.
    final class GitHub: Sendable {
        let installations: [(id: Int, login: String)]
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let requests = Mutex<[(method: String, path: String, bearer: String)]>([])
        let refuse = Mutex(false)
        /// The installations' Checks permission, as GitHub lists it: "read", "write", or none.
        let checks: String?

        init(installations: [(id: Int, login: String)] = [(7, "deskree-inc")], checks: String? = nil) {
            self.installations = installations
            self.checks = checks
        }

        var minted: Int { requests.withLock { $0.filter { $0.method == "POST" }.count } }

        func send(_ method: String, _ path: String, _ bearer: String) async throws -> GitHubApp.Answer {
            let count = requests.withLock { requests in
                requests.append((method, path, bearer))
                return requests.filter { $0.method == "POST" }.count
            }
            if refuse.withLock({ $0 }) { return .init(status: 401, body: Data(#"{"message":"A JSON web token could not be decoded"}"#.utf8)) }
            if method == "GET", path.hasPrefix("/app/installations") {
                let rows = installations.map { ["id": $0.id, "account": ["login": $0.login], "permissions": checks.map { ["checks": $0] } ?? [:]] as [String: Any] }
                return .init(status: 200, body: try JSONSerialization.data(withJSONObject: rows))
            }
            let expires = clock.withLock { $0 }.addingTimeInterval(3600).ISO8601Format()
            return .init(status: 201, body: Data(#"{"token":"ghs_\#(count)","expires_at":"\#(expires)"}"#.utf8))
        }

        func app() throws -> GitHubApp {
            GitHubApp(id: "5276623", sign: try GitHubAppKey.signer(pem: GitHubAppTests.key.pem), send: send, now: { [self] in clock.withLock { $0 } })
        }
    }

    /// What ran: each tool's arguments and the GH_TOKEN it got, if any.
    final class Ran: Sendable {
        let calls = Mutex<[(arguments: [String], token: String?)]>([])
        /// gh's answer to a call, by its arguments.
        let answer: @Sendable ([String], String?) -> Shell.Output

        init(answer: @escaping @Sendable ([String], String?) -> Shell.Output = { _, _ in Shell.Output(status: 0, out: Data(), err: "") }) {
            self.answer = answer
        }

        func stand(_ app: GitHubApp?) -> Shell.Stand {
            Shell.Stand(app: app) { [self] arguments, env in
                let token = env["GH_TOKEN"] ?? nil
                calls.withLock { $0.append((arguments, token)) }
                return answer(arguments, token)
            }
        }

        func token(_ prefix: [String]) -> String?? {
            calls.withLock { $0 }.first { Array($0.arguments.prefix(prefix.count)) == prefix }.map(\.token)
        }
    }

    /// A throwaway RSA key from openssl, made once for these tests: nothing secret is in the repository.
    struct Key: Sendable {
        let folder: URL
        let pem: String

        init() throws {
            folder = try temporaryFolder()
            try Self.openssl(["genrsa", "-out", folder.appending(path: "key.pem").path, "2048"])
            try Self.openssl(["rsa", "-in", folder.appending(path: "key.pem").path, "-pubout", "-out", folder.appending(path: "public.pem").path])
            pem = try String(contentsOf: folder.appending(path: "key.pem"), encoding: .utf8)
        }

        /// Whether `signature` is RS256 over `input` with this key, as openssl checks it.
        func verifies(_ signature: Data, for input: Data) throws -> Bool {
            let name = UUID().uuidString
            let signed = folder.appending(path: "\(name).sig"), data = folder.appending(path: "\(name).txt")
            try signature.write(to: signed)
            try input.write(to: data)
            return (try? Self.openssl(["dgst", "-sha256", "-verify", folder.appending(path: "public.pem").path, "-signature", signed.path, data.path])) != nil
        }

        @discardableResult
        static func openssl(_ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["openssl"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Shell.Failure(message: "openssl \(arguments.first ?? ""): exit \(process.terminationStatus)") }
            return process.terminationStatus
        }
    }
    nonisolated static let key = try! Key()

    static func job(_ id: String = "app-151") -> Job {
        var job = Job(id: id, request: "Fix #151", agent: "claude", account: "default", repo: "deskree-inc/oby", branch: "oby/fix-151",
                      base: "dev", pr: nil, kind: .fix, task: "Fix #151")
        job.published = "https://github.com/deskree-inc/oby/pull/152"
        return job
    }

    // MARK: The JWT and the tokens

    @Test func theJWTIsRS256WithTheAppAsIssuerForNineMinutes() async throws {
        let github = GitHub()
        let jwt = try await github.app().jwt()
        let parts = jwt.split(separator: ".").map(String.init)
        try #require(parts.count == 3)
        func decoded(_ part: String) throws -> Data {
            var text = part.replacing("-", with: "+").replacing("_", with: "/")
            text += String(repeating: "=", count: (4 - text.count % 4) % 4)
            return try #require(Data(base64Encoded: text))
        }
        let header = try #require(try JSONSerialization.jsonObject(with: decoded(parts[0])) as? [String: Any])
        #expect(header as NSDictionary == ["alg": "RS256", "typ": "JWT"])
        let claims = try #require(try JSONSerialization.jsonObject(with: decoded(parts[1])) as? [String: Any])
        let now = 1_800_000_000
        #expect(claims["iss"] as? String == "5276623")
        #expect(claims["iat"] as? Int == now - 60 && claims["exp"] as? Int == now + 540)
        #expect((claims["exp"] as? Int ?? .max) - now <= 600)
        #expect(try Self.key.verifies(decoded(parts[2]), for: Data((parts[0] + "." + parts[1]).utf8)))
        #expect(try !Self.key.verifies(decoded(parts[2]), for: Data((parts[0] + "." + parts[0]).utf8)))
    }

    @Test func tokensAreKeptUntilFiveMinutesBeforeTheyExpire() async throws {
        let github = GitHub()
        let app = try github.app()
        #expect(await app.token(for: "deskree-inc") == "ghs_1")
        #expect(await app.token(for: "Deskree-Inc") == "ghs_1")
        #expect(github.minted == 1 && app.works)
        // The installation is found once, with the JWT, and the token is minted with it.
        let first = try #require(github.requests.withLock { $0 }.first)
        #expect(first.method == "GET" && first.path == "/app/installations?per_page=100" && first.bearer.split(separator: ".").count == 3)
        github.clock.withLock { $0 += 3600 - 301 }
        #expect(await app.token(for: "deskree-inc") == "ghs_1")
        github.clock.withLock { $0 += 2 }
        #expect(await app.token(for: "deskree-inc") == "ghs_2")
        #expect(github.minted == 2)
    }

    @Test func aRefusedTokenIsMintedAgainAndTheCallRunsOnceMore() async throws {
        let github = GitHub()
        let app = try github.app()
        let ran = Ran { _, token in
            token == "ghs_1" ? Shell.Output(status: 1, out: Data(), err: "HTTP 401: Bad credentials (https://api.github.com/graphql)")
                             : Shell.Output(status: 0, out: Data("[]".utf8), err: "")
        }
        let result = try await Shell.$stand.withValue(ran.stand(app)) {
            try await Shell.run(["gh", "pr", "list", "-R", "deskree-inc/oby"], as: .app)
        }
        #expect(result.status == 0 && result.text == "[]")
        #expect(ran.calls.withLock { $0.map(\.token) } == ["ghs_1", "ghs_2"])
        #expect(github.minted == 2)
    }

    // MARK: Who acts

    @Test func withoutTheAppOrItsInstallationCallsGoAsTheOwner() async throws {
        let github = GitHub()
        let ran = Ran()
        try await Shell.$stand.withValue(ran.stand(try github.app())) {
            _ = try await Shell.run(["gh", "issue", "list", "-R", "someone-else/repo"], as: .app)
            _ = try await Shell.run(["gh", "api", "user", "-q", ".login"], as: .app)
            _ = try await Shell.run(["gh", "issue", "edit", "1", "-R", "deskree-inc/oby", "--add-assignee", "@me"], as: .app)
            _ = try await Shell.run(["gh", "project", "list", "--owner", "@me"], as: .app)
            _ = try await Shell.run(["gh", "pr", "create", "-R", "deskree-inc/oby"])
        }
        #expect(ran.calls.withLock { $0.map(\.token) } == [nil, nil, nil, nil, nil])

        // An app GitHub refuses, or none at all.
        let refusing = GitHub()
        refusing.refuse.withLock { $0 = true }
        let stranded = Ran()
        try await Shell.$stand.withValue(stranded.stand(try refusing.app())) {
            _ = try await Shell.run(["gh", "pr", "view", "1", "-R", "deskree-inc/oby"], as: .app)
        }
        try await Shell.$stand.withValue(stranded.stand(nil)) {
            _ = try await Shell.run(["gh", "pr", "view", "1", "-R", "deskree-inc/oby"], as: .app)
        }
        #expect(stranded.calls.withLock { $0.map(\.token) } == [nil, nil])
        #expect(!GitHubApp.inUse)
    }

    @Test func theAccountACallNamesPicksTheInstallation() {
        #expect(GitHubApp.account(in: ["gh", "pr", "view", "3", "-R", "deskree-inc/oby"]) == "deskree-inc")
        #expect(GitHubApp.account(in: ["gh", "pr", "view", "3", "--repo", "deskree-inc/oby"]) == "deskree-inc")
        #expect(GitHubApp.account(in: ["gh", "project", "item-list", "20", "--owner", "deskree-inc"]) == "deskree-inc")
        #expect(GitHubApp.account(in: ["gh", "api", "repos/deskree-inc/oby/pulls/3"]) == "deskree-inc")
        #expect(GitHubApp.account(in: ["gh", "pr", "view", "https://github.com/deskree-inc/oby/pull/3"]) == "deskree-inc")
        #expect(GitHubApp.account(in: ["gh", "api", "graphql", "-f", "query=…"]) == nil)
        #expect(GitHubApp.ownersOwn(["gh", "api", "user/emails"]) && GitHubApp.ownersOwn(["api", "user", "-q", ".login"]))
        #expect(!GitHubApp.ownersOwn(["gh", "api", "repos/deskree-inc/oby/issues/1/sub_issues?per_page=50"]))
    }

    @Test func theRunnersOwnCallsActAsTheAppAndPublishingAsTheOwner() async throws {
        let github = GitHub()
        let pull = #"{"title":"fix: it (#151)","state":"open","merged":false,"base":{"ref":"dev"},"head":{"sha":"\#(CheckTests.head)","ref":"oby/fix-151","repo":{"full_name":"deskree-inc/oby"}}}"#
        let ran = Ran { arguments, _ in
            let said: String = switch Array(arguments.prefix(3)) {
            case ["gh", "api", "repos/deskree-inc/oby/pulls/152"]: pull
            case ["gh", "api", "repos/deskree-inc/oby/pulls/152/commits?per_page=100"]: #"[{"commit":{"message":"fix: it\n\nCloses #151"}}]"#
            case ["gh", "api", "repos/deskree-inc/oby/commits/\(CheckTests.head)/check-runs?check_name=Oby%20review&filter=latest&per_page=100"],
                 ["gh", "api", "repos/deskree-inc/oby/commits/\(CheckTests.head)/check-runs?check_name=Oby%20Mac%20check&filter=latest&per_page=100"]:
                #"{"check_runs":[]}"#
            // Xcode Cloud's checks, read right before the merge (#122).
            case ["gh", "api", "repos/deskree-inc/oby/commits/\(CheckTests.head)/check-runs?per_page=100"]: #"[{"check_runs":[]}]"#
            case ["gh", "api", "-X"] where arguments.contains("repos/deskree-inc/oby/check-runs"): #"{"html_url":"https://github.com/deskree-inc/oby/runs/1"}"#
            case ["gh", "pr", "create"]: "https://github.com/deskree-inc/oby/pull/152"
            case ["gh", "pr", "view"]: #"{"state":"OPEN","reviewDecision":"","mergedAt":null,"baseRefName":"dev","headRefOid":"\#(CheckTests.head)"}"#
            case ["gh", "api", "user"]: "well-prado"
            case ["gh", "pr", "list"]: ""
            case ["gh", "project", "list"] where arguments.contains("@me"): #"{"projects":[]}"#
            case ["gh", "project", "list"]: #"{"projects":[{"title":"\#(Lead.boardTitle)","number":20}]}"#
            case ["gh", "project", "item-list"]: #"{"items":[]}"#
            default: arguments.first == "gh" && arguments.contains("--json") ? "[]" : ""
            }
            return Shell.Output(status: 0, out: Data(said.utf8), err: "")
        }
        let folder = try temporaryFolder()
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "jobs.sqlite")))
        let job = Self.job()
        let check = MacCheck.make(for: job, pr: 152, head: CheckTests.head)
        try await Shell.$stand.withValue(ran.stand(try github.app())) {
            // Publishing: the open PR is looked up as the app, and opened as the owner.
            _ = try await Publish.pullRequest(job, base: "dev", title: "fix: #151", closes: true)
            // Merging into dev, through the REST API.
            try await MacCheck.merge(job, check)
            // Reviews and check results, as check runs.
            var check = check
            check.state = .passed
            check.mac = "Studio"
            _ = try await CheckRun.post(job, Review.checkRun(Review(verdict: .approved, job: "r", agent: "codex", account: "Work", round: 1),
                                                             summary: "Approve.", head: CheckTests.head))
            _ = try await CheckRun.post(job, MacCheck.checkRun(check))
            // Following the PR, the issue and its epic, the board, the failure records.
            _ = try await PullRequests(desk: desk).read(try PullRequests.arguments(for: job))
            _ = try await desk.issueSync.gh(["issue", "view", "151", "-R", job.repo, "--json", "title"])
            _ = try await desk.failureLog.gh(["issue", "list", "-R", job.repo, "--label", "oby-failure"])
            _ = await Workspace.openSubIssues(of: 151, in: job.repo)
            _ = try? await Board.read(repos: [job.repo])
        }
        let app = "ghs_1"
        #expect(ran.token(["gh", "pr", "list"]) == app)
        #expect(ran.token(["gh", "pr", "create"]) == .some(nil))
        #expect(ran.token(["gh", "api", "repos/deskree-inc/oby/pulls/152"]) == app)
        #expect(ran.token(["gh", "api", "repos/deskree-inc/oby/pulls/152/commits?per_page=100"]) == app)
        #expect(ran.token(["gh", "api", "repos/deskree-inc/oby/commits/\(CheckTests.head)/check-runs?per_page=100", "--paginate", "--slurp"]) == app)
        #expect(ran.token(["gh", "api", "-X", "PUT", "repos/deskree-inc/oby/pulls/152/merge", "-f", "merge_method=squash", "-f", "sha=\(CheckTests.head)",
                           "-f", "commit_title=fix: it (#151) (#152)", "-f", "commit_message=Part of #151"]) == app)
        #expect(ran.token(["gh", "api", "-X", "DELETE", "repos/deskree-inc/oby/git/refs/heads/oby/fix-151"]) == app)
        let runs = ran.calls.withLock { $0 }.filter { $0.arguments.contains("repos/deskree-inc/oby/check-runs") }
        #expect(runs.count == 2 && runs.allSatisfy { $0.token == app && $0.arguments.contains("POST") })
        // No comment from the runner on a pull request or an issue: GitHub emails the owner for each (#198).
        #expect(!ran.calls.withLock { $0 }.contains { $0.arguments.contains("comment") })
        #expect(ran.token(["gh", "pr", "view"]) == app)
        #expect(ran.token(["gh", "issue", "view"]) == app)
        #expect(ran.token(["gh", "issue", "list"]) == app)
        #expect(ran.token(["gh", "api", "repos/deskree-inc/oby/issues/151/sub_issues?per_page=50"]) == app)
        // The board: who the owner is, and their own projects, as the owner; the organization's as the app.
        #expect(ran.token(["gh", "api", "user"]) == .some(nil))
        #expect(ran.token(["gh", "project", "list", "--owner", "@me"]) == .some(nil))
        #expect(ran.token(["gh", "project", "list", "--owner", "deskree-inc"]) == app)
        #expect(github.minted == 1)
    }

    // MARK: Check runs (#198)

    /// GitHub's check runs: what's on each commit, by which app, and what each request sent.
    final class Runs: Sendable {
        struct Run: Sendable {
            var id: Int
            var app: Int
            var name: String
            var head: String
            var body: [String: String]
        }
        let runs = Mutex<[Run]>([])
        let sent = Mutex<[(method: String, path: String, body: [String: String])]>([])
        /// GitHub refuses writes: the app has Checks: read only.
        let refuse = Mutex(false)

        /// gh's answer: GET lists the runs on a commit, POST adds one, PATCH updates one.
        func answer(_ arguments: [String]) -> Shell.Output {
            func said(_ object: Any) -> Shell.Output { Shell.Output(status: 0, out: try! JSONSerialization.data(withJSONObject: object), err: "") }
            // The secret scan's own tools find nothing.
            guard arguments.prefix(2) == ["gh", "api"] else { return Shell.Output(status: 0, out: Data(), err: "") }
            if arguments.count == 3, let path = URLComponents(string: arguments[2]), path.path.hasSuffix("/check-runs") {
                let parts = path.path.split(separator: "/")
                let name = path.queryItems?.first { $0.name == "check_name" }?.value
                let rows = runs.withLock { $0 }.filter { $0.head == parts[parts.count - 2] && $0.name == name }
                return said(["total_count": rows.count, "check_runs": rows.map { ["id": $0.id, "name": $0.name, "app": ["id": $0.app]] }])
            }
            guard let method = arguments.firstIndex(of: "-X").map({ arguments[$0 + 1] }), let input = arguments.firstIndex(of: "--input"),
                  let path = arguments.dropFirst(2).first(where: { $0.hasPrefix("repos/") }),
                  let data = FileManager.default.contents(atPath: arguments[input + 1]),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Shell.Output(status: 1, out: Data(), err: "bad request") }
            var body: [String: String] = [:]
            for (key, value) in object {
                if let output = value as? [String: String] { for (inner, text) in output { body["\(key).\(inner)"] = text } } else { body[key] = "\(value)" }
            }
            sent.withLock { $0.append((method, path, body)) }
            if refuse.withLock({ $0 }) {
                return Shell.Output(status: 1, out: Data(#"{"message":"Resource not accessible by integration"}"#.utf8),
                                    err: "gh: Resource not accessible by integration (HTTP 403)")
            }
            let id: Int = runs.withLock { runs in
                if method == "PATCH", let id = Int(path.split(separator: "/").last ?? ""), let index = runs.firstIndex(where: { $0.id == id }) {
                    runs[index].body = runs[index].body.merging(body) { $1 }
                    return id
                }
                let id = 100 + runs.count
                runs.append(Run(id: id, app: 5276623, name: body["name"] ?? "", head: body["head_sha"] ?? "", body: body))
                return id
            }
            return said(["id": id, "html_url": "https://github.com/deskree-inc/oby/runs/\(id)"])
        }
    }

    static func review(_ verdict: Review.Verdict, round: Int = 1) -> Review {
        Review(verdict: verdict, job: "r", agent: "codex", account: "Work", round: round)
    }

    @Test func aReviewAndAMacCheckAreCheckRunsOnTheCommitAndARerunUpdatesItsOwn() async throws {
        let github = GitHub(checks: "write")
        let app = try github.app()
        let runs = Runs()
        // Another app's check run with the same name on the same commit is never touched.
        runs.runs.withLock { $0.append(.init(id: 7, app: 1, name: "Oby review", head: CheckTests.head, body: [:])) }
        let ran = Ran { arguments, _ in runs.answer(arguments) }
        let job = Self.job()
        var check = MacCheck.make(for: job, pr: 152, head: CheckTests.head)
        check.mac = "Studio"
        check.state = .failed
        check.steps = [MacCheck.Step(name: "Mac app and MacTests", passed: false, seconds: 61,
                                     failing: [MacCheck.FailingTest(test: "MacTests/PublishTests/blocksASecret()", message: "Expectation failed")])]
        check.failures = ["MacTests/PublishTests/blocksASecret()"]
        let urls = try await Shell.$stand.withValue(ran.stand(app)) {
            [
                try await CheckRun.post(job, Review.checkRun(Self.review(.changesRequested), summary: "Blocking:\n- It crashes\n\nVERDICT: CHANGES REQUESTED", head: CheckTests.head)),
                // The same commit reviewed again: the app's own check run changes, no second one.
                try await CheckRun.post(job, Review.checkRun(Self.review(.approved, round: 2), summary: "Fine.\n\nVERDICT: APPROVED", head: CheckTests.head)),
                try await CheckRun.post(job, MacCheck.checkRun(check)),
            ]
        }
        #expect(urls.map(\.absoluteString) == ["https://github.com/deskree-inc/oby/runs/101", "https://github.com/deskree-inc/oby/runs/101", "https://github.com/deskree-inc/oby/runs/102"])
        let sent = runs.sent.withLock { $0 }
        #expect(sent.map(\.method) == ["POST", "PATCH", "POST"])
        #expect(sent.map(\.path) == ["repos/deskree-inc/oby/check-runs", "repos/deskree-inc/oby/check-runs/101", "repos/deskree-inc/oby/check-runs"])
        // Changes requested: failure, the review fenced as its summary.
        #expect(sent[0].body["name"] == "Oby review" && sent[0].body["head_sha"] == CheckTests.head && sent[0].body["status"] == "completed")
        #expect(sent[0].body["conclusion"] == "failure" && sent[0].body["output.title"] == "Oby review · Codex · Work: Changes requested")
        #expect(sent[0].body["output.summary"]?.hasPrefix("```\nBlocking:\n- It crashes\n\nVERDICT: CHANGES REQUESTED\n```") == true)
        // Approved on the second look: success.
        #expect(sent[1].body["conclusion"] == "success" && sent[1].body["output.title"] == "Oby review · Codex · Work: Approved" && sent[1].body["head_sha"] == nil)
        #expect(sent[1].body["output.summary"]?.contains("review 2. ") == true)
        // The Mac check: failure, the steps and the failing tests.
        #expect(sent[2].body["name"] == "Oby Mac check" && sent[2].body["conclusion"] == "failure" && sent[2].body["output.title"] == "Oby Mac check · Studio: Failed")
        #expect(sent[2].body["output.summary"]?.contains("| Mac app and MacTests | Failed | 1m 01s |") == true)
        #expect(sent[2].body["output.summary"]?.contains("```\nMacTests/PublishTests/blocksASecret(): Expectation failed\n```") == true)
        #expect(runs.runs.withLock { $0 }.first { $0.id == 7 }?.body.isEmpty == true)
        // Every call as the app, and none a comment.
        #expect(ran.calls.withLock { $0 }.filter { $0.arguments.first == "gh" }.allSatisfy { $0.token == "ghs_1" && !$0.arguments.contains("comment") })
        _ = await app.check()
        #expect(app.writesChecks && GitHubApp.checks(app) == "ok")

        // Passed, and the Mac couldn't run it: success and neutral.
        check.state = .passed
        #expect(MacCheck.checkRun(check).conclusion == .success)
        check.state = .error
        check.problem = "The simulator is missing."
        let neutral = MacCheck.checkRun(check)
        #expect(neutral.conclusion == .neutral && neutral.title == "Oby Mac check · Studio: Couldn't run" && neutral.summary.contains("The simulator is missing."))
    }

    @Test func withoutTheChecksPermissionNothingGoesOutAndTheStatusSaysSo() async throws {
        // The app as it's installed today: Checks read.
        let github = GitHub(checks: "read")
        let app = try github.app()
        _ = await app.check()
        #expect(app.works && !app.writesChecks && GitHubApp.checks(app) == "missing permission")
        let runs = Runs()
        runs.refuse.withLock { $0 = true }
        let ran = Ran { arguments, _ in runs.answer(arguments) }
        let run = Review.checkRun(Self.review(.approved), summary: "Fine.\n\nVERDICT: APPROVED", head: CheckTests.head)
        await #expect(throws: CheckRun.Unwritable.self) {
            try await Shell.$stand.withValue(ran.stand(app)) { _ = try await CheckRun.post(Self.job(), run) }
        }
        #expect(GitHubApp.checks(app) == "missing permission")
        // Once the owner grants it, the next one goes through, and the status says so.
        runs.refuse.withLock { $0 = false }
        _ = try await Shell.$stand.withValue(ran.stand(app)) { try await CheckRun.post(Self.job(), run) }
        #expect(GitHubApp.checks(app) == "ok")
        #expect(!ran.calls.withLock { $0 }.contains { $0.arguments.contains("comment") })

        // Without the app, the owner's login can't write check runs: nothing runs at all.
        let stranded = Ran()
        await #expect(throws: CheckRun.Unwritable.self) {
            try await Shell.$stand.withValue(stranded.stand(nil)) { _ = try await CheckRun.post(Self.job(), run) }
        }
        #expect(stranded.calls.withLock { $0 }.isEmpty && GitHubApp.checks(nil) == "no app")
    }

    @Test func noRunnerPathCommentsOnAPullRequestOrAnIssue() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for folder in ["Engine", "Runner"] {
            let files = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: folder).path).filter { $0.hasSuffix(".swift") }
            #expect(!files.isEmpty)
            for file in files {
                let text = try String(contentsOf: root.appending(path: "\(folder)/\(file)"), encoding: .utf8)
                #expect(text.firstMatch(of: /"(pr|issue)",\s*"comment"/) == nil, "\(folder)/\(file)")
            }
        }
    }

    // MARK: Agents

    @Test func agentsNeverGetAGitHubTokenNorWhereTheAppsKeyIs() throws {
        let folder = try temporaryFolder()
        let vault = Vault(store: FileVault(folder: folder.appending(path: "vault")))
        let base = ["PATH": "/usr/bin", "GH_TOKEN": "ghs_runner", "GITHUB_TOKEN": "ghs_other",
                    GitHubApp.idVariable: "5276623", GitHubApp.keyVariable: "/home/oby/.config/oby/github-app.pem"]
        let agent = try Agents.environment([:], vault: vault, base: base)
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] + GitHubApp.variables { #expect(agent[key] == nil) }
        #expect(agent["PATH"] == "/usr/bin")
        let brain = try ClaudeBrain(home: nil, vault: vault).environment(base: base)
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] + GitHubApp.variables { #expect(brain.keys.contains(key) && brain[key] == .some(nil)) }
        // Nothing Oby runs inherits the app's settings either.
        for key in GitHubApp.variables { #expect(Shell.environment[key] == nil) }
    }

    // MARK: The runner's settings

    @Test func theAppIsSetUpOnlyWithItsIDAndAPrivateKey() throws {
        #expect(GitHubAppKey.load([:]) == nil)
        let folder = try temporaryFolder()
        let file = folder.appending(path: "github-app.pem")
        let missing = GitHubAppKey.load([GitHubApp.idVariable: "5276623", GitHubApp.keyVariable: file.path])
        #expect(missing.map { if case .failure(let failure) = $0 { failure.message.contains("no key") } else { false } } == true)

        try Self.key.pem.write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o644)
        let open = GitHubAppKey.load([GitHubApp.idVariable: "5276623", GitHubApp.keyVariable: file.path])
        #expect(open.map { if case .failure(let failure) = $0 { failure.message.contains("chmod 600") } else { false } } == true)

        chmod(file.path, 0o600)
        guard case .success(let app) = GitHubAppKey.load([GitHubApp.idVariable: "5276623", GitHubApp.keyVariable: file.path]) else {
            Issue.record("the key wasn't loaded")
            return
        }
        #expect(app.id == "5276623" && !app.works)
    }
}
