import Foundation

/// Runner-owned GitHub writes, serialized across jobs. Never uses an agent's environment.
@MainActor
final class IssueSync {
    nonisolated static let coverageInstruction = "In your final summary, list completed Build checklist items from the issue as `- [x] <the exact item text or its bold heading>`. List only items this change fully covers, and leave real-device test items for the user. The runner uses this coverage after the PR merges to update the issue itself."
    nonisolated static let scopeFix = "Runner gh login lacks read:project or project scope; run gh auth refresh -s read:project,project on the runner"
    nonisolated static func projectError(_ text: String) -> String {
        let lower = text.lowercased()
        return lower.split(separator: "\n").contains { line in
            line.contains("scope") && (line.contains("read:project") || line.contains("'project'") || line.contains("[project]") || line.contains("scope project"))
        } ? scopeFix : text
    }

    weak var desk: Desk?
    let store: JobStore
    var enabled = false
    var gh: ([String]) async throws -> String = { args in
        do { return try await Shell.ok(["gh"] + args, env: ["GH_PROMPT_DISABLED": "1"], as: .app) }
        catch { throw Shell.Failure(message: args.first == "project" ? IssueSync.projectError(error.localizedDescription) : error.localizedDescription) }
    }
    var scan: ([(name: String, text: String)]) async throws -> Void
    private var tail: Task<Void, Never>?
    private var seen: [String: String] = [:]
    var now: () -> Date = { .now }
    private struct Retry: Codable { var transition: String; var failures: Int; var after: Date }
    var auditURL = Workspace.root.appending(path: "issue-audit.json")
    /// What the owner chose for a status the roadmap has no column for (#215): the column its issues
    /// go to instead, or nil to leave them where they are.
    struct Choice: Codable, Equatable { var use: String? }
    private struct AuditState: Codable {
        var day: String?
        var outgoing: [Outgoing] = []
        var retries: [String: Retry]?
        /// By the missing column's name, lowercased.
        var choices: [String: Choice]?
        /// The column each open decision is about, by its inbox item's id.
        var asked: [String: String]?
    }
    private var auditState = AuditState()
    private var stateLoaded = false
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

    /// A step of a job on its issue: the status label it sets. No comments: they email the owner (#162).
    struct Event: Equatable {
        var status: String?
        var key: String
    }

    static func event(_ job: Job) -> Event? {
        guard job.reviewOf == nil else { return nil }
        if job.pullRequest?.state == .merged {
            return Event(status: "status:needs-test", key: "merged:\(job.published ?? "")")
        }
        if job.waitsForAnswer || job.reviewNeedsYou || job.needsYou {
            let reason = job.question?.text ?? (job.reviewNeedsYou ? job.review?.stopReason ?? Review.stopLine : job.publishError ?? job.summary.split(separator: "\n").first.map(String.init) ?? "a user decision")
            return Event(status: "status:blocked", key: "blocked:\(reason)")
        }
        if job.isActive {
            return Event(status: "status:in-progress", key: "start:\(job.branch):\(job.started?.timeIntervalSince1970 ?? 0)")
        }
        if let pr = job.published, (job.pullRequest?.state ?? .open) == .open {
            return Event(status: "status:in-review", key: "pr:\(pr)")
        }
        return Event(status: nil, key: "idle")
    }

    /// The hidden line in the issue body naming the job that claimed it last. A body edit emails nobody.
    nonisolated static let claimLine = "<!-- oby-claim: job "

    /// The body with one claim line, for `id`, at its end.
    static func claimed(_ body: String, by id: String) -> String {
        var text = body.replacing(/[ \t]*<!-- oby-claim: job [A-Za-z0-9._-]* -->/, with: "")
        while text.last?.isWhitespace == true { text.removeLast() }
        return (text.isEmpty ? "" : text + "\n\n") + claimLine + id + " -->"
    }

    /// The job the body's claim line names, whichever Desk (the runner, the Mac) wrote it.
    static func claimant(_ body: String) -> String? {
        body.matches(of: /<!-- oby-claim: job ([A-Za-z0-9._-]+) -->/).last.map { String($0.1) }
    }

    static func marker(_ key: String) -> String {
        // Stable across processes; Swift's Hasher is deliberately randomized.
        String(key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
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
        loadState()
        let transition = Self.marker(event.key)
        if let retry = auditState.retries?[job.id], retry.transition == transition {
            guard retry.failures < 4, now() >= retry.after else { return }
        }
        seen[job.id] = event.key
        let previous = tail
        tail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await sync(job, event: event)
                if auditState.retries?.removeValue(forKey: job.id) != nil { try? saveAuditState() }
            } catch {
                let old = auditState.retries?[job.id]
                let failures = (old?.transition == transition ? old?.failures ?? 0 : 0) + 1
                if auditState.retries == nil { auditState.retries = [:] }
                auditState.retries?[job.id] = Retry(transition: transition, failures: failures, after: now().addingTimeInterval(Self.retryDelay(failures)))
                try? saveAuditState()
                recordError(job.id, error)
                if seen[job.id] == event.key { seen[job.id] = nil }
            }
        }
    }

    static func retryDelay(_ failures: Int) -> TimeInterval {
        min(3600, 60 * pow(2, Double(min(max(0, failures - 1), 6))))
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

    private func write(_ args: [String], texts: [String], job: Job, action: String) async throws {
        // Arguments are outgoing data too, including label names, URLs and repository names.
        try await scan((texts + args).enumerated().map { ("issue sync \($0.offset)", $0.element) })
        do { _ = try await gh(args) }
        catch { throw Shell.Failure(message: args.first == "project" ? Self.projectError(error.localizedDescription) : error.localizedDescription) }
        let url = "https://github.com/\(job.repo)/issues/\(job.issue ?? 0)"
        let detail = action == "issueLabels" ? args.enumerated().compactMap { i, arg in ["--add-label", "--remove-label"].contains(arg) ? "\(arg) \(args[i + 1])" : nil }.joined(separator: ", ") : action
        let outgoing = Outgoing(action: .init(rawValue: action), repo: job.repo, id: "\(url) (\(detail))")
        if desk?.issueJobs.contains(where: { $0.id == job.id }) == true { desk?.recordIssueOutgoing(job.id, outgoing) }
        else {
            auditState.outgoing.append(outgoing)
            try saveAuditState()
        }
    }

    private func bodyFile(_ body: String, args: [String], job: Job, action: String) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "oby-issue-\(UUID().uuidString).md")
        try body.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        try await write(args + ["--body-file", file.path], texts: [body], job: job, action: action)
    }

    /// The job the issue's claim line names or, for an issue claimed before #162, the job its latest
    /// `Oby is working on …` comment names. Read only: nothing comments any more.
    private func claimant(_ row: [String: Any], number: Int, repo: String) async throws -> String? {
        if let id = Self.claimant(row["body"] as? String ?? "") { return id }
        let comments = try await json(["issue", "view", "\(number)", "-R", repo, "--json", "comments"]) as? [String: Any]
        return (comments?["comments"] as? [[String: Any]] ?? []).compactMap { comment in
            (comment["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                .wholeMatch(of: /Oby is working on .* \(job ([A-Za-z0-9._-]+)\)\./).map { String($0.1) }
        }.last
    }

    private func labels(_ row: [String: Any], status: String?, job: Job) async throws -> Bool {
        let current = Board.names(row["labels"], key: "name").filter { $0.hasPrefix("status:") }
        guard Set(current) != Set(status.map { [$0] } ?? []) else { return false }
        // Work on another Desk (the Mac's) is invisible here: only the Desk whose job claimed
        // the issue last takes its running or blocked status away; otherwise the labels stay.
        let held = ["status:in-progress", "status:blocked"]
        if !held.contains(status ?? ""), current.contains(where: held.contains) {
            guard let id = try await claimant(row, number: job.issue!, repo: job.repo), desk?.issueJobs.contains(where: { $0.id == id }) == true else { return false }
        }
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

    /// The roadmap's Status field has no option for the column an issue belongs in: the audit asks
    /// the owner what to do (#215). `options` are the columns it has.
    struct MissingStatus: LocalizedError {
        var column: String
        var options: [String]
        var errorDescription: String? { "Issue sync: roadmap has no Status option \(column)." }
    }

    private func board(status: String?, job: Job) async throws -> Bool {
        guard let status, let project = try await roadmap() else { return false }
        let url = "https://github.com/\(job.repo)/issues/\(job.issue!)"
        guard let item = project.items.first(where: { ($0["content"] as? [String: Any])?["url"] as? String == url }), let itemID = item["id"] as? String else { return false }
        let current = ((item["fieldValueByName"] as? [String: Any])?["name"] as? String)?.lowercased()
        guard !["done", "shipped", "closed"].contains(current ?? "") else { return false }
        var column = switch status { case "status:in-progress": "In progress"; case "status:in-review": "In review"; case "status:blocked": "Blocked"; default: "Needs test" }
        // What the owner chose for a column the roadmap lacks: another, or leave it where it is.
        if let choice = auditState.choices?[column.lowercased()] {
            guard let use = choice.use else { return false }
            column = use
        }
        if current == column.lowercased() { return false }
        guard let field = project.fields.first(where: { $0["name"] as? String == "Status" }), let fieldID = field["id"] as? String,
              let options = field["options"] as? [[String: Any]] else {
            throw Shell.Failure(message: "Issue sync: roadmap has no Status field.")
        }
        guard let option = options.first(where: { ($0["name"] as? String)?.lowercased() == column.lowercased() }), let optionID = option["id"] as? String else {
            throw MissingStatus(column: column, options: options.compactMap { $0["name"] as? String })
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
        if event.key.hasPrefix("start:") {
            let old = row["body"] as? String ?? ""
            let body = Self.claimed(old, by: job.id)
            if body != old {
                try await bodyFile(body, args: ["issue", "edit", "\(number)", "-R", job.repo], job: job, action: "issueClaim")
                row["body"] = body
            }
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
        // An older slice ending must not clear another slice's running/review status.
        let other = desk.issueJobs.filter { $0.id != job.id && $0.repo == job.repo && $0.issue == number && $0.reviewOf == nil }
        if !job.isActive && !job.waitsForAnswer && !job.needsYou, other.contains(where: { $0.isActive }) { status = "status:in-progress" }
        else if status == nil, other.contains(where: { $0.published != nil && ($0.pullRequest?.state ?? .open) == .open }) { status = "status:in-review" }
        else if status == nil, other.contains(where: { $0.pullRequest?.state == .merged }) { status = Self.remainingBuild(row["body"] as? String ?? "") ? "status:in-progress" : "status:needs-test" }
        _ = try await labels(row, status: status, job: job)
        _ = try await board(status: status, job: job)
        desk.clearIssueSyncError(job.id)
        if event.key.hasPrefix("start:") { desk.issueSyncError(job.id, "Claimed: labeled status:in-progress.") }
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

    private func loadState() {
        guard !stateLoaded else { return }
        if let data = try? Data(contentsOf: auditURL), let state = try? JSONDecoder().decode(AuditState.self, from: data) { auditState = state }
        stateLoaded = true
    }

    /// Called hourly by the runner; a separate ledger keeps quiet days out of the inbox.
    func audit(now: Date = .now) async {
        guard enabled else { return }
        await schedule(now: now, again: false).value
    }

    /// The audit again now, whatever day it is: Try again on its report, or a status decided.
    func again() {
        guard enabled else { return }
        schedule(now: now(), again: true)
    }

    @discardableResult
    private func schedule(now: Date, again: Bool) -> Task<Void, Never> {
        let previous = tail
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.auditRun(now: now, again: again)
        }
        tail = task
        return task
    }

    /// The owner's answer on a missing status's item: `use` that column for it from now on, or nil
    /// to leave its issues where they are. Remembered in `issue-audit.json`; a column chosen moves them now.
    func decide(_ item: String, use column: String?) throws {
        loadState()
        guard let status = auditState.asked?[item] else { throw Shell.Failure(message: "Oby no longer knows which status that was about.") }
        if auditState.choices == nil { auditState.choices = [:] }
        auditState.choices?[status.lowercased()] = Choice(use: column)
        auditState.asked?[item] = nil
        try saveAuditState()
        if column != nil { again() }
    }

    /// Add the column on a missing status's item (#215): the column joins the roadmap's Status
    /// field with every card keeping its status, then the audit runs again and moves its issues
    /// there. In turn with the other writes; throws when it couldn't, and the item still waits.
    func addColumn(for item: String) async throws {
        loadState()
        guard let column = auditState.asked?[item] else { throw Shell.Failure(message: "Oby no longer knows which status that was about.") }
        let previous = tail
        let task = Task { [weak self] () -> Result<Void, any Error> in
            await previous?.value
            guard let self else { return .failure(Shell.Failure(message: "Issue sync has stopped.")) }
            do { try await self.add(column); return .success(()) } catch { return .failure(error) }
        }
        tail = Task { _ = await task.value }
        try await task.value.get()
        auditState.asked?[item] = nil
        try saveAuditState()
        again()
    }

    /// One option of the roadmap's Status field, as `updateProjectV2Field` takes it back: with its
    /// id it stays the same option, so the cards on it keep their status; with none it's new.
    struct StatusOption: Equatable {
        var id: String?
        var name: String
        var color: String
        var description: String

        var input: [String: Any] {
            var input: [String: Any] = ["name": name, "color": color, "description": description]
            if let id { input["id"] = id }
            return input
        }
    }

    /// The Status field's options, in their order.
    private func statusOptions(_ field: String) async throws -> [StatusOption] {
        let query = "query($id:ID!){node(id:$id){... on ProjectV2SingleSelectField{options{id name color description}}}}"
        guard let root = try await json(["api", "graphql", "-f", "query=\(query)", "-f", "id=\(field)"]) as? [String: Any],
              let node = (root["data"] as? [String: Any])?["node"] as? [String: Any], let options = node["options"] as? [[String: Any]] else {
            throw Shell.Failure(message: "Issue sync: couldn't read the roadmap's Status options.")
        }
        return try options.map { option in
            guard let id = option["id"] as? String, let name = option["name"] as? String else { throw Shell.Failure(message: "Issue sync: a Status option has no id.") }
            return StatusOption(id: id, name: name, color: option["color"] as? String ?? "GRAY", description: option["description"] as? String ?? "")
        }
    }

    /// `updateProjectV2Field` keeps an option, and the cards on it, when the option goes back with
    /// its id: every option goes back with its id, in its order, and the new one, with none, after
    /// the column it stands in for (Needs test after In review), else last. Oby checks the ids
    /// kept by reading them back after: any old id that changed or moved is an error.
    nonisolated static func adding(_ column: String, to options: [StatusOption]) -> [StatusOption] {
        var list = options
        let after = closest(to: column, in: options.map(\.name)).flatMap { name in options.firstIndex { $0.name == name } }
        list.insert(StatusOption(id: nil, name: column, color: "GRAY", description: ""), at: after.map { $0 + 1 } ?? list.endIndex)
        return list
    }

    private func add(_ column: String) async throws {
        project = nil; projectRead = false
        defer { project = nil; projectRead = false }
        guard let project = try await roadmap() else { throw Shell.Failure(message: "Issue sync: there's no \(Lead.boardTitle) project to add \(column) to.") }
        guard let field = project.fields.first(where: { $0["name"] as? String == "Status" })?["id"] as? String else {
            throw Shell.Failure(message: "Issue sync: roadmap has no Status field.")
        }
        let before = try await statusOptions(field)
        guard !before.contains(where: { $0.name.lowercased() == column.lowercased() }) else { return }
        let mutation = "mutation($input:UpdateProjectV2FieldInput!){updateProjectV2Field(input:$input){projectV2Field{... on ProjectV2SingleSelectField{id}}}}"
        let request: [String: Any] = ["query": mutation, "variables": ["input": ["fieldId": field, "singleSelectOptions": Self.adding(column, to: before).map(\.input)]]]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), as: UTF8.self)
        let file = FileManager.default.temporaryDirectory.appending(path: "oby-project-\(UUID().uuidString).json")
        try body.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let args = ["api", "graphql", "--input", file.path]
        try await scan(([body] + args).enumerated().map { ("issue sync \($0.offset)", $0.element) })
        let answer = try await json(args) as? [String: Any]
        if let errors = answer?["errors"] as? [[String: Any]], !errors.isEmpty {
            throw Shell.Failure(message: "Issue sync: GitHub didn't add \(column): \(errors.compactMap { $0["message"] as? String }.joined(separator: "; "))")
        }
        auditState.outgoing.append(Outgoing(action: .init(rawValue: "projectField"), repo: project.owner, id: "\(Lead.boardTitle) Status: added \(column)"))
        try saveAuditState()
        let after = try await statusOptions(field)
        let ids = before.compactMap(\.id)
        let kept = before.allSatisfy { old in after.contains { $0.id == old.id && $0.name == old.name } } && after.compactMap(\.id).filter(ids.contains) == ids
        guard kept, after.contains(where: { $0.name.lowercased() == column.lowercased() }) else {
            Logger.jobs.error("issue sync: adding \(column, privacy: .public) changed the roadmap's Status options")
            throw Shell.Failure(message: "Issue sync: \(column) was sent to the roadmap, but its Status options didn't come back as they were. Check the cards' columns on the board.")
        }
        Logger.jobs.notice("issue sync: added \(column, privacy: .public) to the roadmap's Status field; every option kept its id")
    }

    /// What the owner chose for `column`, or nil while they haven't.
    func choice(for column: String) -> Choice? {
        loadState()
        return auditState.choices?[column.lowercased()]
    }

    /// The column to offer instead of a missing one: the nearest step before it that the roadmap
    /// has (Needs test → In review). Never Todo or a finished column, which the audit never sets.
    nonisolated static func closest(to column: String, in options: [String]) -> String? {
        let nearer = ["needs test": ["In review", "In progress"], "in review": ["In progress"], "blocked": ["In progress"]]
        for name in nearer[column.lowercased()] ?? [] {
            if let option = options.first(where: { $0.lowercased() == name.lowercased() }) { return option }
        }
        return nil
    }

    private func auditRun(now: Date, again: Bool = false) async {
        guard enabled, let desk else { return }
        let day = "issue-audit-\(Int(now.timeIntervalSince1970 / 86400))"
        loadState()
        guard again || auditState.day != day else { return }
        // Run again the same day, its report is another item.
        var auditID = day, count = 1
        while desk.item(auditID) != nil {
            count += 1
            auditID = "\(day)-\(count)"
        }
        if desk.repos.isEmpty { desk.repos = (try? await Workspace.knownRepos()) ?? [] }
        guard !desk.repos.isEmpty || !desk.issueJobs.isEmpty else { return }
        let outgoingBefore = Dictionary(desk.issueJobs.map { ($0.id, $0.outgoing?.count ?? 0) }, uniquingKeysWith: { _, last in last })
        let ledgerBefore = auditState.outgoing.count
        auditing = true; project = nil; projectRead = false
        defer { auditing = false; project = nil; projectRead = false }
        var changed = 0, failures: [String] = []
        // Columns the roadmap lacks, with the columns it has and the issues that belong there.
        var missing: [String: (options: [String], issues: [String])] = [:]
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
                        // Another Desk (including the Mac) may own work absent from this runner.
                        guard !related.isEmpty else { continue }
                        let pr = prs.first { pr in
                            let reference = Job(id: "pr", request: "", agent: "runner", account: "", repo: repo, branch: pr["headRefName"] as? String ?? "", base: nil, pr: nil, kind: .investigate, task: pr["body"] as? String ?? "", title: pr["title"] as? String)
                            return (pr["closingIssuesReferences"] as? [[String: Any]] ?? []).contains { $0["number"] as? Int == number && ($0["url"] as? String ?? "https://github.com/\(repo)/issues/\(number)") == "https://github.com/\(repo)/issues/\(number)" } || related.contains { $0.branch == pr["headRefName"] as? String } || Self.inferred(reference, issues: issues) == number
                        }
                        var job = related.first(where: { $0.isActive || $0.waitsForAnswer || $0.needsYou }) ?? related[0]
                        job.issue = number
                        var status = Self.event(job)?.status
                        if !job.isActive && !job.waitsForAnswer && !job.needsYou {
                            let merged = related.contains { $0.pullRequest?.state == .merged }
                            status = pr != nil ? "status:in-review" : merged ? (Self.remainingBuild(row["body"] as? String ?? "") ? "status:in-progress" : "status:needs-test") : (Board.names(row["labels"], key: "name").contains("status:needs-test") ? "status:needs-test" : nil)
                        }
                        let labeled = try await labels(row, status: status, job: job)
                        var moved = false
                        do { moved = try await board(status: status, job: job) }
                        catch let lacking as MissingStatus {
                            missing[lacking.column, default: (lacking.options, [])].issues.append("\(repo)#\(number)")
                        }
                        if labeled || moved { changed += 1 }
                    } catch { failures.append("\(repo)#\(number): \(error.localizedDescription)") }
                }
            } catch { failures.append(error.localizedDescription) }
        }
        let outgoing = desk.issueJobs.flatMap { Array(($0.outgoing ?? []).dropFirst(outgoingBefore[$0.id] ?? 0)) } + Array(auditState.outgoing.dropFirst(ledgerBefore))
        // A column the roadmap lacks needs the owner (#215): one decision per column, until they make it.
        var decisions: [InboxItem] = []
        for (column, lacking) in missing.sorted(by: { $0.key < $1.key }) {
            let id = "\(day)-status-\(Self.marker(column.lowercased()))"
            let title = Self.statusTitle(column)
            guard desk.item(id) == nil, !desk.inbox.contains(where: { $0.isOpen && $0.kind == .audit && $0.title == title }) else { continue }
            let text = "The roadmap's Status field has no \(column) option. Issues that belong there stay where they are: \(lacking.issues.sorted().joined(separator: ", "))."
            let safe = (try? desk.vault.forAgent(text)) ?? "The roadmap's Status field has no \(column) option."
            if auditState.asked == nil { auditState.asked = [:] }
            auditState.asked?[id] = column
            let (options, details) = Self.decision(column, instead: Self.closest(to: column, in: lacking.options))
            var item = InboxItem(id: id, kind: .audit, job: "", title: title, text: safe, options: options, details: details, created: now)
            // Adding the column is what the roadmap was missing.
            item.recommended = 0
            decisions.append(item)
        }
        // A decision nothing needs any more (the column was added, or no issue belongs there) is done by itself.
        let lacking = Set(missing.keys.map(Self.statusTitle))
        if roadmap != nil, failures.isEmpty {
            for item in desk.inbox where item.isOpen && item.kind == .audit && auditState.asked?[item.id] != nil && !lacking.contains(item.title) {
                auditState.asked?[item.id] = nil
                _ = try? desk.settle(item.id, .done)
            }
        }
        auditState.day = day
        do { try saveAuditState() } catch { failures.append("Couldn't save the audit ledger.") }
        if changed > 0 || !failures.isEmpty {
            let line = "Issue audit: fixed drift on \(changed) issue(s)." + (failures.isEmpty ? "" : " " + failures.joined(separator: "; ").replacingOccurrences(of: "\n", with: " "))
            let safe = (try? desk.vault.forAgent(line)) ?? "Issue audit failed: couldn't read the vault."
            // Drift it fixed by itself needs nothing from the user: that report arrives done, with
            // the reports (Desk.add). What failed can be tried again.
            desk.addIssueAudit(InboxItem(id: auditID, kind: .audit, job: "", title: Self.reportTitle, text: safe, options: failures.isEmpty ? [] : [Inbox.tryAgain],
                                         details: failures.isEmpty ? nil : ["Runs the audit again now, once what failed is fixed."],
                                         created: now, outgoing: outgoing.sorted { $0.date < $1.date }))
        }
        for decision in decisions { desk.addIssueAudit(decision) }
    }

    /// A missing column's answers and what each does, as Claude Code describes its options: Add
    /// the column (recommended, first), Use the nearest column instead when there's one, Ignore.
    nonisolated static func decision(_ column: String, instead: String?) -> (options: [String], details: [String]) {
        var list = [(Inbox.addColumn, "Adds \(column) to the roadmap's Status field, every card keeping its column, and moves these issues there.")]
        if let instead { list.append((Inbox.useInstead(instead), "Moves these issues to \(instead), now and whenever they'd go to \(column).")) }
        list.append((Inbox.ignoreStatus, "Leaves these issues where they are, and doesn't ask about \(column) again."))
        return (list.map(\.0), list.map(\.1))
    }

    nonisolated static let reportTitle = "Daily issue audit"
    /// The title of the decision about a column the roadmap lacks.
    nonisolated static func statusTitle(_ column: String) -> String { "Roadmap column \(column)" }
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
        if lists(id) { replace(latest) } else { issueSync.store.save(latest); onJobChange(latest) }
    }
    func recordIssueOutgoing(_ id: String, _ outgoing: Outgoing) {
        guard var latest = issueJobs.first(where: { $0.id == id }) else { return }
        latest.outgoing = (latest.outgoing ?? []) + [outgoing]
        if lists(id) { replace(latest) } else { issueSync.store.save(latest); onJobChange(latest) }
    }
    func issueSyncError(_ id: String, _ line: String) {
        guard var latest = issueJobs.first(where: { $0.id == id }) else { return }
        latest.claim = line
        if lists(id) { replace(latest) } else { issueSync.store.save(latest); onJobChange(latest) }
    }
    func clearIssueSyncError(_ id: String) {
        guard var latest = issueJobs.first(where: { $0.id == id }), latest.claim?.hasPrefix("Issue sync:") == true else { return }
        latest.claim = nil
        if lists(id) { replace(latest) } else { issueSync.store.save(latest); onJobChange(latest) }
    }
}
