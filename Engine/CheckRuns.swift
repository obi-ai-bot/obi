import Foundation

/// Oby's review and Mac check on a pull request, as GitHub check runs on the commit they judged
/// (#198), never comments: the GitHub app writes them, and a check run sends nobody an email.
/// `Oby review` and `Oby Mac check`, one of each per commit: a later result for the same commit
/// updates the app's own check run. Only the app can write check runs, and only with Checks: Read
/// and write; without either, nothing goes on the pull request, the result stays in Oby, and
/// `/v1/status` says why (`GitHubApp.checks`).
nonisolated struct CheckRun: Equatable, Sendable {
    enum Conclusion: String, Sendable { case success, failure, neutral }

    var name: String
    /// The commit it's on.
    var head: String
    var conclusion: Conclusion
    var title: String
    /// Markdown.
    var summary: String

    static let review = "Oby review"
    static let securityReview = "Oby security review"
    static let macCheck = "Oby Mac check"
    /// GitHub takes 65,535 characters in a summary.
    static let summaryLimit = 60_000

    /// Nothing went on the pull request because the app can't write check runs.
    struct Unwritable: LocalizedError {
        var errorDescription: String?
        static let noApp = Unwritable(errorDescription: "Not posted: only a GitHub app can write checks, and Oby's calls go as the owner.")
        static let permission = Unwritable(errorDescription: "Not posted: the Oby app needs Checks: Read and write on its installation.")
    }

    /// Writes `run` on `author`'s own pull request's commit as the GitHub app, after the secret scan
    /// of its title and summary: the app's check run of that name on that commit when there is one,
    /// else a new one. Returns the check run's URL.
    static func post(_ author: Job, _ run: CheckRun) async throws -> URL {
        guard Review.pullRequest(of: author) != nil else { throw Shell.Failure(message: "Not posted: the job has no pull request of its own.") }
        guard run.head.wholeMatch(of: /[0-9a-f]{40}/) != nil else { throw Shell.Failure(message: "Not posted: Oby can't tell which commit it's about.") }
        // The owner's login can't write check runs, and a call with no app token would go as the owner.
        let owner = String(author.repo.split(separator: "/").first ?? "")
        guard let app = Shell.stand?.app ?? GitHubApp.shared, await app.token(for: owner) != nil else { throw Unwritable.noApp }
        let findings: [Publish.Finding]
        do {
            findings = try await Publish.scan(texts: [("\(run.name) title", run.title), ("\(run.name)", run.summary)])
        } catch {
            throw Shell.Failure(message: "Not posted: the secret scan couldn't run (\(error.localizedDescription)).")
        }
        if !findings.isEmpty { throw Shell.Failure(message: "Not posted: possible secret in " + MacCheck.places(findings) + ".") }

        let runs = "repos/\(author.repo)/check-runs"
        let name = run.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? run.name
        let listed = try await gh(["api", "repos/\(author.repo)/commits/\(run.head)/check-runs?check_name=\(name)&filter=latest&per_page=100"], app)
        let existing = (listed["check_runs"] as? [[String: Any]] ?? []).first { row in
            guard row["name"] as? String == run.name, let by = row["app"] as? [String: Any] else { return false }
            return (by["id"] as? Int).map(String.init) == app.id || by["client_id"] as? String == app.id
        }?["id"] as? Int
        var body: [String: Any] = [
            "status": "completed", "conclusion": run.conclusion.rawValue,
            "completed_at": Date.now.ISO8601Format(),
            "output": ["title": run.title, "summary": String(run.summary.prefix(summaryLimit))],
        ]
        if existing == nil {
            body["name"] = run.name
            body["head_sha"] = run.head
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "oby-check-run-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: body, options: .sortedKeys).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let written = try await gh(existing.map { ["api", "-X", "PATCH", "\(runs)/\($0)", "--input", file.path] }
                                   ?? ["api", "-X", "POST", runs, "--input", file.path], app)
        app.wroteChecks(true)
        guard let url = (written["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw Shell.Failure(message: "GitHub wrote no check run.")
        }
        return url
    }

    /// gh as the app, its answer as JSON. Throws `Unwritable.permission` when GitHub says the app
    /// isn't allowed to write check runs.
    private static func gh(_ args: [String], _ app: GitHubApp) async throws -> [String: Any] {
        let result = try await Shell.run(["gh"] + args, env: ["GH_PROMPT_DISABLED": "1"], timeout: 60, as: .app)
        guard result.status == 0 else {
            if result.err.contains("Resource not accessible by integration") {
                app.wroteChecks(false)
                throw Unwritable.permission
            }
            throw Shell.Failure(message: "gh api: " + (result.err.split(separator: "\n").last.map(String.init) ?? "exit \(result.status)"))
        }
        return (try? JSONSerialization.jsonObject(with: result.out)) as? [String: Any] ?? [:]
    }

    /// `text` in a code block: what's in it came from an agent or a build, so no mention, link or
    /// image in it takes effect.
    static func fenced(_ text: String) -> String {
        let fence = String(repeating: "`", count: max(3, (text.matches(of: /`+/).map(\.output.count).max() ?? 0) + 1))
        return "\(fence)\n\(text)\n\(fence)"
    }
}
