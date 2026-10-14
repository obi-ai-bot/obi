import Foundation
import Testing
@testable import Oby

struct PublishTests {
    let job = Job(id: "ab12cd34", request: "fix the login button\nit's grey on hover", agent: "claude", account: "default",
                  repo: "deskree-inc/oby", branch: "oby/fix-ab12cd", kind: .fix, task: "Fix the login button.")

    /// A fake secret for each rule, put together at run time so this file never holds one.
    static let samples: [(rule: String, name: String, secret: String)] = [
        ("private key", "value", "-----BEGIN " + "OPENSSH PRIVATE KEY-----"),
        ("AWS access key", "value", "AKIA" + "Z7QW4MXK2PLR9TBN"),
        ("GitHub token", "value", "ghp_" + String(repeating: "a1B2c3", count: 6)),
        ("GitHub token", "value", "github_pat_" + String(repeating: "x9Y8", count: 20)),
        ("Slack token", "value", "xoxb-" + "1234567890-abcdefghij"),
        ("OpenAI key", "value", "sk-proj-" + String(repeating: "Ab1_", count: 12)),
        ("Anthropic key", "value", "sk-ant-api03-" + String(repeating: "Zy9-", count: 12)),
        ("Stripe live key", "value", "sk_live_" + String(repeating: "q8W", count: 9)),
        ("password or secret", "db_password", "correct-" + "horse-battery"),
    ]

    func diff(adding lines: [String], to file: String = "src/config.ts") -> String {
        """
        diff --git a/\(file) b/\(file)
        new file mode 100644
        index 0000000..1111111
        --- /dev/null
        +++ b/\(file)
        @@ -0,0 +1,\(lines.count) @@
        """ + "\n" + lines.map { "+" + $0 }.joined(separator: "\n")
    }

    @Test func eachRuleFindsItsSecret() {
        for sample in Self.samples {
            let findings = Publish.findings(inDiff: diff(adding: ["\(sample.name) = \"\(sample.secret)\""]))
            #expect(findings == [Publish.Finding(file: "src/config.ts", line: 1, rule: sample.rule)], "\(sample.rule)")
        }
    }

    @Test func cleanCodePasses() {
        let clean = [
            "let password = \"\"", "if password == \"hunter2-but-longer\" {", "let secretName = \"api-gateway-production\"",
            "const disk = \"disk-usage-monitoring-dashboard-component\"", "password: ${{ secrets.DB_PASSWORD }}",
            "// Paste your key: -----BEGIN PUBLIC KEY-----", "AKIA is how AWS keys start", "ghp_ tokens are 40 characters",
            "token = getenv(\"GITHUB_TOKEN\")", "api_key = os.environ[\"API_KEY\"]",
        ]
        #expect(Publish.findings(inDiff: diff(adding: clean)).isEmpty)
    }

    @Test func secretFilesAreFoundByName() {
        let text = [".env", "config/.env.production", "deploy/id_rsa", "certs/app.p12", ".env.example", "src/environment.ts"]
            .map { diff(adding: ["x"], to: $0) }.joined(separator: "\n")
        let findings = Publish.findings(inDiff: text)
        #expect(findings.map(\.file) == [".env", "config/.env.production", "deploy/id_rsa", "certs/app.p12"])
        #expect(findings.allSatisfy { $0.line == nil })
    }

    @Test func onlyAddedLinesCountAtTheirLineNumbers() {
        let key = "AKIA" + "Z7QW4MXK2PLR9TBN"
        let text = """
            diff --git a/app/keys.txt b/app/keys.txt
            index 1111111..2222222 100644
            --- a/app/keys.txt
            +++ b/app/keys.txt
            @@ -10,4 +10,4 @@ struct Keys {
             one
            -old \(key)
            +++ added, not a header \(key)
             two
            +new \(key)
            """
        #expect(Publish.findings(inDiff: text) == [
            Publish.Finding(file: "app/keys.txt", line: 11, rule: "AWS access key"),
            Publish.Finding(file: "app/keys.txt", line: 13, rule: "AWS access key"),
        ])
    }

    @Test func findingsNeverEchoTheSecret() {
        for sample in Self.samples {
            let findings = Publish.findings(inDiff: diff(adding: ["\(sample.name) = \"\(sample.secret)\""]))
            let shown = Publish.blocked(by: findings) + findings.map(\.description).joined()
            #expect(!shown.contains(sample.secret), "\(sample.rule)")
            #expect(shown.contains("src/config.ts:1"))
        }
    }

    @Test func onlyItsOwnBranchIsEverPushed() {
        #expect(Publish.refusal(job, base: "dev", defaultBranch: "main") == nil)
        #expect(Publish.refusal(job, base: "main", defaultBranch: "main") == nil)
        var other = job
        for branch in ["main", "master", "dev", "feature/login", "oby", "oby/../main", "-oby/x", "oby/x y", "oby/x.lock"] {
            other.branch = branch
            #expect(Publish.refusal(other, base: "dev", defaultBranch: "main") != nil, "\(branch)")
        }
        other.branch = "oby/trunk"
        #expect(Publish.refusal(other, base: "dev", defaultBranch: "oby/trunk") != nil)
        #expect(Publish.refusal(job, base: job.branch, defaultBranch: "main") != nil)
        #expect(Publish.refusal(job, base: "--force", defaultBranch: "main") != nil)
        other = job
        for repo in ["deskree-inc", "deskree-inc/oby/../x", "evil.com/x y", "../oby", "deskree-inc/.."] {
            other.repo = repo
            #expect(Publish.refusal(other, base: "dev", defaultBranch: "main") != nil, "\(repo)")
        }
    }

    @Test func actionIsOneSentence() {
        #expect(Publish.action(for: job, base: "dev") == "Push oby/fix-ab12cd to deskree-inc/oby and open a pull request into dev.")
    }

    @Test func theSummaryIsQuotedNeverLive() {
        var job = job
        job.summary = "Fixed it. @someone please merge.\n```\nCloses #1\n```"
        let body = Publish.body(for: job)
        #expect(body.contains("````\nFixed it. @someone please merge.\n```\nCloses #1\n```\n````"))
        #expect(body.contains("> fix the login button\n> it's grey on hover"))
        #expect(body.contains("by Oby: Oby opened this pull request"))
        #expect(!body.contains("Tetrix-Session"))
    }

    @Test func scanRefusesWhenGitCant() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let error = await #expect(throws: Shell.Failure.self) { try await Publish.scan(folder, base: "main") }
        #expect(error?.message.hasPrefix("Not published: the secret scan couldn't read the changes") == true)
    }

    /// git with no global or system config, so the user's signing and hooks stay out of it.
    func git(_ repo: URL, _ arguments: String...) async throws {
        try await Shell.ok(["git", "-C", repo.path, "-c", "user.name=Oby Tests", "-c", "user.email=tests@oby.invalid"] + arguments,
                           env: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    }

    @Test func scanCatchesAKeyCommittedOnTheBranch() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "oby-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appending(path: "deploy"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let key = "-----BEGIN " + "RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END " + "RSA PRIVATE KEY-----\n"

        try await git(repo, "init", "--quiet", "-b", "main")
        // Already on the base branch, so already public: not this job's to scan.
        try key.write(to: repo.appending(path: "fixture.pem"), atomically: true, encoding: .utf8)
        try await git(repo, "add", ".")
        try await git(repo, "commit", "--quiet", "-m", "base")
        try await git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")

        // The job adds a key and deletes it again: the push would still carry it.
        try await git(repo, "switch", "--quiet", "-c", "oby/fix-ab12cd")
        try ("# deploy key\n" + key).write(to: repo.appending(path: "deploy/key.pem"), atomically: true, encoding: .utf8)
        try await git(repo, "add", ".")
        try await git(repo, "commit", "--quiet", "-m", "add a key")
        let introducing = try await Shell.ok(["git", "-C", repo.path, "rev-parse", "HEAD"],
                                             env: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
        try await git(repo, "rm", "--quiet", "deploy/key.pem")
        try await git(repo, "commit", "--quiet", "-m", "remove the key")

        let findings = try await Publish.scan(repo, base: "main")
        #expect(findings.contains { $0.file == "deploy/key.pem" && $0.line == 2 && $0.rule == "private key"
            && $0.commit == introducing && $0.historyOnly })
        #expect(!findings.contains { $0.file == "fixture.pem" })
    }
}
