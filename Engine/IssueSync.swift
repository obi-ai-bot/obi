import Foundation

/// Runner-owned GitHub writes, serialized across jobs. Never uses an agent's environment.
@MainActor
final class IssueSync {
    nonisolated static let coverageInstruction = "In your final summary, list completed Build checklist items from the issue as `- [x] <the exact item text or its bold heading>`. List only items this change fully covers, and leave real-device test items for the user. The runner uses this coverage after the PR merges to update the issue itself."
    nonisolated static let scopeFix = "Runner gh login lacks read:project or project scope; run gh auth refresh -s read:project,project on the runner"
    nonisolated static func projectError(_ text: String) -> String {
        let lower = text.lowercased()
        return lower.contains("scope") && (lower.contains("read:project") || lower.contains("'project'") || lower.contains("scope project")) ? scopeFix : text
    }

    weak var desk: Desk?
    let store: JobStore
    var enabled = false
    var gh: ([String]) async throws -> String = { args in
        do { return try await Shell.ok(["gh"] + args, env: ["GH_PROMPT_DISABLED": "1"]) }
        catch { throw Shell.Failure(message: args.first == "project" ? IssueSync.projectError(error.localizedDescription) : error.localizedDescription) }
    }
    var scan: ([(name: String, text: String)]) async throws -> Void
    private var tail: Task<Void, Never>?
    private var seen: [String: String] = [:]
    var auditURL = Workspace.root.appending(path: "issue-audit.json")
    private struct AuditState: Codable { var day: String?; var outgoing: [Outgoing] = [] }
    private var auditState = AuditState()
    private var auditing = false
    private struct Project { var id: String; var number: Int; var owner: String; var fields: [[String: Any]]; var items: [[String: Any]] }
    private var project: Project?
    private var projectRead = false

    init(desk: Desk, store: JobStore) {
        self.desk = desk
        self.store = store
        scan = { [weak desk] texts in
            guard let desk else { throw Shell.Failure(message: "Issue sync has no desk.") }
            let findings = try await Publish.scan(texts: texts, vault: desk.vault)
            guard findings.isEmpty else { throw Publish.Blocked(findings: findings) }
        }
    }

    struct Event: Equatable {
        var status: String?
        var note: String?
        var key: String
    }

    static func event(_ job: Job) -> Event? {
        guard job.reviewOf == nil else { return nil }
        if job.pullRequest?.state == .merged {
            return Event(status: "status:needs-test", note: "Merged \(job.published ?? "the pull request") into \(job.pullRequest?.base ?? job.base ?? "dev").\n\n\(quoted(job.summary))", key: "merged:\(job.published ?? "")")
        }
        if job.waitsForAnswer || job.reviewNeedsYou || job.needsYou {
            let reason = job.question?.text ?? (job.reviewNeedsYou ? Review.stopLine : job.publishError ?? job.summary.split(separator: "\n").first.map(String.init) ?? "a user decision")
            return Event(status: "status:blocked", note: "Oby is waiting on you: \(quoted(reason))", key: "blocked:\(reason)")
        }
        if job.isActive {
            return Event(status: "status:in-progress", note: "Oby is working on branch \(Publish.code(job.branch)) (job \(job.id)).", key: "start:\(job.branch):\(job.started?.timeIntervalSince1970 ?? 0)")
        }
        if let pr = job.published, (job.pullRequest?.state ?? .open) == .open {
            return Event(status: "status:in-review", note: "Oby opened \(pr) for branch \(Publish.code(job.branch)).", key: "pr:\(pr)")
        }
        return Event(status: nil, note: nil, key: "idle")
    }

    static func quoted(_ text: String) -> String {
        let ticks = String(repeating: "`", count: max(3, (text.matches(of: /`+/).map(\.output.count).max() ?? 0) + 1))
        return "\n\(ticks)\n\(text)\n\(ticks)"
    }

    static func marker(_ key: String) -> String {
        // Stable across processes; Swift's Hasher is deliberately randomized.
        String(key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
    }

    nonisolated static func prReference(_ job: Job) -> String {
        job.issue.map { "\n\nPart of #\($0)" } ?? ""
    }

    /// Ambiguous feature references remain unlinked; numbers must name an open issue.
    static func inferred(_ job: Job, issues: [[String: Any]]) -> Int? {
        let open = Set(issues.compactMap { $0["number"] as? Int })
        let references = Set([job.task, job.request, job.title ?? ""].flatMap { text in
            text.split(separator: "\n").compactMap { line in
                line.trimmingCharacters(in: .whitespaces).wholeMatch(of: /(?i)part of #([0-9]+)/).flatMap { Int($0.1) }
            }
        }).intersection(open)
        if references.count == 1 { return references.first }
        if !references.isEmpty { return nil }
        let normalize = { (text: String) in text.lowercased().replacing(/[^a-z0-9]+/, with: " ").trimmingCharacters(in: .whitespaces) }
        let matches = issues.filter { row in
            guard let number = row["number"] as? Int, let title = row["title"] as? String else { return false }
            return job.branch.firstMatch(of: /^oby\/[a-z]+-([0-9]+)$/).flatMap { Int($0.1) } == number ||
                (job.title ?? "").firstMatch(of: /\(#([0-9]+)\)$/).flatMap { Int($0.1) } == number ||
                (!(job.title ?? "").isEmpty && normalize(job.title!) == normalize(title))
        }
        return matches.count == 1 ? matches.first?["number"] as? Int : nil
    }

    func observe(_ job: Job) {
        guard enabled, job.status != .queued, let event = Self.event(job), seen[job.id] != event.key else { return }
        seen[job.id] = event.key
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await sync(job, event: event) }
            catch { recordError(job.id, error); if seen[job.id] == event.key { seen[job.id] = nil } }
        }
    }

    func drain() async { await tail?.value }

    private func json(_ args: [String]) async throws -> Any {
        let text: String
        do { text = try await gh(args) }
        catch { throw Shell.Failure(message: args.first == "project" ? Self.projectError(error.localizedDescription) : error.localizedDescription) }
        return try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private func rows(_ args: [String], key: String? = nil) async throws -> [[String: Any]] {
        let value = try await json(args)
        if let key, let object = value as? [String: Any], let rows = object[key] as? [[String: Any]] { return rows }
        guard let rows = value as? [[String: Any]] else { throw Shell.Failure(message: "Issue sync: gh returned invalid JSON.") }
        return rows
    }

    private func issue(_ number: Int, repo: String) async throws -> [String: Any] {
        guard let row = try await json(["issue", "view", "\(number)", "-R", repo, "--json", "number,title,body,labels,url,state"]) as? [String: Any] else {
            throw Shell.Failure(message: "Issue sync: gh returned no issue.")
        }
        return row
    }

    private func write(_ args: [String], texts: [String], job: Job, action: String, marker: String? = nil) async throws {
        // Arguments are outgoing data too, including label names, URLs and repository names.
        try await scan((texts + args).enumerated().map { ("issue sync \($0.offset)", $0.element) })
        let answer: String
        do { answer = try await gh(args) }
        catch { throw Shell.Failure(message: args.first == "project" ? Self.projectError(error.localizedDescription) : error.localizedDescription) }
        let url = "https://github.com/\(job.repo)/issues/\(job.issue ?? 0)"
        let validComment = answer.hasPrefix(url + "#issuecomment-") && answer.dropFirst((url + "#issuecomment-").count).allSatisfy(\.isNumber)
        let detail = action == "issueLabels" ? args.enumerated().compactMap { i, arg in ["--add-label", "--remove-label"].contains(arg) ? "\(arg) \(args[i + 1])" : nil }.joined(separator: ", ") : action
        let id = action == "comment" && validComment ? answer : "\(url) (\(detail))"
        let outgoing = Outgoing(action: .init(rawValue: action), repo: job.repo, id: id, sync: marker.map(Self.marker))
        if desk?.issueJobs.contains(where: { $0.id == job.id }) == true { desk?.recordIssueOutgoing(job.id, outgoing) }
        else {
            auditState.outgoing.append(outgoing)
            try saveAuditState()
        }
    }

    private func bodyFile(_ body: String, args: [String], job: Job, action: String, marker: String? = nil) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "oby-issue-\(UUID().uuidString).md")
        try body.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await write(args + ["--body-file", file.path], texts: [body], job: job, action: action, marker: marker)
    }

    @discardableResult
    private func comment(_ note: String, job: Job, key: String) async throws -> Bool {
        // Durable outgoing entries also prevent duplicates after a partial transition/restart.
        if desk?.issueJobs.first(where: { $0.id == job.id })?.outgoing?.contains(where: { $0.action == .comment && $0.sync == Self.marker(key) }) == true { return false }
        if auditState.outgoing.contains(where: { $0.repo == job.repo && $0.id.hasPrefix("https://github.com/\(job.repo)/issues/\(job.issue!)") && $0.action == .comment && $0.sync == Self.marker(key) }) { return false }
        try await bodyFile(note, args: ["issue", "comment", "\(job.issue!)", "-R", job.repo], job: job, action: "comment", marker: key)
        return true
    }

    private func labels(_ row: [String: Any], status: String?, job: Job) async throws -> Bool {
        let current = Board.names(row["labels"], key: "name").filter { $0.hasPrefix("status:") }
        guard Set(current) != Set(status.map { [$0] } ?? []) else { return false }
        var args = ["issue", "edit", "\(job.issue!)", "-R", job.repo]
        for label in current where label != status { args += ["--remove-label", label] }
        if let status, !current.contains(status) { args += ["--add-label", status] }
        try await write(args, texts: [], job: job, action: "issueLabels")
        return true
    }

    /// Resolve the same named roadmap and owner as the Lead, then read it once per pass.
    private func roadmap() async throws -> Project? {
        if projectRead { return project }
        let user = (try? await gh(["api", "user", "-q", ".login"])) ?? ""
        var owners = ["@me"]
        for owner in (desk?.repos ?? []).compactMap({ $0.split(separator: "/").first.map(String.init) }) where owner != user && !owners.contains(owner) { owners.append(owner) }
        var found: (String, Int, String)?
        for owner in owners {
            let projects: [[String: Any]]
            do { projects = try await rows(["project", "list", "--owner", owner, "--format", "json", "--limit", "100"], key: "projects") }
            catch {
                if error.localizedDescription == Self.scopeFix { throw error }
                continue
            }
            if let row = projects.first(where: { Board.sameTitle($0["title"] as? String ?? "", Lead.boardTitle) }), let number = Board.int(row["number"]), let id = row["id"] as? String {
                found = (owner, number, id); break
            }
        }
        guard let (owner, number, projectID) = found else { projectRead = true; return nil }
        let fields = try await rows(["project", "field-list", "\(number)", "--owner", owner, "--format", "json", "--limit", "100"], key: "fields")
        var cursor: String?
        var all: [[String: Any]] = []
        var visited = Set<String>()
        repeat {
            let query = "query($id:ID!,$cursor:String){node(id:$id){... on ProjectV2{items(first:100,after:$cursor){nodes{id content{... on Issue{url}} fieldValueByName(name:\"Status\"){... on ProjectV2ItemFieldSingleSelectValue{name}}} pageInfo{hasNextPage endCursor}}}}}"
            var args = ["api", "graphql", "-f", "query=\(query)", "-f", "id=\(projectID)"]
            if let cursor { args += ["-f", "cursor=\(cursor)"] }
            guard let root = try await json(args) as? [String: Any], let data = root["data"] as? [String: Any], let node = data["node"] as? [String: Any], let items = node["items"] as? [String: Any],
                  let nodes = items["nodes"] as? [[String: Any]], let page = items["pageInfo"] as? [String: Any], let more = page["hasNextPage"] as? Bool else {
                throw Shell.Failure(message: "Issue sync: couldn't read project #20 items.")
            }
            all += nodes
            cursor = more ? page["endCursor"] as? String : nil
            if more && cursor == nil { throw Shell.Failure(message: "Issue sync: project pagination returned no cursor.") }
            if let cursor, !visited.insert(cursor).inserted { throw Shell.Failure(message: "Issue sync: project pagination repeated a cursor.") }
        } while cursor != nil
        project = Project(id: projectID, number: number, owner: owner, fields: fields, items: all)
        projectRead = true
        return project
    }

    private func board(status: String?, job: Job) async throws -> Bool {
        guard let status, let project = try await roadmap() else { return false }
        let url = "https://github.com/\(job.repo)/issues/\(job.issue!)"
        guard let item = project.items.first(where: { ($0["content"] as? [String: Any])?["url"] as? String == url }), let itemID = item["id"] as? String else { return false }
        let current = ((item["fieldValueByName"] as? [String: Any])?["name"] as? String)?.lowercased()
        guard !["done", "shipped", "closed"].contains(current ?? "") else { return false }
        let column = switch status { case "status:in-progress": "In progress"; case "status:in-review": "In review"; case "status:blocked": "Blocked"; default: "Needs test" }
        if current == column.lowercased() { return false }
        guard let field = project.fields.first(where: { $0["name"] as? String == "Status" }), let fieldID = field["id"] as? String,
              let options = field["options"] as? [[String: Any]], let option = options.first(where: { ($0["name"] as? String)?.lowercased() == column.lowercased() }), let optionID = option["id"] as? String else {
            throw Shell.Failure(message: "Issue sync: roadmap has no Status option \(column).")
        }
        try await write(["project", "item-edit", "--id", itemID, "--project-id", project.id, "--field-id", fieldID, "--single-select-option-id", optionID], texts: [column], job: job, action: "projectStatus")
        return true
    }

    /// Only exact, explicitly checked PR tasks cover issue tasks. Never guess from prose.
    static func checklist(_ body: String, covered: String) -> String {
        let done = Set(covered.split(separator: "\n").compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("- [x] ") || text.hasPrefix("- [X] ") else { return nil }
            return String(text.dropFirst(6))
        })
        let heading = { (text: String) in text.firstMatch(of: /^\*\*[^*]+\*\*/).map { String($0.output) } }
        let headings = body.split(separator: "\n").compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("- [ ] ") else { return nil }
            return heading(String(text.dropFirst(6)))
        }
        var userTests = false
        return body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("## ") { userTests = text.lowercased().contains("test it when") }
            if userTests { return String(line) }
            let item = String(text.dropFirst(min(6, text.count)))
            let title = heading(item)
            let coveredHeading = title.map { name in done.contains(name) && headings.filter { $0 == name }.count == 1 } ?? false
            if text.hasPrefix("- [ ] "), done.contains(item) || coveredHeading, let range = line.range(of: "- [ ] ") { return line.replacingOccurrences(of: "- [ ] ", with: "- [x] ", range: range) }
            return String(line)
        }.joined(separator: "\n")
    }

    private func sync(_ snapshot: Job, event: Event) async throws {
        guard let desk else { return }
        if !auditing { project = nil; projectRead = false }
        var job = snapshot
        if job.issue == nil {
            let issues = try await rows(["issue", "list", "-R", job.repo, "--state", "open", "--limit", "1000", "--json", "number,title"])
            guard issues.count < 1000, let number = Self.inferred(job, issues: issues) else { return }
            job.issue = number
            desk.linkIssue(job.id, number)
        }
        guard let number = job.issue, number > 0, job.repo.wholeMatch(of: /[A-Za-z0-9-]+\/[A-Za-z0-9._-]+/) != nil, !job.repo.contains("..") else { return }
        var row = try await issue(number, repo: job.repo)
        var status = event.status
        if event.key.hasPrefix("start:"), !desk.issueJobs.contains(where: { $0.id == job.id && ($0.outgoing ?? []).contains(where: { $0.action.rawValue == "issueAssignment" && $0.sync == Self.marker(event.key) }) }) {
            try await scan([("claim", event.note ?? "")])
            try await write(["issue", "edit", "\(number)", "-R", job.repo, "--add-assignee", "@me"], texts: [], job: job, action: "issueAssignment", marker: event.key)
        }
        if event.key.hasPrefix("merged:") {
            guard let url = job.published, let pr = try await json(["pr", "view", url, "-R", job.repo, "--json", "body"]) as? [String: Any], let prBody = pr["body"] as? String else {
                throw Shell.Failure(message: "Issue sync: merged PR returned no body.")
            }
            let old = row["body"] as? String ?? ""
            let body = Self.checklist(old, covered: prBody)
            if body != old {
                try await bodyFile(body, args: ["issue", "edit", "\(number)", "-R", job.repo], job: job, action: "issueChecklist")
                row["body"] = body
            }
            if Self.remainingBuild(body) || desk.issueJobs.contains(where: { $0.id != job.id && $0.repo == job.repo && $0.issue == number && $0.isActive }) { status = "status:in-progress" }
        }
        if let note = event.note { try await comment(note, job: job, key: event.key) }
        // An older slice ending must not clear another slice's running/review status.
        let other = desk.issueJobs.filter { $0.id != job.id && $0.repo == job.repo && $0.issue == number && $0.reviewOf == nil }
        if !job.isActive && !job.waitsForAnswer && !job.needsYou, other.contains(where: { $0.isActive }) { status = "status:in-progress" }
        else if status == nil, other.contains(where: { $0.published != nil && ($0.pullRequest?.state ?? .open) == .open }) { status = "status:in-review" }
        else if status == nil, other.contains(where: { $0.pullRequest?.state == .merged }) { status = Self.remainingBuild(row["body"] as? String ?? "") ? "status:in-progress" : "status:needs-test" }
        _ = try await labels(row, status: status, job: job)
        _ = try await board(status: status, job: job)
        desk.clearIssueSyncError(job.id)
        if event.key.hasPrefix("start:") { desk.issueSyncError(job.id, "Claimed: assigned to you, labeled status:in-progress, branch noted.") }
    }

    static func remainingBuild(_ body: String) -> Bool {
        let build = body.components(separatedBy: "## Build").dropFirst().first?.components(separatedBy: "\n## ").first ?? ""
        return build.contains("- [ ] ")
    }

    private func recordError(_ id: String, _ error: Error) {
        guard let desk else { return }
        let safe = (try? desk.vault.forAgent("Issue sync: \(error.localizedDescription)")) ?? "Issue sync failed; the secret scan couldn't read the vault."
        desk.issueSyncError(id, safe)
    }

    private func saveAuditState() throws {
        try FileManager.default.createDirectory(at: auditURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(auditState).write(to: auditURL, options: .atomic)
    }

    /// Called hourly by the runner; a separate ledger keeps quiet days out of the inbox.
    func audit(now: Date = .now) async {
        guard enabled else { return }
        let previous = tail
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.auditRun(now: now)
        }
        tail = task
        await task.value
    }

    private func auditRun(now: Date) async {
        guard enabled, let desk else { return }
        let auditID = "issue-audit-\(Int(now.timeIntervalSince1970 / 86400))"
        if let data = try? Data(contentsOf: auditURL), let state = try? JSONDecoder().decode(AuditState.self, from: data) { auditState = state }
        guard auditState.day != auditID else { return }
        if desk.repos.isEmpty { desk.repos = (try? await Workspace.knownRepos()) ?? [] }
        guard !desk.repos.isEmpty || !desk.issueJobs.isEmpty else { return }
        let outgoingBefore = Dictionary(desk.issueJobs.map { ($0.id, $0.outgoing?.count ?? 0) }, uniquingKeysWith: { _, last in last })
        let ledgerBefore = auditState.outgoing.count
        auditing = true; project = nil; projectRead = false
        defer { auditing = false; project = nil; projectRead = false }
        var changed = 0, failures: [String] = []
        let roadmap: Project?
        do { roadmap = try await self.roadmap() }
        catch { roadmap = nil; failures.append(error.localizedDescription) }
        let jobs = desk.issueJobs
        let urls = Set((roadmap?.items ?? []).compactMap { ($0["content"] as? [String: Any])?["url"] as? String })
        let repos = Set(urls.compactMap { url -> String? in
            guard let parts = URLComponents(string: url), parts.host == "github.com" else { return nil }
            let path = parts.path.split(separator: "/")
            guard path.count == 4, path[2] == "issues" else { return nil }
            return "\(path[0])/\(path[1])"
        })
        for repo in repos.sorted() {
            do {
                let issues = try await rows(["issue", "list", "-R", repo, "--state", "open", "--limit", "1000", "--json", "number,title,body,labels,url"])
                let prs = try await rows(["pr", "list", "-R", repo, "--state", "open", "--limit", "1000", "--json", "url,title,body,headRefName,closingIssuesReferences"])
                guard issues.count < 1000, prs.count < 1000 else { throw Shell.Failure(message: "Issue audit: result limit reached; no stale statuses removed.") }
                for row in issues {
                    guard let number = row["number"] as? Int, urls.contains("https://github.com/\(repo)/issues/\(number)") else { continue }
                    do {
                        let related = jobs.filter { $0.repo == repo && $0.issue == number && $0.reviewOf == nil }.sorted { $0.created > $1.created }
                        let pr = prs.first { pr in
                            let reference = Job(id: "pr", request: "", agent: "runner", account: "", repo: repo, branch: pr["headRefName"] as? String ?? "", base: nil, pr: nil, kind: .investigate, task: pr["body"] as? String ?? "", title: pr["title"] as? String)
                            return (pr["closingIssuesReferences"] as? [[String: Any]] ?? []).contains { $0["number"] as? Int == number && ($0["url"] as? String ?? "https://github.com/\(repo)/issues/\(number)") == "https://github.com/\(repo)/issues/\(number)" } || related.contains { $0.branch == pr["headRefName"] as? String } || Self.inferred(reference, issues: issues) == number
                        }
                        var fallback = Job(id: auditID + "-\(repo.replacingOccurrences(of: "/", with: "-"))-\(number)", request: "Daily issue audit", agent: "runner", account: "", repo: repo, branch: "", base: nil, pr: nil, kind: .investigate, task: "Daily issue audit")
                        fallback.status = .done
                        var job = related.first(where: { $0.isActive || $0.waitsForAnswer || $0.needsYou }) ?? related.first ?? fallback
                        job.issue = number
                        var status = Self.event(job)?.status
                        if !job.isActive && !job.waitsForAnswer && !job.needsYou {
                            let merged = related.contains { $0.pullRequest?.state == .merged }
                            status = pr != nil ? "status:in-review" : merged ? (Self.remainingBuild(row["body"] as? String ?? "") ? "status:in-progress" : "status:needs-test") : (Board.names(row["labels"], key: "name").contains("status:needs-test") ? "status:needs-test" : nil)
                        }
                        var commented = false
                        if let url = pr?["url"] as? String { commented = try await comment("Oby's pull request for this issue: \(url).", job: job, key: "pr:\(url)") }
                        if job.isActive || job.waitsForAnswer || job.needsYou, let event = Self.event(job), let note = event.note {
                            let posted = try await comment(note, job: job, key: event.key)
                            commented = posted || commented
                        }
                        let labeled = try await labels(row, status: status, job: job)
                        let moved = try await board(status: status, job: job)
                        if labeled || moved || commented { changed += 1 }
                    } catch { failures.append("\(repo)#\(number): \(error.localizedDescription)") }
                }
            } catch { failures.append(error.localizedDescription) }
        }
        let outgoing = desk.issueJobs.flatMap { Array(($0.outgoing ?? []).dropFirst(outgoingBefore[$0.id] ?? 0)) } + Array(auditState.outgoing.dropFirst(ledgerBefore))
        auditState.day = auditID
        do { try saveAuditState() } catch { failures.append("Couldn't save the audit ledger.") }
        if changed > 0 || !failures.isEmpty {
            let line = "Issue audit: fixed drift on \(changed) issue(s)." + (failures.isEmpty ? "" : " " + failures.joined(separator: "; ").replacingOccurrences(of: "\n", with: " "))
            let safe = (try? desk.vault.forAgent(line)) ?? "Issue audit failed: couldn't read the vault."
            desk.addIssueAudit(InboxItem(id: auditID, kind: .audit, job: "", title: "Daily issue audit", text: safe, options: [], created: now, outgoing: outgoing.sorted { $0.date < $1.date }))
        }
    }
}

extension Desk {
    var issueJobs: [Job] {
        var all = Dictionary(issueSync.store.recent(-1).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for job in jobs { all[job.id] = job }
        return Array(all.values)
    }
    func linkIssue(_ id: String, _ number: Int) {
        guard var latest = issueJobs.first(where: { $0.id == id }) else { return }
        latest.issue = number
        if job(id) != nil { replace(latest) } else { issueSync.store.save(latest); onJobChange(latest) }
    }
    func recordIssueOutgoing(_ id: String, _ outgoing: Outgoing) {
        guard var latest = issueJobs.first(where: { $0.id == id }) else { return }
        latest.outgoing = (latest.outgoing ?? []) + [outgoing]
        if job(id) != nil { replace(latest) } else { issueSync.store.save(latest); onJobChange(latest) }
    }
    func issueSyncError(_ id: String, _ line: String) {
        guard var latest = issueJobs.first(where: { $0.id == id }) else { return }
        latest.claim = line
        if job(id) != nil { replace(latest) } else { issueSync.store.save(latest); onJobChange(latest) }
    }
    func clearIssueSyncError(_ id: String) {
        guard var latest = issueJobs.first(where: { $0.id == id }), latest.claim?.hasPrefix("Issue sync:") == true else { return }
        latest.claim = nil
        if job(id) != nil { replace(latest) } else { issueSync.store.save(latest); onJobChange(latest) }
    }
}
