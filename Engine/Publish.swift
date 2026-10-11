import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Publishing a finished job as the user: push its branch and open a pull request, ready for
/// review. Guards, then a secret scan, then the approval; nothing is sent before it (only the base is fetched).
/// A job that ends done with commits publishes by itself (the approval lets everything through);
/// a job whose publish failed is published by hand, with Touch ID on the Mac or a phone's
/// signature on the runner. Oby never force-pushes or pushes to main for anyone; it merges only
/// into dev, after its review and the Mac check (Engine/Checks.swift).
nonisolated enum Publish {
    /// The secret scan found something: nothing goes out, and the job fails naming where.
    struct Blocked: LocalizedError {
        var findings: [Finding]
        var errorDescription: String? { Publish.blocked(by: findings) }
    }

    /// Every commit the job would push is on its base already, compared by patch (a squash merge
    /// changes their hashes): publishing would open a pull request for merged work.
    struct AlreadyOnBase: LocalizedError {
        var base: String
        var errorDescription: String? { "Not published: its commits are already on \(base)." }
    }

    /// Something the scan found: where, and which rule. Never the secret itself.
    struct Finding: Hashable, Sendable, CustomStringConvertible {
        var file: String
        /// Nil when the file's name is the problem, like `.env`.
        var line: Int?
        var rule: String
        var description: String { "\(file)\(line.map { ":\($0)" } ?? "") (\(rule))" }

        /// With the vault's secrets taken out of the file's name.
        func redacted(by leaks: Leaks) -> Finding {
            leaks.isEmpty ? self : Finding(file: leaks.redact(file), line: line, rule: rule)
        }
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

    /// The job was stopped while it published: nothing more goes out.
    struct Stopped: LocalizedError {
        var errorDescription: String? { "Not published: the job was stopped." }
    }

    /// What publishing tells the desk as it goes, and asks it before each thing it sends.
    struct Hooks {
        /// The step it's on, for the job's pipeline.
        var progress: (PublishStep) -> Void = { _ in }
        /// Throws (`Stopped`) when nothing more may go out: asked right before the push and the pull request.
        var proceed: () throws -> Void = {}
        /// Something just went out, for the job's report.
        var sent: (Outgoing) -> Void = { _ in }
    }

    /// Guards, the commits compared with the base by patch (`AlreadyOnBase` when they're all on it),
    /// secret scan of the changes, the commit messages and the pull request's title and description
    /// (`Blocked` when it finds something), `approve` with the action, push, pull request. The first
    /// refusal stops it with one line the notch can show. Returns the pull request's URL. `approve`
    /// is `{ _ in }` when a job publishes by itself.
    static func publish(_ job: Job, base: String, hooks: Hooks = Hooks(),
                        approve: (String) async throws -> Void) async throws -> URL {
        let progress = hooks.progress
        progress(.scan)
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
        // The base as GitHub has it now: work merged since the job started counts as merged.
        try? await fetch(base, of: job, into: worktree)
        guard let left = await unmerged(worktree, base: base, head: head) else {
            throw Shell.Failure(message: "Not published: can't compare \(job.branch) with \(base).")
        }
        if left == 0 { throw AlreadyOnBase(base: base) }
        let findings = try await scan(worktree, base: base, head: head)
        if !findings.isEmpty { throw Blocked(findings: findings) }
        // Everything else that goes out: every commit's message, merges too, and the pull request's title and description.
        guard let messages = await git(["log", "--format=%B", "refs/remotes/origin/\(base)..\(head)"]),
              let subjects = await git(["log", "--reverse", "--no-merges", "--format=%s", "refs/remotes/origin/\(base)..\(head)"]) else {
            throw Shell.Failure(message: "Not published: the secret scan couldn't read the commit messages.")
        }
        let title = title(for: job, subjects: subjects.split(separator: "\n").map(String.init))
        let texts = outgoing(job, messages: messages, title: title)
        let said: [Finding]
        do {
            said = try await scan(texts: texts)
        } catch {
            throw Shell.Failure(message: "Not published: the secret scan couldn't run (\(error.localizedDescription)).")
        }
        if !said.isEmpty { throw Blocked(findings: said) }
        try await approve(action(for: job, base: base))
        try hooks.proceed()
        progress(.push)
        try await push(head, of: job, from: worktree)
        hooks.sent(Outgoing(action: .push, repo: job.repo, id: head, branch: job.branch))
        try hooks.proceed()
        progress(.pullRequest)
        let (url, sent) = try await pullRequest(job, base: base, title: title)
        if let sent { hooks.sent(Outgoing(action: sent, repo: job.repo, id: url.absoluteString)) }
        return url
    }

    /// Everything a publish sends besides the files: the branch's name, every commit's message, and
    /// the pull request's title and description.
    static func outgoing(_ job: Job, messages: String, title: String) -> [(name: String, text: String)] {
        [("branch name", job.branch), ("commit message", messages), ("pull request title", title), ("pull request description", body(for: job))]
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
                // A name with a tab, newline, quote or backslash in it, git writes quoted, with C escapes.
                if line.hasSuffix("\""), let quoted = line.range(of: " \"b/", options: .backwards) {
                    file = String(unquoted(line[line.index(after: quoted.lowerBound)...]).dropFirst(2))
                }
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

    /// A path as git quotes it (`"b/a\tb\303\251"`: C escapes, octal bytes), as it is.
    static func unquoted(_ quoted: Substring) -> String {
        guard quoted.count >= 2, quoted.first == "\"", quoted.last == "\"" else { return String(quoted) }
        var rest = Array(quoted.dropFirst().dropLast().utf8)[...]
        var bytes: [UInt8] = []
        let escapes: [UInt8: UInt8] = [UInt8(ascii: "t"): 9, UInt8(ascii: "n"): 10, UInt8(ascii: "r"): 13, UInt8(ascii: "a"): 7,
                                       UInt8(ascii: "b"): 8, UInt8(ascii: "f"): 12, UInt8(ascii: "v"): 11]
        let octal = UInt8(ascii: "0")...UInt8(ascii: "7")
        while let byte = rest.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = rest.popFirst() else { bytes.append(byte); continue }
            if octal.contains(next) {
                var value = Int(next - octal.lowerBound)
                for _ in 0..<2 {
                    guard let digit = rest.first, octal.contains(digit) else { break }
                    value = value * 8 + Int(digit - octal.lowerBound)
                    rest.removeFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            } else {
                bytes.append(escapes[next] ?? next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// What the built-in scanner finds in a diff, each place once, with the vault's secrets in `leaks`:
    /// in the lines it adds, and in the names of the files it touches. A file's name with a secret
    /// in it is shown redacted.
    static func findings(inDiff diff: String, leaks: Leaks = .empty) -> [Finding] {
        let (files, lines) = parse(diff)
        let named = files.flatMap { file in
            [secretFile(file)].compactMap { $0 }.map { Finding(file: file, line: nil, rule: $0) }
                + leaks.found(in: file).map { Finding(file: file, line: nil, rule: "\($0) in the file's name") }
        }
        let found = lines.flatMap { line in matches(line.text, leaks: leaks).map { Finding(file: line.file, line: line.number, rule: $0) } }
        var seen = Set<Finding>()
        return (named + found + wrapped(lines, leaks: leaks) + spanning(lines, leaks: leaks))
            .map { $0.redacted(by: leaks) }
            .filter { seen.insert($0).inserted }
    }

    /// Vault secrets whose value spans lines, posted as they are: runs of adjacent lines in one
    /// file, joined, and found at the line the value starts on.
    static func spanning(_ lines: [Line], leaks: Leaks) -> [Finding] {
        guard leaks.spans else { return [] }
        var runs: [[Line]] = []
        for line in lines {
            if let last = runs.last?.last, last.file == line.file, last.number + 1 == line.number {
                runs[runs.count - 1].append(line)
            } else {
                runs.append([line])
            }
        }
        return runs.filter { $0.count > 1 }.flatMap { run in
            leaks.spanning(run.map(\.text)).map { Finding(file: run[$0.line].file, line: run[$0.line].number, rule: "vault secret \($0.name)") }
        }
    }

    /// Base64 or hex wrapped over several lines (`base64` and `openssl` wrap at 76 or 64): runs of
    /// adjacent lines in one file that hold nothing else, joined, with the end of the line before
    /// (`token = QUtJ…`), and found at the run's first line.
    static func wrapped(_ lines: [Line], leaks: Leaks = .empty) -> [Finding] {
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"',\\"))
        var found: [Finding] = []
        var run: [Line] = [], lead = ""
        func flush() {
            if run.count + (lead.isEmpty ? 0 : 1) > 1, let first = run.first {
                let joined = lead + run.map { $0.text.trimmingCharacters(in: trim) }.joined()
                found += matches(joined, leaks: leaks).map { Finding(file: first.file, line: first.number, rule: $0) }
            }
            run = []
            lead = ""
        }
        var previous: Line?
        for line in lines {
            let text = line.text.trimmingCharacters(in: trim)
            let encoded = !text.isEmpty && text.wholeMatch(of: /[A-Za-z0-9+\/=_-]+/) != nil
            let adjacent = previous.map { $0.file == line.file && $0.number + 1 == line.number } ?? false
            if encoded, adjacent, !run.isEmpty {
                run.append(line)
            } else {
                flush()
                if encoded {
                    run = [line]
                    // The first part may end the line before, after `=` or `:`.
                    if adjacent, let previous, let tail = previous.text.trimmingCharacters(in: trim).firstMatch(of: /[A-Za-z0-9+\/_-]{8,}$/) {
                        lead = String(tail.output)
                    }
                }
            }
            previous = line
        }
        flush()
        return found
    }

    /// The rules a line breaks, by name: in plain text, else in a base64, hex or URL-encoded copy
    /// ("GitHub token, base64"), and the vault's secrets it holds, first ("vault secret npm-token, hex").
    static func matches(_ text: String, leaks: Leaks = .empty) -> [String] {
        let vault = leaks.found(in: text)
        let plain = rules.filter { text.contains($0.pattern) }.map(\.name)
        guard plain.isEmpty else { return vault + plain }
        var seen = Set<String>()
        return vault + decoded(text).flatMap { how, text in
            rules.filter { text.contains($0.pattern) }.map { "\($0.name), \(how)" }
        }.filter { seen.insert($0).inserted }
    }

    /// The text's encoded runs, decoded: URL-encoding, base64 (standard or URL-safe) and hex, and
    /// what those hide in turn (`depth` levels), labelled like "base64" or "hex in base64".
    /// `keep` says which decoded texts are worth looking in: by default those a rule could match.
    static func decoded(_ text: String, depth: Int = 2, keep: (String) -> Bool = readable) -> [(how: String, text: String)] {
        guard depth > 0 else { return [] }
        var found: [(how: String, text: String)] = []
        // Each run of %XX on its own, so one stray % (`50%`) doesn't hide the rest of the line.
        if text.contains("%") {
            let plain = text.replacing(/(?:%[0-9A-Fa-f]{2})+/) { percent($0.output) }
            if plain != text { found.append(("URL-encoded", plain)) }
        }
        for run in text.matches(of: /[A-Za-z0-9+\/_-]{16,}={0,2}/) {
            if let plain = base64(run.output) { found.append(("base64", plain)) }
        }
        for run in text.matches(of: /[0-9A-Fa-f]{16,}/) {
            // An odd run has a stray digit at one end or the other.
            let tries = run.output.count.isMultiple(of: 2) ? [run.output] : [run.output.dropFirst(), run.output.dropLast()]
            found += tries.compactMap { hex($0).map { ("hex", $0) } }
        }
        // Hex written as escapes: \x41\x4b… or 0x41, 0x4b, …
        for run in text.matches(of: /(?:\\x[0-9A-Fa-f]{2}){8,}|(?:0x[0-9A-Fa-f]{2}[\s,]*){8,}/) {
            let digits = run.output.matches(of: /(?:\\x|0x)([0-9A-Fa-f]{2})/).map(\.output.1).joined()
            if let plain = hex(Substring(digits)) { found.append(("hex", plain)) }
        }
        // What a run of letters that isn't an encoding decodes to has no stretch a rule could match:
        // skipping it keeps long lines (minified code, lockfiles) quick.
        found = found.filter { keep($0.text) }
        return found + found.flatMap { how, plain in decoded(plain, depth: depth - 1, keep: keep).map { ("\($0.how) in \(how)", $0.text) } }
    }

    /// Text with 15 printable ASCII characters in a row: the shortest any rule matches.
    static func readable(_ text: String) -> Bool {
        var row = 0
        for byte in text.utf8 {
            row = (0x20...0x7E).contains(byte) ? row + 1 : 0
            if row >= 15 { return true }
        }
        return false
    }

    /// `%41%4B…` as text.
    static func percent(_ run: Substring) -> String {
        let bytes = run.split(separator: "%").compactMap { UInt8($0, radix: 16) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Base64, standard or URL-safe, padded or not, as text (bytes that aren't UTF-8 become �, so a
    /// secret inside binary still reads). Nil when it isn't base64.
    static func base64(_ run: Substring) -> String? {
        var text = String(run.prefix { $0 != "=" }).replacing("-", with: "+").replacing("_", with: "/")
        guard text.count % 4 != 1 else { return nil }
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Hex pairs as text, or nil when the run isn't whole bytes.
    static func hex(_ run: Substring) -> String? {
        guard run.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = run.startIndex
        while index < run.endIndex {
            let next = run.index(index, offsetBy: 2)
            guard let byte = UInt8(run[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// What the built-in rules find in text Oby is about to post (a pull request's title or
    /// description, a comment, commit messages), each line under `name`.
    static func findings(inText text: String, named name: String, leaks: Leaks = .empty) -> [Finding] {
        let lines = lines(of: text, named: name)
        var seen = Set<Finding>()
        return (lines.flatMap { line in matches(line.text, leaks: leaks).map { Finding(file: name, line: line.number, rule: $0) } }
                + wrapped(lines, leaks: leaks) + spanning(lines, leaks: leaks))
            .filter { seen.insert($0).inserted }
    }

    /// Text Oby is about to post, as numbered lines under `name`.
    static func lines(of text: String, named name: String) -> [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            Line(file: name, number: index + 1, text: String(line))
        }
    }

    /// Scans each text Oby is about to post, by name: the built-in rules, the vault's secrets, and
    /// gitleaks when it's installed. Throws when the scan can't run (the vault can't be read, too): then nothing goes out.
    static func scan(texts: [(name: String, text: String)], vault: Vault = .shared) async throws -> [Finding] {
        let leaks = try vault.leaks()
        let lines = texts.flatMap { lines(of: $0.text, named: $0.name) }
        let found = texts.flatMap { findings(inText: $0.text, named: $0.name, leaks: leaks) }
        var seen = Set<Finding>()
        return (found + (try await gitleaks(lines))).filter { seen.insert($0).inserted }
    }

    /// Scans what publishing would send: each commit up to `head` that isn't on origin/<base>,
    /// and the diff they add up to, for the built-in rules and the vault's secrets. If the scan
    /// can't run, it throws and nothing is published.
    static func scan(_ worktree: URL, base: String, head: String = "HEAD", vault: Vault = .shared) async throws -> [Finding] {
        let leaks: Leaks
        do {
            leaks = try vault.leaks()
        } catch {
            throw Shell.Failure(message: "Not published: the secret scan couldn't read the vault (\(error.localizedDescription)).")
        }
        // --text and --no-textconv: no attribute or driver can hide what the push sends.
        let options = ["--no-color", "--no-ext-diff", "--no-textconv", "--text", "--diff-filter=d", "--src-prefix=a/", "--dst-prefix=b/"]
        let since = "refs/remotes/origin/\(base)"
        let diff: String
        do {
            // Files' names as they are, not escaped, so the vault's secrets are found in them too.
            let git = ["git", "-C", worktree.path, "-c", "core.quotePath=false"]
            // A merge as what its author changed from git's own merge of its parents: content a merge
            // brings in that neither side had is pushed too, even if a later commit takes it out.
            let commits = try await Shell.ok(git + ["log", "-p", "--diff-merges=remerge", "--format="] + options + ["\(since)..\(head)"])
            let total = try await Shell.ok(git + ["diff"] + options + ["\(since)...\(head)"])
            diff = commits + "\n" + total
        } catch {
            throw Shell.Failure(message: "Not published: the secret scan couldn't read the changes (\(error.localizedDescription)).")
        }
        let blobs: [Finding]
        do {
            blobs = try await blobFindings(worktree, since: since, head: head, leaks: leaks)
        } catch {
            throw Shell.Failure(message: "Not published: the secret scan couldn't read the commits' files (\(error.localizedDescription)).")
        }
        // gitleaks names files as the diff does: a vault secret in a name is redacted there too.
        var seen = Set<Finding>()
        return (findings(inDiff: diff, leaks: leaks) + blobs.map { $0.redacted(by: leaks) }
                + (try await gitleaks(parse(diff).lines)).map { $0.redacted(by: leaks) }).filter { seen.insert($0).inserted }
    }

    /// The biggest file the vault scan reads whole; a bigger one is a finding, so it isn't pushed unscanned.
    static let biggestBlob = 32 << 20

    /// The vault's secrets in every file the push sends that `since` doesn't have, each read whole
    /// (every version, in every commit, merges too): a value over lines, next to a line that was
    /// there already, or one a merge brought in and a later commit took out, is in a file even when
    /// no hunk shows it. Throws when git can't say.
    static func blobFindings(_ worktree: URL, since: String, head: String, leaks: Leaks) async throws -> [Finding] {
        guard !leaks.isEmpty else { return [] }
        let git = ["git", "-C", worktree.path, "-c", "core.quotePath=false"]
        // "<sha> <path>" for every tree and file; a commit has no path.
        var paths: [String: String] = [:], order: [String] = []
        for line in try await Shell.ok(git + ["rev-list", "--objects", "\(since)..\(head)"]).split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let sha = String(line[..<space]), path = String(line[line.index(after: space)...])
            if !path.isEmpty, paths[sha] == nil {
                paths[sha] = path
                order.append(sha)
            }
        }
        guard !order.isEmpty else { return [] }
        let checked = try await Shell.run(git + ["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
                                          input: Data((order.joined(separator: "\n") + "\n").utf8))
        guard checked.status == 0 else { throw Shell.Failure(message: "git cat-file: \(checked.err)") }
        var findings: [Finding] = [], blobs: [String] = []
        for line in String(decoding: checked.out, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[1] == "blob", let size = Int(parts[2]), let path = paths[String(parts[0])] else { continue }
            if size > biggestBlob {
                findings.append(Finding(file: path, line: nil, rule: "too big for the vault scan"))
            } else {
                blobs.append(String(parts[0]))
            }
        }
        guard !blobs.isEmpty else { return findings }
        let read = try await Shell.run(git + ["cat-file", "--batch"], input: Data((blobs.joined(separator: "\n") + "\n").utf8))
        guard read.status == 0 else { throw Shell.Failure(message: "git cat-file: \(read.err)") }
        // Each: "<sha> blob <size>\n", the bytes, "\n".
        var rest = read.out[...]
        while let newline = rest.firstIndex(of: 10) {
            let header = String(decoding: rest[rest.startIndex..<newline], as: UTF8.self).split(separator: " ")
            guard header.count == 3, let size = Int(header[2]), let path = paths[String(header[0])] else {
                throw Shell.Failure(message: "git cat-file answered something else")
            }
            let start = rest.index(after: newline), end = start + size
            guard end < rest.endIndex else { throw Shell.Failure(message: "git cat-file stopped short") }
            findings += vaultFindings(inFile: String(decoding: rest[start..<end], as: UTF8.self), named: path, leaks: leaks)
            rest = rest[(end + 1)...]
        }
        return findings
    }

    /// The vault's secrets in a whole file: on each line, encoded and wrapped over lines, and
    /// values that span lines.
    static func vaultFindings(inFile text: String, named name: String, leaks: Leaks) -> [Finding] {
        let lines = lines(of: text, named: name)
        return lines.flatMap { line in leaks.found(in: line.text).map { Finding(file: name, line: line.number, rule: $0) } }
            + wrapped(lines, leaks: leaks).filter { $0.rule.hasPrefix("vault secret") }
            + spanning(lines, leaks: leaks)
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

    /// The agent could have changed the clone's config, so git talks to GitHub with no hooks, and only gh signs in.
    private static let toGitHub = ["git", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=",
                                   "-c", "credential.helper=!gh auth git-credential"]

    /// Pushes one commit to the job's own branch, never with --force: no tags, submodules or signing programs either.
    static func push(_ commit: String, of job: Job, from worktree: URL) async throws {
        let result = try await Shell.run(
            toGitHub + ["push", "--no-follow-tags", "--no-signed", "--recurse-submodules=no",
                        "https://github.com/\(job.repo).git", "\(commit):refs/heads/\(job.branch)"],
            in: worktree, env: ["GIT_TERMINAL_PROMPT": "0"])
        guard result.status == 0 else { throw Shell.Failure(message: "Couldn't push \(job.branch): \(said(result.err))") }
    }

    /// Brings origin/<base> up to date from GitHub, so what's merged since the job started counts.
    static func fetch(_ base: String, of job: Job, into worktree: URL) async throws {
        let result = try await Shell.run(
            toGitHub + ["fetch", "--quiet", "--no-tags", "--recurse-submodules=no",
                        "https://github.com/\(job.repo).git", "+refs/heads/\(base):refs/remotes/origin/\(base)"],
            in: worktree, env: ["GIT_TERMINAL_PROMPT": "0"], timeout: 120)
        guard result.status == 0 else { throw Shell.Failure(message: "Couldn't fetch \(base): \(said(result.err))") }
    }

    /// How many commits up to `head` aren't on origin/<base>, compared by patch, so a cherry-pick,
    /// a rebase or a squash merge counts as on it. Nil when git can't say.
    static func unmerged(_ worktree: URL, base: String, head: String = "HEAD") async -> Int? {
        let git = { (arguments: [String]) in try? await Shell.ok(["git", "-C", worktree.path] + arguments) }
        let since = "refs/remotes/origin/\(base)"
        // One line per commit: "-" when a commit with the same patch is on the base, "+" when not.
        guard let cherry = await git(["cherry", since, head]) else { return nil }
        let left = cherry.split(separator: "\n").count { $0.hasPrefix("+") }
        guard left > 0 else { return 0 }
        // A squash merge lands them all as one commit: then merging them into the base changes nothing.
        // A conflict (merge-tree fails) means they aren't all there.
        guard let merged = await git(["merge-tree", "--write-tree", since, head]),
              let tree = await git(["rev-parse", "\(since)^{tree}"]) else { return left }
        return merged.split(separator: "\n").first.map(String.init) == tree ? 0 : left
    }

    /// Opens the pull request, ready for review, or returns the one already open for the branch
    /// with its description brought up to date (a later round's summary and check). `sent` says
    /// which went out: `pullRequestEdit` only when the description did update.
    static func pullRequest(_ job: Job, base: String, title: String) async throws -> (url: URL, sent: Outgoing.Action?) {
        let file = FileManager.default.temporaryDirectory.appending(path: "oby-pr-\(UUID().uuidString).md")
        try body(for: job).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let open = try await Shell.ok(["gh", "pr", "list", "-R", job.repo, "--head", job.branch, "--state", "open",
                                       "--json", "url", "--jq", ".[0].url // empty"])
        if !open.isEmpty, let url = URL(string: open) {
            // The commits are on it already; a description that didn't update isn't worth failing for.
            let edited = (try? await Shell.ok(["gh", "pr", "edit", open, "-R", job.repo, "--body-file", file.path])) != nil
            return (url, edited ? .pullRequestEdit : nil)
        }
        let created = try await Shell.ok(["gh", "pr", "create", "-R", job.repo, "--base", base, "--head", job.branch,
                                          "--title=\(title)", "--body-file", file.path])
        guard let url = created.split(separator: "\n").last.flatMap({ URL(string: String($0)) }) else {
            throw Shell.Failure(message: "gh opened no pull request: \(created)")
        }
        return (url, .pullRequest)
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
            title = "\(type): \(line.isEmpty ? job.heading : line)"
        }
        var text = title ?? job.heading
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

            by Oby: Oby opened this pull request after the check passed and the secret scan was clean. Oby merges it into dev once its review approves and the checks on the user's Mac pass on the same commit.
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

/// Persisted publishing detail, independent of the agent's free-form step.
nonisolated enum PublishStep: String, Codable, Sendable {
    case scan, push, pullRequest
    var detail: String {
        switch self {
        case .scan: "Secret scan"
        case .push: "Secret scan clean · pushing commits"
        case .pullRequest: "Commits pushed · opening pull request"
        }
    }
}
