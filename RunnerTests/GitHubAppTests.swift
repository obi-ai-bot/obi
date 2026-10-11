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

        init(installations: [(id: Int, login: String)] = [(7, "deskree-inc")]) { self.installations = installations }

        var minted: Int { requests.withLock { $0.filter { $0.method == "POST" }.count } }

        func send(_ method: String, _ path: String, _ bearer: String) async throws -> GitHubApp.Answer {
            let count = requests.withLock { requests in
                requests.append((method, path, bearer))
                return requests.filter { $0.method == "POST" }.count
            }
            if refuse.withLock({ $0 }) { return .init(status: 401, body: Data(#"{"message":"A JSON web token could not be decoded"}"#.utf8)) }
            if method == "GET", path.hasPrefix("/app/installations") {
                let rows = installations.map { ["id": $0.id, "account": ["login": $0.login]] as [String: Any] }
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
        let pull = #"{"state":"open","merged":false,"base":{"ref":"dev"},"head":{"sha":"\#(CheckTests.head)","ref":"oby/fix-151","repo":{"full_name":"deskree-inc/oby"}}}"#
        let ran = Ran { arguments, _ in
            let said: String = switch Array(arguments.prefix(3)) {
            case ["gh", "api", "repos/deskree-inc/oby/pulls/152"]: pull
            case ["gh", "pr", "create"]: "https://github.com/deskree-inc/oby/pull/152"
            case ["gh", "pr", "comment"]: "https://github.com/deskree-inc/oby/pull/152#issuecomment-1"
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
            _ = try await Publish.pullRequest(job, base: "dev", title: "fix: #151")
            // Merging into dev, through the REST API.
            try await MacCheck.merge(job, check)
            // Reviews and check results.
            _ = try await Review.post(job, body: "Approve.")
            _ = try await MacCheck.post(job, body: "Passed.")
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
        #expect(ran.token(["gh", "api", "-X", "PUT", "repos/deskree-inc/oby/pulls/152/merge", "-f", "merge_method=squash", "-f", "sha=\(CheckTests.head)"]) == app)
        #expect(ran.token(["gh", "api", "-X", "DELETE", "repos/deskree-inc/oby/git/refs/heads/oby/fix-151"]) == app)
        let comments = ran.calls.withLock { $0 }.filter { $0.arguments.prefix(3) == ["gh", "pr", "comment"] }
        #expect(comments.count == 2 && comments.allSatisfy { $0.token == app })
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
