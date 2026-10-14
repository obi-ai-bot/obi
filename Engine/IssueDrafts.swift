import Foundation

/// A chat proposal for a GitHub issue. Creating it is a separate, explicit user action.
nonisolated struct IssueDraft: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case draft, creating, created, failed, discarded }

    struct Fields: Codable, Equatable, Sendable {
        var repo: String
        var title: String
        var what: String
        var why: String
        var how: String
        var acceptance: [String]
        var files: [String]
        var labels: [String]
    }

    var id: String
    var version: Int
    var fields: Fields
    var state: State
    var turn: String
    var created: Date
    var updated: Date
    var issue: Int?
    var url: String?
    var error: String?
    var outgoing: [Outgoing]?
    var previous: Fields?

    init(id: String = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased(),
         version: Int = 1, fields: Fields, state: State = .draft, turn: String,
         created: Date = .now, updated: Date = .now, issue: Int? = nil, url: String? = nil,
         error: String? = nil, outgoing: [Outgoing]? = nil, previous: Fields? = nil) {
        self.id = id
        self.version = version
        self.fields = fields
        self.state = state
        self.turn = turn
        self.created = created
        self.updated = updated
        self.issue = issue
        self.url = url
        self.error = error
        self.outgoing = outgoing
        self.previous = previous
    }

    private enum Keys: String, CodingKey { case id, version, fields, state, turn, created, updated, issue, url, error, outgoing, previous }

    /// GitHub's issue body, generated deterministically so every model produces the same result.
    nonisolated func body(_ fields: Fields? = nil) -> String {
        let fields = fields ?? self.fields
        func safeMentions(_ text: String) -> String {
            text.replacingOccurrences(of: #"(?<![\w`])@([A-Za-z0-9-]+)"#, with: "`@$1`", options: .regularExpression)
        }
        var result = "## What\n\n\(safeMentions(fields.what))\n\n## Why\n\n\(safeMentions(fields.why))\n\n## How\n\n\(safeMentions(fields.how))\n\n### Acceptance tests\n\n"
        result += fields.acceptance.map { "- [ ] \(safeMentions($0))" }.joined(separator: "\n")
        if !fields.files.isEmpty { result += "\n\nFiles: " + fields.files.map { "`\($0)`" }.joined(separator: ", ") }
        result += "\n\n<!-- oby-draft: \(id) -->\nDrafted with Oby from chat."
        return result
    }

    nonisolated func problems(in repos: [String]) -> [String] {
        var problems: [String] = []
        if !repos.contains(fields.repo) { problems.append("repo must be one of the known repositories") }
        if !(1...100).contains(fields.title.count) || fields.title.contains(where: \.isNewline) { problems.append("title must be 1 to 100 characters on one line") }
        for (name, text, limit) in [("what", fields.what, 3000), ("why", fields.why, 3000), ("how", fields.how, 6000)] where !(1...limit).contains(text.count) {
            problems.append("\(name) must be 1 to \(limit) characters")
        }
        if !(1...12).contains(fields.acceptance.count) { problems.append("acceptance must have 1 to 12 tests") }
        if fields.acceptance.contains(where: { !(1...300).contains($0.count) || $0.contains(where: \.isNewline) }) { problems.append("each acceptance test must be 1 to 300 characters on one line") }
        if fields.files.count > 30 { problems.append("files holds at most 30 paths") }
        if fields.files.contains(where: { !Self.validPath($0) }) { problems.append("files must contain repository-relative paths") }
        if fields.labels.count > 5 || fields.labels.contains(where: { $0.isEmpty || $0.count > 50 || $0.contains(where: \.isNewline) }) { problems.append("labels holds at most 5 one-line names") }
        if body().count > 20_000 { problems.append("rendered body is longer than 20,000 characters") }
        return problems
    }

    private nonisolated static func validPath(_ path: String) -> Bool {
        Lead.isPath(path)
    }
}

/// Creates a drafted issue only after checking the current version and scanning every outgoing
/// string. The GitHub app identity is explicit; callers cannot accidentally use the owner's login.
@MainActor final class IssueCreator {
    typealias GitHub = @Sendable (_ arguments: [String], _ actor: GitHubActor) async throws -> String
    typealias Scanner = @Sendable (_ texts: [(name: String, text: String)]) async throws -> [Publish.Finding]

    let store: JobStore
    var gh: GitHub
    var scan: Scanner
    var changed: ((IssueDraft, String?) -> Void)?

    init(store: JobStore,
         gh: @escaping GitHub = { try await Shell.ok(["gh"] + $0, env: ["GH_PROMPT_DISABLED": "1"], as: $1) },
         scan: @escaping Scanner = { try await Publish.scan(texts: $0) },
         changed: ((IssueDraft, String?) -> Void)? = nil) {
        self.store = store
        self.gh = gh
        self.scan = scan
        self.changed = changed
    }

    func create(_ id: String, version: Int, repos: [String]) async -> IssueDraft? {
        guard var draft = store.issueDraft(id) else { return nil }
        guard (draft.state == .draft || draft.state == .failed), draft.version == version else { return draft }
        let problems = draft.problems(in: repos)
        guard problems.isEmpty else { draft.error = problems.joined(separator: "; "); return draft }
        draft.state = .creating
        draft.error = nil
        draft.updated = .now
        store.save(draft)
        changed?(draft, nil)
        do {
            if let found = try await find(draft) {
                return finish(&draft, url: found.url, number: found.number, title: draft.fields.title)
            }
            let labelsOutput = try await gh(["label", "list", "-R", draft.fields.repo, "--json", "name"], .app)
            let available = Set(try Self.labelNames(labelsOutput))
            let dropped = draft.fields.labels.filter { !available.contains($0) }
            let labels = draft.fields.labels.filter { available.contains($0) }
            let body = draft.body()
            let base = ["issue", "create", "-R", draft.fields.repo, "--title", draft.fields.title]
            var args = base
            for label in labels { args += ["--label", label] }
            let texts = [draft.fields.title, body] + args
            let file = FileManager.default.temporaryDirectory.appending(path: "oby-issue-\(UUID().uuidString).md")
            try body.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let finalArgs = args + ["--body-file", file.path]
            let findings = try await scan((texts + finalArgs).enumerated().map { ("issue draft \($0.offset)", $0.element) })
            guard findings.isEmpty else { throw Shell.Failure(message: "Secret scan found \(findings.count) finding(s).") }
            let answer = try await gh(finalArgs, .app)
            guard let url = answer.split(separator: "\n").last.map(String.init),
                  url.hasPrefix("https://github.com/\(draft.fields.repo)/issues/") else {
                throw Shell.Failure(message: "gh opened no issue: \(answer.prefix(200))")
            }
            let number = Int(url.split(separator: "/").last ?? "")
            let reply = dropped.isEmpty ? nil : "Unknown labels were dropped: " + dropped.joined(separator: ", ")
            return finish(&draft, url: url, number: number, title: draft.fields.title, message: reply)
        } catch {
            draft.state = .failed
            draft.error = String(describing: error).split(separator: "\n").first.map(String.init) ?? "GitHub issue creation failed"
            draft.updated = .now
            store.save(draft)
            changed?(draft, nil)
            return draft
        }
    }

    func recover(repos: [String]) async {
        for var draft in store.issueDrafts() where draft.state == .creating {
            do {
                if let found = try await find(draft) { _ = finish(&draft, url: found.url, number: found.number, title: draft.fields.title) }
                else {
                    draft.state = .failed
                    draft.error = "Oby restarted before GitHub answered."
                    draft.updated = .now
                    store.save(draft)
                    changed?(draft, nil)
                }
            } catch {
                draft.state = .failed
                draft.error = "Oby restarted before GitHub answered."
                draft.updated = .now
                store.save(draft)
                changed?(draft, nil)
            }
        }
    }

    private func find(_ draft: IssueDraft) async throws -> (url: String, number: Int?)? {
        let output = try await gh(["issue", "list", "-R", draft.fields.repo, "--state", "all", "--limit", "50", "--search", "oby-draft: \(draft.id) in:body", "--json", "number,url,body"], .app)
        guard let data = output.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw Shell.Failure(message: "Couldn't check whether this issue draft was already created.")
        }
        for row in rows where (row["body"] as? String)?.contains("<!-- oby-draft: \(draft.id) -->") == true {
            guard let url = row["url"] as? String,
                  url.hasPrefix("https://github.com/\(draft.fields.repo)/issues/") else { continue }
            return (url, row["number"] as? Int)
        }
        return nil
    }

    private func finish(_ draft: inout IssueDraft, url: String, number: Int?, title: String, message: String? = nil) -> IssueDraft {
        draft.state = .created
        draft.url = url
        draft.issue = number
        draft.error = message
        draft.outgoing = (draft.outgoing ?? []) + [Outgoing(action: .issue, repo: draft.fields.repo, id: url)]
        draft.updated = .now
        store.save(draft)
        changed?(draft, "Created \(draft.fields.repo)#\(number.map(String.init) ?? "issue"): \(title)." + (message.map { " \($0)" } ?? ""))
        return draft
    }

    private static func labelNames(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw Shell.Failure(message: "Couldn't read the repository's GitHub labels.")
        }
        return rows.compactMap { $0["name"] as? String }
    }
}
