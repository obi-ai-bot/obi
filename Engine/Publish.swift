import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Publishing a finished job as the user: push its branch and open a pull request, ready for
/// review. Guards, then a secret scan, then the approval; nothing touches the network before it.
/// A job that ends done with commits publishes by itself (the approval lets everything through);
/// a job whose publish failed is published by hand, with Touch ID on the Mac or a phone's
/// signature on the runner. Oby never merges, force-pushes or pushes to main for anyone.
nonisolated enum Publish {
    /// The secret scan found something: nothing goes out, and the job fails naming where.
    struct Blocked: LocalizedError {
        var findings: [Finding]
        var errorDescription: String? { Publish.blocked(by: findings) }
    }

    /// Something the scan found: where, and which rule. Never the secret itself.
    struct Finding: Hashable, Sendable, CustomStringConvertible {
        var file: String
        /// Nil when the file's name is the problem, like `.env`.
        var line: Int?
        var rule: String
        var description: String { "\(file)\(line.map { ":\($0)" } ?? "") (\(rule))" }
    }

    /// A line a diff adds, and where it lands in the new file.
    struct Line: Sendable {
        var file: String
        var number: Int
        var text: String
    }

    /// The one sentence a publish carries out: shown in the notch, the Touch ID reason, and what a phone signs.
    /// Once published, it pushes the new commits to the same branch, and `pullRequest` finds the open pull request.
    static func action(for job: Job, base: String) -> String {
        job.published == nil ? "Push \(job.branch) to \(job.repo) and open a pull request into \(base)."
            : "Push the new commits on \(job.branch) to \(job.repo), for its pull request into \(base)."
    }

    /// Guards, secret scan (`Blocked` when it finds something), `approve` with the action, push,
    /// pull request. The first refusal stops it with one line the notch can show. Returns the pull
    /// request's URL. `approve` is `{ _ in }` when a job publishes by itself.
    static func publish(_ job: Job, base: String, approve: (String) async throws -> Void) async throws -> URL {
        let worktree = Workspace.worktree(job.id)
        let git = { (arguments: [String]) in try? await Shell.ok(["git", "-C", worktree.path] + arguments) }
        let defaultBranch = await git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]).map { String($0.dropFirst("origin/".count)) }
        if let refusal = refusal(job, base: base, defaultBranch: defaultBranch) { throw Shell.Failure(message: refusal) }
        // One commit from here on, so nothing added after the scan gets pushed.
        guard let head = await git(["rev-parse", "--verify", "HEAD^{commit}"]) else {
            throw Shell.Failure(message: "Not published: can't read \(job.branch) in the job's worktree.")
        }
        if await git(["rev-list", "--count", "refs/remotes/origin/\(base)..\(head)"]) == "0" {
            throw Shell.Failure(message: "Nothing to publish: \(job.branch) has no commits that aren't on \(base).")
        }
        let findings = try await scan(worktree, base: base, head: head)
        if !findings.isEmpty { throw Blocked(findings: findings) }
        try await approve(action(for: job, base: base))
        let subjects = await git(["log", "--reverse", "--no-merges", "--format=%s", "refs/remotes/origin/\(base)..\(head)"]) ?? ""
        try await push(head, of: job, from: worktree)
        return try await pullRequest(job, base: base, subjects: subjects.split(separator: "\n").map(String.init))
    }

    /// Why Oby won't publish this job, or nil to go ahead.
    static func refusal(_ job: Job, base: String, defaultBranch: String?) -> String? {
        let branch = job.branch
        if !branch.hasPrefix("oby/") || !Plan.isBranchName(branch) { return "Oby only publishes its own oby/ branches, not \(branch)." }
        if !Plan.isBranchName(base) { return "\(base) isn't a branch name." }
        if branch == base { return "\(branch) can't be its own base." }
        if ["main", "master", defaultBranch].contains(branch) { return "Oby never pushes to \(branch)." }
        if job.repo.wholeMatch(of: /[A-Za-z0-9-]+\/[A-Za-z0-9._-]+/) == nil || job.repo.contains("..") { return "\(job.repo) isn't a GitHub repository." }
        return nil
    }

    // MARK: Secret scan

    /// The built-in scanner's rules, matched against each added line.
    static let rules: [(name: String, pattern: Regex<Substring>)] = [
        ("private key", /-----BEGIN [A-Z ]*PRIVATE KEY/),
        ("AWS access key", /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/),
        ("GitHub token", /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}|\bgithub_pat_[A-Za-z0-9_]{60,}/),
        ("Slack token", /\bxox[abeoprs]-[A-Za-z0-9-]{10,}/),
        ("OpenAI key", /\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,}|\bsk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}/),
        ("Anthropic key", /\bsk-ant-[a-z]+[0-9]{2}-[A-Za-z0-9_-]{20,}/),
        ("Stripe live key", /\b(?:sk|rk)_live_[A-Za-z0-9]{20,}/),
        ("password or secret", /(?i)(?:password|passwd|secret|api_?key|access_?key|access_?token|auth_?token|private_?key)["']?\s*(?::?=|=>|:)\s*["'][^"'\s]{12,}["']/),
    ]

    /// A file that holds secrets by its name alone.
    static func secretFile(_ path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if name == ".env" || name.hasPrefix(".env.") && ![".env.example", ".env.sample", ".env.template"].contains(name) { return ".env file" }
        if ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"].contains(name) || name.hasSuffix(".p12") || name.hasSuffix(".pfx") { return "private key file" }
        return nil
    }

    /// The files a `git diff` or `git log -p` touches, and the lines it adds.
    static func parse(_ diff: String) -> (files: [String], lines: [Line]) {
        var files: [String] = [], lines: [Line] = []
        var file = "", number = 0, inHunk = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                let names = line.replacing("\"", with: "")
                file = names.range(of: " b/", options: .backwards).map { String(names[$0.upperBound...]) } ?? String(names)
                files.append(file)
                inHunk = false
            } else if let hunk = line.prefixMatch(of: /@@ -\d+(?:,\d+)? \+(\d+)/) {
                number = Int(hunk.1) ?? 0
                inHunk = true
            } else if inHunk, line.hasPrefix("+") {
                lines.append(Line(file: file, number: number, text: String(line.dropFirst())))
                number += 1
            } else if inHunk, line.hasPrefix(" ") {
                number += 1
            }
        }
        return (files, lines)
    }

    /// What the built-in scanner finds in a diff, each place once.
    static func findings(inDiff diff: String) -> [Finding] {
        let (files, lines) = parse(diff)
        let named = files.compactMap { file in secretFile(file).map { Finding(file: file, line: nil, rule: $0) } }
        let found = lines.flatMap { line in
            rules.filter { line.text.contains($0.pattern) }.map { Finding(file: line.file, line: line.number, rule: $0.name) }
        }
        var seen = Set<Finding>()
        return (named + found).filter { seen.insert($0).inserted }
    }

    /// Scans what publishing would send: each commit up to `head` that isn't on origin/<base>,
    /// and the diff they add up to. If the scan can't run, it throws and nothing is published.
    static func scan(_ worktree: URL, base: String, head: String = "HEAD") async throws -> [Finding] {
        // --text and --no-textconv: no attribute or driver can hide what the push sends.
        let options = ["--no-color", "--no-ext-diff", "--no-textconv", "--text", "--diff-filter=d", "--src-prefix=a/", "--dst-prefix=b/"]
        let since = "refs/remotes/origin/\(base)"
        let diff: String
        do {
            let commits = try await Shell.ok(["git", "-C", worktree.path, "log", "-p", "--no-merges", "--format="] + options + ["\(since)..\(head)"])
            let total = try await Shell.ok(["git", "-C", worktree.path, "diff"] + options + ["\(since)...\(head)"])
            diff = commits + "\n" + total
        } catch {
            throw Shell.Failure(message: "Not published: the secret scan couldn't read the changes (\(error.localizedDescription)).")
        }
        return findings(inDiff: diff) + (try await gitleaks(parse(diff).lines))
    }

    /// gitleaks on the same added lines when it's installed. The built-in scanner runs either way.
    static func gitleaks(_ lines: [Line]) async throws -> [Finding] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-gitleaks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let added = folder.appending(path: "added.txt"), report = folder.appending(path: "report.json")
        try lines.map(\.text).joined(separator: "\n").write(to: added, atomically: true, encoding: .utf8)
        let result = try await Shell.run(["gitleaks", "dir", added.path, "--no-banner", "--redact", "--exit-code=99",
                                          "--report-format=json", "--report-path=\(report.path)"], timeout: 120)
        switch result.status {
        case 0, 127: return []  // 127: /usr/bin/env found no gitleaks.
        case 99:
            let leaks = (try? JSONSerialization.jsonObject(with: Data(contentsOf: report))) as? [[String: Any]] ?? []
            if leaks.isEmpty { return [Finding(file: "?", line: nil, rule: "gitleaks")] }
            return leaks.map { leak in
                let line = (leak["StartLine"] as? Int).flatMap { lines.indices.contains($0 - 1) ? lines[$0 - 1] : nil }
                return Finding(file: line?.file ?? "?", line: line?.number, rule: "gitleaks \(leak["RuleID"] as? String ?? "")")
            }
        default:
            throw Shell.Failure(message: "Not published: gitleaks couldn't run (\(said(result.err))).")
        }
    }

    /// One line for the notch: where the scan found secrets, never the secrets.
    static func blocked(by findings: [Finding]) -> String {
        let more = findings.count > 3 ? " and \(findings.count - 3) more" : ""
        return "Not published: possible secret in " + findings.prefix(3).map(\.description).joined(separator: ", ") + more + "."
    }

    // MARK: Approval, push and pull request

    #if canImport(LocalAuthentication)
    /// Touch ID, or the password on Macs without it, with the action as the reason.
    static func touchID(_ action: String) async throws {
        // macOS shows "Oby is trying to <reason>.", so the sentence goes in lowercase, without its period.
        let reason = action.prefix(1).lowercased() + action.dropFirst().dropLast(action.hasSuffix(".") ? 1 : 0)
        guard (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else {
            throw Shell.Failure(message: "Not published: Touch ID didn't approve it.")
        }
    }
    #endif

    /// Pushes one commit to the job's own branch, never with --force. The agent could have changed
    /// the clone's config, so no hooks, tags, submodules or signing programs, and only gh signs in.
    static func push(_ commit: String, of job: Job, from worktree: URL) async throws {
        let result = try await Shell.run(
            ["git", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
             "push", "--no-follow-tags", "--no-signed", "--recurse-submodules=no",
             "https://github.com/\(job.repo).git", "\(commit):refs/heads/\(job.branch)"],
            in: worktree, env: ["GIT_TERMINAL_PROMPT": "0"])
        guard result.status == 0 else { throw Shell.Failure(message: "Couldn't push \(job.branch): \(said(result.err))") }
    }

    /// Opens the pull request, ready for review, or returns the one already open for the branch
    /// with its description brought up to date (a later round's summary and check).
    static func pullRequest(_ job: Job, base: String, subjects: [String]) async throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "oby-pr-\(UUID().uuidString).md")
        try body(for: job).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let open = try await Shell.ok(["gh", "pr", "list", "-R", job.repo, "--head", job.branch, "--state", "open",
                                       "--json", "url", "--jq", ".[0].url // empty"])
        if !open.isEmpty, let url = URL(string: open) {
            // The commits are on it already; a description that didn't update isn't worth failing for.
            _ = try? await Shell.ok(["gh", "pr", "edit", open, "-R", job.repo, "--body-file", file.path])
            return url
        }
        let created = try await Shell.ok(["gh", "pr", "create", "-R", job.repo, "--base", base, "--head", job.branch,
                                          "--title=\(title(for: job, subjects: subjects))", "--body-file", file.path])
        guard let url = created.split(separator: "\n").last.flatMap({ URL(string: String($0)) }) else {
            throw Shell.Failure(message: "gh opened no pull request: \(created)")
        }
        return url
    }

    /// The pull request's title in Conventional Commits form, ending with `(#issue)` when there is
    /// one: the first commit subject that's already in that form, else the job's kind and the
    /// agent's first line.
    static func title(for job: Job, subjects: [String]) -> String {
        let conventional = /^([a-z]+)(\([^()]+\))?!?: \S.*/
        var title = subjects.lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.wholeMatch(of: conventional) != nil }
        if title == nil {
            let type = switch job.kind { case .build: "feat"; case .fix: "fix"; case .test: "test"; default: "chore" }
            let said = (job.summaries?.last ?? job.summary).split(separator: "\n").first.map(String.init) ?? ""
            var line = said.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            // "Fixed the thing" reads "fixed the thing" after the colon; "iOS" and "API" stay as they are.
            if let first = line.first, first.isUppercase, !(line.dropFirst().first?.isUppercase ?? false) {
                line = first.lowercased() + line.dropFirst()
            }
            title = "\(type): \(line.isEmpty ? job.title : line)"
        }
        var text = title ?? job.title
        // The issue goes last, once: a subject may carry one already.
        text = text.replacing(/\s*\(#\d+\)$/, with: "")
        let issue = job.issue.map { " (#\($0))" } ?? ""
        if text.count + issue.count > 100 { text = text.prefix(99 - issue.count) + "…" }
        return text + issue
    }

    /// The pull request's description: every round's summary, what the user asked for, the check
    /// and the scan, `Closes #N`, and that Oby opened it. The agent's summaries are untrusted (it
    /// may have read someone else's pull request), so they go in as code blocks: no mentions,
    /// links or closing keywords.
    static func body(for job: Job) -> String {
        let summaries = job.summaries.flatMap { $0.isEmpty ? nil : $0 } ?? [job.summary]
        let rounds = summaries.enumerated().map { index, summary in
            let fence = String(repeating: "`", count: max(3, (summary.matches(of: /`+/).map(\.output.count).max() ?? 0) + 1))
            let label = summaries.count == 1 ? "The agent's summary:" : "Round \(index + 1), the agent's summary:"
            return "\(label)\n\n\(fence)\n\(summary)\n\(fence)"
        }
        let request = job.request.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        let check = job.check.map { "- Check: \(code($0)) passed." } ?? "- Check: none, the job had no check."
        return """
            \(rounds.joined(separator: "\n\n"))

            What the user asked for:

            \(request)

            \(check)
            - Secret scan: clean.\(job.issue.map { "\n\nCloses #\($0)" } ?? "")

            by Oby: Oby opened this pull request after the check passed and the secret scan was clean. A person reviews it before it merges.
            """
    }

    /// Text as inline code, whatever backticks it holds.
    static func code(_ text: String) -> String {
        let ticks = String(repeating: "`", count: (text.matches(of: /`+/).map(\.output.count).max() ?? 0) + 1)
        return "\(ticks) \(text) \(ticks)"
    }

    /// The last thing a tool said on stderr, skipping git's hints.
    private static func said(_ err: String) -> String {
        err.split(separator: "\n").last { !$0.hasPrefix("hint:") }.map(String.init) ?? "no reason given"
    }
}
