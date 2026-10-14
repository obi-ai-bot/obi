import Foundation
import Synchronization
import Testing
@testable import ObyEngine
@testable import oby_runner

// F17, secrets Oby uses but never shows (#60), slice one: the runner's vault file, the secret scan
// learning every value in each encoding, and values kept out of lists, errors and logs.

/// A vault in a folder of its own, and a value made at runtime, so this file holds no secret.
private func scratch() -> (vault: Vault, store: FileVault, folder: URL) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "oby-vault-\(UUID().uuidString)/vault")
    let store = FileVault(folder: folder)
    return (Vault(store: store), store, folder)
}

/// Characters every encoding treats differently: `/`, `+`, `=`, `?`, `&`, a space and a non-ASCII one.
private func secret() -> String { "tok/\(UUID().uuidString.prefix(12))+a=b?c&d é" }

private func status(_ url: URL) throws -> stat {
    var info = stat()
    try #require(lstat(url.path, &info) == 0)
    return info
}

private func mode(_ url: URL) throws -> mode_t { try status(url).st_mode & 0o777 }

/// Every encoded copy of `value` the scan and redaction must catch, by how it's labelled.
private func copies(of value: String) -> [(how: String, text: String)] {
    let data = Data(value.utf8)
    let hex = data.map { String(format: "%02x", $0) }.joined()
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return [
        ("", value),
        ("base64", data.base64EncodedString()),
        ("base64", Fake.base64URL(value)),
        // In the middle of a longer encoded string, at each offset.
        ("base64", Fake.base64("x" + value + "tail")),
        ("base64", Fake.base64("xy" + value)),
        ("base64", Fake.base64("TOKEN=" + value + "\n")),
        ("hex", hex),
        ("hex", hex.uppercased()),
        ("URL-encoded", value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""),
        ("URL-encoded", Fake.percent(value)),
        ("URL-encoded", Fake.percent(value).lowercased()),
        // As a form sends it, spaces as +.
        ("URL-encoded", (value.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: " "))) ?? "")
            .replacing(" ", with: "+")),
    ]
}

struct VaultStorageTests {
    @Test func theFileIsReadableOnlyByTheRunnersUser() throws {
        let (vault, store, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        #expect(try vault.names().isEmpty)
        let value = secret()
        try vault.add(value, as: "staging-api-key")
        #expect(try mode(folder) == 0o700)
        #expect(try mode(store.file) == 0o600)
        #expect(try status(store.file).st_uid == geteuid())
        // Saved in one rename: no copy left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["secrets.json"])
        #expect(try vault.use("staging-api-key") { $0 } == value)

        // Replaced and removed, still 0600.
        try vault.add("another-value-1234", as: "staging-api-key")
        try vault.add(secret(), as: "npm-token")
        #expect(try mode(store.file) == 0o600)
        #expect(try vault.names() == ["npm-token", "staging-api-key"])
        try vault.remove("staging-api-key")
        #expect(try vault.names() == ["npm-token"])
        #expect(try mode(store.file) == 0o600)
    }

    @Test func aVaultOthersCanReadIsntRead() throws {
        let (vault, store, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let value = secret()
        try vault.add(value, as: "npm-token")

        chmod(store.file.path, 0o644)
        var error = #expect(throws: Shell.Failure.self) { try FileVault(folder: folder).names() }
        #expect(error?.message.contains("mode 644") == true)
        #expect(error?.message.contains(value) == false)
        // Nor saved over: the scan can't run until it's fixed.
        #expect(throws: Shell.Failure.self) { try vault.add(secret(), as: "other-token") }
        #expect(throws: Shell.Failure.self) { try Vault(store: store).leaks() }
        chmod(store.file.path, 0o600)

        chmod(folder.path, 0o755)
        error = #expect(throws: Shell.Failure.self) { try FileVault(folder: folder).names() }
        #expect(error?.message.contains("chmod 700") == true)
        chmod(folder.path, 0o700)
        #expect(try FileVault(folder: folder).names() == ["npm-token"])

        // A link in place of the file isn't followed.
        let elsewhere = folder.deletingLastPathComponent().appending(path: "elsewhere.json")
        try FileManager.default.moveItem(at: store.file, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: elsewhere)
        #expect(throws: Shell.Failure.self) { try FileVault(folder: folder).names() }
    }

    @Test func namesAndValuesAreChecked() throws {
        let (vault, _, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        for name in ["", "has space", "new\nline", "../up", "-dash-first", String(repeating: "a", count: 65)] {
            #expect(throws: Shell.Failure.self, Comment(rawValue: name)) { try vault.add(secret(), as: name) }
        }
        let short = "abc1234"
        let error = #expect(throws: Shell.Failure.self) { try vault.add(short, as: "short") }
        #expect(error?.message.contains(short) == false)
        #expect(throws: Shell.Failure.self) { try vault.add("          ", as: "blank") }
        // A pasted value's trailing newline isn't part of it.
        try vault.add("pasted-value-123\n", as: "pasted")
        #expect(try vault.use("pasted") { $0 } == "pasted-value-123")
        #expect(throws: Shell.Failure.self) { try vault.use("missing") { $0 } }
    }

    /// The vault is in OBY_HOME, which every agent's bubblewrap covers; a bind that would show it again gets it covered too.
    @Test func agentsCantSeeTheVault() {
        let vault = Vault.folder.path
        #expect(vault.hasPrefix(Workspace.root.path))
        let args = Agents.sandboxed(["env"], in: nil, own: nil, bubblewrap: true)
        let hidden = args.indices.contains { args[$0] == "--tmpfs" && args.indices.contains($0 + 1) && args[$0 + 1] == Workspace.root.path }
        #expect(hidden)
        #expect(!args.contains(vault))
        let showing = Agents.sandboxed(["env"], in: nil, own: nil, reading: [Workspace.root.path], bubblewrap: true)
        let end = showing.firstIndex(of: "--") ?? showing.endIndex
        #expect(Array(showing[(end - 2)..<end]) == ["--tmpfs", vault])
    }
}

struct VaultScanTests {
    @Test func redactionTakesOutEveryEncoding() throws {
        let value = secret()
        let leaks = Leaks(["staging-api-key": value])
        for copy in copies(of: value) {
            let line = "curl -H 'Authorization: \(copy.text)' https://api.example.com"
            let redacted = leaks.redact(line)
            #expect(redacted.contains("[vault: staging-api-key]"), Comment(rawValue: copy.how))
            #expect(!redacted.contains(copy.text), Comment(rawValue: copy.how))
            #expect(redacted.hasPrefix("curl -H 'Authorization: ") && redacted.hasSuffix("' https://api.example.com"))
        }
        // A key over several lines: each line on its own too.
        let key = "line-one-of-the-key\nline-two-of-the-key"
        #expect(!Leaks(["deploy-key": key]).redact("got line-two-of-the-key").contains("line-two"))
        #expect(Leaks.empty.redact("nothing to take out") == "nothing to take out")
    }

    /// Whatever the scan finds, redaction takes out: partly URL-encoded, encoded twice, split over lines.
    @Test func redactionTakesOutWhatTheScanFinds() {
        let value = secret()
        let leaks = Leaks(["staging-api-key": value])
        let partly = value.replacing("/", with: "%2F").replacing("=", with: "%3d")
        let texts = [
            "curl 'https://api.example.com/?k=\(partly)' -v",
            "blob \(Fake.base64(Fake.hex(value))) end",
            "blob \(Fake.hex(Fake.base64(value))) end",
            "key = \(Fake.hex(value).chunks(2).map { "\\x\($0)" }.joined())",
            "multi\n\(value)\nlines",
            // Partly form-encoded: + for the space, %2B for the +, the rest as it is.
            "q=" + value.replacing("+", with: "%2B").replacing(" ", with: "+"),
            // Base64 wrapped over lines, as `base64` does, and its first part at the end of the line before.
            (["data: |"] + Fake.base64("export STAGING_KEY=" + value + "\n").chunks(16).map { "  " + $0 } + ["done"]).joined(separator: "\n"),
            (["token = \"" + Fake.base64(value + " tail").chunks(12)[0] + "\""] + Fake.base64(value + " tail").chunks(12).dropFirst().map { "\"" + $0 + "\"" }).joined(separator: "\n"),
        ]
        for text in texts {
            let vaultRules = { (text: String) in
                Publish.findings(inText: text, named: "log", leaks: leaks).filter { $0.rule.hasPrefix("vault secret") }
            }
            #expect(!vaultRules(text).isEmpty, Comment(rawValue: text))
            let redacted = leaks.redact(text)
            // Nothing the scan would find is left.
            #expect(leaks.hits(in: redacted).isEmpty, Comment(rawValue: redacted))
            #expect(vaultRules(redacted).isEmpty, Comment(rawValue: redacted))
            #expect(redacted.contains("[vault: staging-api-key]"), Comment(rawValue: redacted))
        }
        #expect(leaks.redact("blob \(Fake.base64(Fake.hex(value))) end") == "blob [vault: staging-api-key] end")
        // A value over lines, posted as it is, goes too.
        let lines = Leaks(["two-lines": "aaaa!\nbbbb?"])
        #expect(lines.hits(in: lines.redact("x aaaa!\nbbbb? y")).isEmpty)
    }

    @Test func everyEncodingIsBlockedNamingTheSecret() throws {
        let value = secret()
        let leaks = Leaks(["staging-api-key": value])
        for copy in copies(of: value) {
            let rule = "vault secret staging-api-key" + (copy.how.isEmpty ? "" : ", \(copy.how)")
            #expect(Publish.matches("data: \(copy.text)", leaks: leaks) == [rule], Comment(rawValue: copy.how))
        }
        // Encoded twice, and wrapped over lines as `base64` does.
        #expect(Publish.matches("blob \(Fake.base64(Fake.hex(value)))", leaks: leaks) == ["vault secret staging-api-key, hex in base64"])
        let wrapped = Fake.base64("export STAGING_KEY=" + value + "\nexport MORE=1\n" + String(repeating: "padding ", count: 8)).chunks(20)
        let text = (["config:"] + wrapped).joined(separator: "\n")
        #expect(Publish.findings(inText: text, named: "pull request description", leaks: leaks).contains {
            $0.line == 2 && $0.rule.hasPrefix("vault secret staging-api-key")
        })
        // Ordinary text isn't.
        for line in ["let token = vault.use(\"staging-api-key\")", Fake.base64("staging-api-key"), Fake.hex("tok/"), UUID().uuidString] {
            #expect(Publish.matches(line, leaks: leaks).isEmpty, Comment(rawValue: line))
        }
    }

    @Test func anOutgoingTextOrDiffWithASecretIsBlocked() async throws {
        let (vault, _, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let value = secret()
        try vault.add(value, as: "npm-token")
        let leaks = try vault.leaks()
        let findings = try await Publish.scan(texts: [("pull request title", "fix: the build"),
                                                      ("pull request description", "Done.\nUsed \(Fake.base64(value)) to test it."),
                                                      ("commit message", "fix: the build\n\n\(Fake.percent(value))")], vault: vault)
        #expect(findings.contains(Publish.Finding(file: "pull request description", line: 2, rule: "vault secret npm-token, base64")))
        #expect(findings.contains(Publish.Finding(file: "commit message", line: 3, rule: "vault secret npm-token, URL-encoded")))
        #expect(!findings.contains { $0.file == "pull request title" })
        // What the notch says names the secret and where, never the value.
        let said = Publish.blocked(by: findings)
        for copy in copies(of: value) { #expect(!said.contains(copy.text)) }
        #expect(said.contains("npm-token"))

        let diff = """
            diff --git a/test/setup.js b/test/setup.js
            --- a/test/setup.js
            +++ b/test/setup.js
            @@ -1,1 +1,2 @@
             const api = require('./api')
            +api.token = "\(Fake.hex(value))"
            """
        #expect(Publish.findings(inDiff: diff, leaks: leaks) == [Publish.Finding(file: "test/setup.js", line: 2, rule: "vault secret npm-token, hex")])

        // The vault learns a secret as it's added and forgets it as it's removed.
        let later = secret()
        try vault.add(later, as: "later-token")
        #expect(try await Publish.scan(texts: [("comment", "see \(later)")], vault: vault) == [Publish.Finding(file: "comment", line: 1, rule: "vault secret later-token")])
        try vault.remove("later-token")
        #expect(try await Publish.scan(texts: [("comment", "see \(later)")], vault: vault).isEmpty)
        // Added by `oby-runner vault add`, another process, while the service runs.
        let elsewhere = secret()
        try Vault(store: FileVault(folder: folder)).add(elsewhere, as: "added-elsewhere")
        #expect(try await Publish.scan(texts: [("comment", "see \(elsewhere)")], vault: vault)
                == [Publish.Finding(file: "comment", line: 1, rule: "vault secret added-elsewhere")])
    }

    /// A value over several lines, short lines and all, posted verbatim.
    @Test func aValueOverLinesIsBlocked() async throws {
        let leaks = Leaks(["two-lines": "aaaa!\nbbbb?"])
        #expect(Publish.findings(inText: "Notes:\naaaa!\nbbbb?\nend", named: "comment", leaks: leaks)
                == [Publish.Finding(file: "comment", line: 2, rule: "vault secret two-lines")])
        #expect(Publish.findings(inText: "aaaa! and\nbbbb? apart", named: "comment", leaks: leaks).isEmpty)
        let diff = """
            diff --git a/notes.txt b/notes.txt
            --- a/notes.txt
            +++ b/notes.txt
            @@ -4,1 +4,3 @@
             keep
            +aaaa!
            +bbbb?
            """
        #expect(Publish.findings(inDiff: diff, leaks: leaks) == [Publish.Finding(file: "notes.txt", line: 5, rule: "vault secret two-lines")])
        // With Windows line ends.
        #expect(!Leaks(["two-lines": "aaaa!\nbbbb?"]).hits(in: "aaaa!\r\nbbbb?").isEmpty)
    }

    /// A short value as \x or 0x escapes: decoded runs shorter than the built-in rules' 15 readable characters count too.
    @Test func aShortValueAsEscapesIsBlocked() {
        let value = "s3cr3t!x"
        let leaks = Leaks(["short-key": value])
        let escaped = Fake.hex(value).chunks(2).map { "\\x\($0)" }.joined()
        let bytes = Fake.hex(value).chunks(2).map { "0x\($0)" }.joined(separator: ", ")
        #expect(Publish.matches("let key = \"\(escaped)\"", leaks: leaks) == ["vault secret short-key, hex"])
        #expect(Publish.matches("char key[] = { \(bytes) };", leaks: leaks) == ["vault secret short-key, hex"])
        #expect(!leaks.redact("let key = \"\(escaped)\"").contains(escaped))
    }

    /// Git quotes a name with a tab in it, with C escapes: the name is read as it is.
    @Test func aQuotedFileNameIsReadAsItIs() {
        #expect(Publish.unquoted("\"b/caf\\303\\251 \\\"x\\\" a\\tb\\\\c\"") == "b/café \"x\" a\tb\\c")
        let leaks = Leaks(["tabbed": "tab\tsecret1"])
        let diff = """
            diff --git "a/notes/tab\\tsecret1.txt" "b/notes/tab\\tsecret1.txt"
            new file mode 100644
            --- /dev/null
            +++ "b/notes/tab\\tsecret1.txt"
            @@ -0,0 +1,1 @@
            +clean
            """
        #expect(Publish.findings(inDiff: diff, leaks: leaks)
                == [Publish.Finding(file: "notes/[vault: tabbed].txt", line: nil, rule: "vault secret tabbed in the file's name")])
    }

    /// A file named with a secret is blocked even when what's in it is clean, and the finding doesn't show the name as it is.
    @Test func aFileNamedWithASecretIsBlocked() {
        let leaks = Leaks(["short-key": "abcdefgh"])
        let diff = """
            diff --git a/abcdefgh.txt b/abcdefgh.txt
            new file mode 100644
            --- /dev/null
            +++ b/abcdefgh.txt
            @@ -0,0 +1,1 @@
            +nothing here
            """
        let findings = Publish.findings(inDiff: diff, leaks: leaks)
        #expect(findings == [Publish.Finding(file: "[vault: short-key].txt", line: nil, rule: "vault secret short-key in the file's name")])
        #expect(!Publish.blocked(by: findings).contains("abcdefgh"))
    }

    @Test func aVaultTheScanCantReadBlocksPublishing() async throws {
        let (vault, store, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try vault.add(secret(), as: "npm-token")
        // Learned first: the cache doesn't hide a vault others may read now.
        #expect(try await Publish.scan(texts: [("comment", "fine")], vault: vault).isEmpty)
        chmod(store.file.path, 0o640)
        await #expect(throws: Shell.Failure.self) { try await Publish.scan(texts: [("comment", "fine")], vault: vault) }
        chmod(folder.path, 0o750)
        chmod(store.file.path, 0o600)
        await #expect(throws: Shell.Failure.self) { try await Publish.scan(texts: [("comment", "fine")], vault: vault) }
        chmod(folder.path, 0o700)
        chmod(store.file.path, 0o640)
        let error = await #expect(throws: Shell.Failure.self) {
            try await Publish.scan(FileManager.default.temporaryDirectory, base: "main", vault: Vault(store: store))
        }
        #expect(error?.message.hasPrefix("Not published: the secret scan couldn't read the vault") == true)
    }

    /// gitleaks as the scan runs it, standing in for whatever this Mac has installed (its version,
    /// its rules): it keeps the text it was given to scan and finds nothing of its own.
    final class Gitleaks: Sendable {
        let scanned = Mutex<[String]>([])

        var stand: Shell.Stand {
            Shell.Stand { [self] arguments, _ in
                guard arguments.first == "gitleaks", let dir = arguments.firstIndex(of: "dir"), arguments.indices.contains(dir + 1) else {
                    throw Shell.Failure(message: "Unexpected command \(arguments.first ?? "")")
                }
                let text = try String(contentsOf: URL(filePath: arguments[dir + 1]), encoding: .utf8)
                scanned.withLock { $0.append(text) }
                return Shell.Output(status: 0, out: Data(), err: "")
            }
        }
    }

    /// The squash commit Oby writes is scanned right before the merge, with the vault as it is then,
    /// and the merge stops when the scan finds something or can't run. gitleaks stands in, so the
    /// findings are the built-in rules' and the vault's whichever gitleaks this Mac has, and it
    /// still has to be given the squash commit's title and message.
    @Test func theSquashCommitIsScannedBeforeTheMerge() async throws {
        let (vault, store, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let gitleaks = Gitleaks()
        try await Shell.$stand.withValue(gitleaks.stand) {
            try await MacCheck.scan(("fix: the login (#3) (#4)", "* fix: the login (#3)"), vault: vault)
            // A title someone edited on GitHub after publishing.
            let titled = await #expect(throws: Shell.Failure.self) {
                try await MacCheck.scan(("fix: \(Fake.aws) (#4)", "* fix: the login"), vault: vault)
            }
            #expect(titled?.message == "possible secret in squash commit title:1 (AWS access key).")
            // A secret the vault learned after publishing.
            let later = secret()
            try vault.add(later, as: "later-token")
            let messaged = await #expect(throws: Shell.Failure.self) {
                try await MacCheck.scan(("fix: the login (#4)", "* fix: the login\n\nUsed \(later)"), vault: vault)
            }
            #expect(messaged?.message == "possible secret in squash commit message:3 (vault secret later-token).")
            #expect(messaged?.message.contains(later) == false)
            // gitleaks was given each squash commit's title and message.
            #expect(gitleaks.scanned.withLock { $0 } == ["fix: the login (#3) (#4)\n* fix: the login (#3)",
                                                         "fix: \(Fake.aws) (#4)\n* fix: the login",
                                                         "fix: the login (#4)\n* fix: the login\n\nUsed \(later)"])
            // A vault the scan can't read.
            chmod(store.file.path, 0o640)
            let unread = await #expect(throws: Shell.Failure.self) { try await MacCheck.scan(("fix: the login (#4)", ""), vault: vault) }
            #expect(unread?.message.hasPrefix("the secret scan of the squash commit couldn't run") == true)
            chmod(store.file.path, 0o600)
        }
    }

    /// GitHub and gitleaks as `MacCheck.merge` meets them, every call kept in the order it came:
    /// pull request #152 titled `title`, open into dev with the checked head, one commit, no Xcode
    /// Cloud checks, and a merge and a branch delete that work. gitleaks keeps the text it was
    /// given and answers `gitleaks`: 0 finds nothing, 99 finds a generic API key on line 1 (as its
    /// JSON report says), anything else is gitleaks failing to run.
    final class Merging: Sendable {
        static let pull = "repos/deskree-inc/oby/pulls/152"
        let title: String
        let gitleaks: Int32
        let calls = Mutex<[[String]]>([])
        let scanned = Mutex<[String]>([])

        init(title: String, gitleaks: Int32 = 0) {
            self.title = title
            self.gitleaks = gitleaks
        }

        var job: Job {
            var job = Job(id: "merge-151", request: "Fix #151", agent: "claude", account: "default", repo: "deskree-inc/oby",
                          branch: "oby/fix-151", base: "dev", pr: nil, kind: .fix, task: "Fix #151")
            job.published = "https://github.com/deskree-inc/oby/pull/152"
            return job
        }

        var check: MacCheck { MacCheck.make(for: job, pr: 152, head: CheckTests.head) }

        var put: [String]? { calls.withLock { $0 }.first { $0.starts(with: ["gh", "api", "-X", "PUT"]) } }

        var stand: Shell.Stand {
            Shell.Stand { [self] arguments, _ in
                calls.withLock { $0.append(arguments) }
                if arguments.first == "gitleaks", let dir = arguments.firstIndex(of: "dir"), arguments.indices.contains(dir + 1) {
                    let text = try String(contentsOf: URL(filePath: arguments[dir + 1]), encoding: .utf8)
                    scanned.withLock { $0.append(text) }
                    if gitleaks == 99, let report = arguments.first(where: { $0.hasPrefix("--report-path=") }) {
                        try Data(#"[{"RuleID":"generic-api-key","StartLine":1}]"#.utf8)
                            .write(to: URL(filePath: String(report.dropFirst("--report-path=".count))))
                    }
                    return Shell.Output(status: gitleaks, out: Data(), err: gitleaks == 0 || gitleaks == 99 ? "" : "gitleaks: config not found")
                }
                let view = #"{"title":"\#(title)","state":"open","merged":false,"base":{"ref":"dev"},"head":{"sha":"\#(CheckTests.head)","ref":"oby/fix-151","repo":{"full_name":"deskree-inc/oby"}}}"#
                let said: String = switch Array(arguments.prefix(3)) {
                case ["gh", "api", Self.pull]: view
                case ["gh", "api", "\(Self.pull)/commits?per_page=100"]: #"[{"commit":{"message":"fix: the login\n\nChecked on the Mac"}}]"#
                case ["gh", "api", "repos/deskree-inc/oby/commits/\(CheckTests.head)/check-runs?per_page=100"]: #"[{"check_runs":[]}]"#
                case ["gh", "api", "-X"]: "{}"
                default: throw Shell.Failure(message: "Unexpected command \(arguments.prefix(3).joined(separator: " "))")
                }
                return Shell.Output(status: 0, out: Data(said.utf8), err: "")
            }
        }

        /// Runs the merge with GitHub and gitleaks standing in; what it threw, if anything.
        func merge() async -> Error? {
            do {
                try await Shell.$stand.withValue(stand) { try await MacCheck.merge(job, check) }
                return nil
            } catch {
                return error
            }
        }
    }

    /// The merge itself scans the squash commit it is about to write, title and message, with
    /// gitleaks among the scanners, before it asks GitHub to merge; and asks for no merge when the
    /// scan finds something, from the built-in rules or from gitleaks, or can't run.
    @Test func theMergeScansTheSquashCommitBeforeAskingGitHub() async throws {
        let clean = Merging(title: "fix: the login")
        #expect(await clean.merge() == nil)
        let calls = clean.calls.withLock { $0 }
        let scan = try #require(calls.firstIndex { $0.first == "gitleaks" })
        let put = try #require(calls.firstIndex { $0.starts(with: ["gh", "api", "-X", "PUT"]) })
        #expect(scan < put)
        // What was scanned is what GitHub is asked to write.
        #expect(clean.scanned.withLock { $0 } == ["fix: the login (#152)\nChecked on the Mac"])
        #expect(clean.put == ["gh", "api", "-X", "PUT", "\(Merging.pull)/merge", "-f", "merge_method=squash", "-f", "sha=\(CheckTests.head)",
                              "-f", "commit_title=fix: the login (#152)", "-f", "commit_message=Checked on the Mac"])

        // A title someone edited on GitHub after publishing: the built-in rules find it.
        let titled = Merging(title: "fix: \(Fake.aws)")
        #expect((await titled.merge() as? Shell.Failure)?.message == "possible secret in squash commit title:1 (AWS access key).")
        #expect(titled.put == nil)

        // What only gitleaks finds.
        let leaked = Merging(title: "fix: the login", gitleaks: 99)
        #expect((await leaked.merge() as? Shell.Failure)?.message == "possible secret in squash commit title:1 (gitleaks generic-api-key).")
        #expect(leaked.scanned.withLock { $0 } == ["fix: the login (#152)\nChecked on the Mac"])
        #expect(leaked.put == nil)

        // gitleaks can't run.
        let broken = Merging(title: "fix: the login", gitleaks: 2)
        let failed = (await broken.merge() as? Shell.Failure)?.message
        #expect(failed?.hasPrefix("the secret scan of the squash commit couldn't run") == true)
        #expect(broken.put == nil)
        // Nor is the branch deleted when nothing was merged.
        for merging in [titled, leaked, broken] {
            #expect(!merging.calls.withLock { $0 }.contains { $0.contains("DELETE") })
        }
    }

    /// Wherever a base64 run starts, the value's own characters are in it.
    @Test func base64IsFoundAtAnyOffset() {
        let value = secret()
        let needles = Leaks.base64(Array(value.utf8))
        #expect(needles.count == 3)
        for prefix in 0..<7 {
            for suffix in 0..<4 {
                let encoded = Fake.base64(String(repeating: "p", count: prefix) + value + String(repeating: "s", count: suffix))
                #expect(needles.contains { encoded.contains($0) }, "prefix \(prefix), suffix \(suffix)")
            }
        }
    }
}

struct VaultNeverShownTests {
    @Test func listsAndTheCommandShowNamesOnly() throws {
        let (vault, store, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let value = secret()
        var out: [String] = [], err: [String] = []
        let run = { (arguments: [String], input: String?) in
            VaultCommand.run(arguments, vault: vault, read: { input }, say: { out.append($0) }, fail: { err.append($0) })
        }
        #expect(run(["add", "staging-api-key"], value + "\n") == 0)
        #expect(run(["add", "npm-token"], secret()) == 0)
        #expect(run(["list"], nil) == 0)
        #expect(out == ["Saved staging-api-key.", "Saved npm-token.", "npm-token", "staging-api-key"])
        #expect(try vault.names() == ["npm-token", "staging-api-key"])
        #expect(try store.value("staging-api-key") == value)
        // A value never comes as an argument, and errors don't repeat it.
        #expect(run(["add", "staging-api-key", value], nil) == 2)
        #expect(run(["add", "bad name"], value) == 1)
        #expect(run(["add", "no-value"], nil) == 1)
        #expect(run(["remove", "npm-token"], nil) == 0)
        #expect(run(["list"], nil) == 0)
        #expect(out.last == "staging-api-key")
        #expect(run([], nil) == 2)
        for line in out + err {
            for copy in copies(of: value) { #expect(!line.contains(copy.text), Comment(rawValue: line)) }
        }
    }

    @Test func logLinesLeaveSecretsOut() throws {
        let (vault, store, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let value = secret()
        try vault.add(value, as: "staging-api-key")
        let logger = Logger(subsystem: "com.deskree.oby", category: "test")
        let said = { (text: String) in logger.line("error", "call failed: \(text, privacy: .public)", vault: vault) }
        // Right after adding it: no scan has run since.
        #expect(said("401 for token \(value), sent as \(Fake.base64(value))")
                == "error [test] call failed: 401 for token [vault: staging-api-key], sent as [vault: staging-api-key]\n")
        // Added by another process, with no scan since.
        let elsewhere = secret()
        try Vault(store: FileVault(folder: folder)).add(elsewhere, as: "added-elsewhere")
        #expect(said("got \(elsewhere)") == "error [test] call failed: got [vault: added-elsewhere]\n")
        // A vault it can't read any more: the latest values known are still taken out.
        chmod(store.file.path, 0o644)
        #expect(said("got \(value) and \(elsewhere)") == "error [test] call failed: got [vault: staging-api-key] and [vault: added-elsewhere]\n")
        chmod(store.file.path, 0o600)
        // Private values stay out, as in OSLog.
        #expect(logger.line("notice", "token \(value)", vault: vault) == "notice [test] token <private>\n")
    }
}

@MainActor
struct VaultPushTests {
    /// A push goes out through Apple: a job's title or summary with a secret in it goes redacted.
    @Test func aPushHasTheVaultsSecretsTakenOut() throws {
        let (vault, store, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let value = secret()
        try vault.add(value, as: "staging-api-key")
        var failed = job
        failed.status = .failed
        failed.summary = "Failed: the API said 401 to \(value)"
        failed.pr = nil
        failed.issue = nil
        failed.request = "Test with \(Fake.base64(value))"
        let body = try Push.notification(.failed, for: failed)
        let scrubbed = try vault.scrubbed(body)
        let text = String(decoding: scrubbed, as: UTF8.self)
        for copy in copies(of: value) { #expect(!text.contains(copy.text), Comment(rawValue: copy.how)) }
        let alert = try #require((object(scrubbed)["aps"] as? [String: Any])?["alert"] as? [String: String])
        #expect(alert["body"] == "Failed: the API said 401 to [vault: staging-api-key]")
        #expect(alert["title"] == "Failed: Test with [vault: staging-api-key]")
        #expect(object(scrubbed)["job"] as? String == job.id)

        // A clean push goes as it was.
        let clean = try Push.notification(.failed, for: job)
        #expect(try vault.scrubbed(clean) == clean)
        // None goes when the vault can't be read.
        chmod(store.file.path, 0o644)
        #expect(throws: Shell.Failure.self) { try vault.scrubbed(clean) }
    }
}

/// Review 3: what reaches agents, merges, the API, and every finding.
struct VaultReachTests {
    @Test func aVariableHoldingASecretIsntPassedToAgents() {
        let value = secret()
        let leaks = Leaks(["staging-api-key": value])
        let env = ["STAGING_API_KEY": value, "ENCODED": Fake.base64(value), "PATH": "/usr/bin:/bin", "HOME": "/home/oby"]
        let withheld = Agents.withheld(env, leaks: leaks)
        #expect(Set(withheld.keys) == ["STAGING_API_KEY", "ENCODED"])
        #expect(withheld.values.allSatisfy { $0 == nil })
        #expect(Agents.withheld(env, leaks: .empty).isEmpty)
        // Removals win over Oby's own environment, as `Agents.environment` and the checks apply them.
        var applied = env
        for (key, value) in withheld { applied[key] = value }
        #expect(applied == ["PATH": "/usr/bin:/bin", "HOME": "/home/oby"])
    }

    @Test func aReviewIsHandedOnWithoutTheVaultsSecrets() throws {
        let (vault, store, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let value = secret()
        try vault.add(value, as: "staging-api-key")
        let review = Review(verdict: .changesRequested, job: "rev12345", agent: "codex", account: "default", round: 1)
        let text = try Review.handOff(review, summary: "The test uses \(value) and \(Fake.hex(value)).\n\nVERDICT: CHANGES REQUESTED", pr: 107, vault: vault)
        for copy in copies(of: value) { #expect(!text.contains(copy.text), Comment(rawValue: copy.how)) }
        #expect(text.contains("> The test uses [vault: staging-api-key] and [vault: staging-api-key]."))
        // Not handed on when the vault can't be read.
        chmod(store.file.path, 0o644)
        #expect(throws: Shell.Failure.self) { try Review.handOff(review, summary: "fine", pr: 107, vault: vault) }
    }

    /// A secret a merge brings in, and a later commit takes out, is still in what the push sends.
    @Test func aSecretAMergeBroughtInIsFound() async throws {
        let (vault, _, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let value = secret()
        try vault.add(value, as: "staging-api-key")
        let repo = try temporaryFolder()
        let git = { (arguments: [String]) in try await AlreadyOnBaseTests.git(arguments, in: repo) }
        try await Shell.ok(["git", "-C", repo.path, "init", "--quiet", "-b", "dev"])
        try await AlreadyOnBaseTests.commit("README.md", in: repo)
        try await git(["update-ref", "refs/remotes/origin/dev", "dev"])
        try await git(["switch", "--quiet", "-c", "side"])
        try await AlreadyOnBaseTests.commit("side.txt", in: repo)
        try await git(["switch", "--quiet", "-c", "oby/fix-2", "dev"])
        try await AlreadyOnBaseTests.commit("a.txt", in: repo)
        try await git(["merge", "--quiet", "--no-ff", "--no-commit", "side"])
        try "token = \(value)\n".write(to: repo.appending(path: "config.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "config.txt"])
        try await git(["commit", "--quiet", "-m", "Merge side"])
        try await git(["rm", "--quiet", "config.txt"])
        try await git(["commit", "--quiet", "-m", "remove config"])

        let findings = try await Publish.scan(repo, base: "dev", head: "oby/fix-2", vault: vault)
        #expect(findings.contains(Publish.Finding(file: "config.txt", line: 1, rule: "vault secret staging-api-key")))
        // An ordinary merge brings in nothing new.
        try await git(["switch", "--quiet", "-c", "oby/fix-3", "dev"])
        try await AlreadyOnBaseTests.commit("b.txt", in: repo)
        try await git(["merge", "--quiet", "--no-ff", "-m", "Merge side", "side"])
        #expect(try await Publish.scan(repo, base: "dev", head: "oby/fix-3", vault: vault).isEmpty)
    }

    @Test func theAPIsJSONHasTheVaultsSecretsTakenOut() throws {
        let (vault, store, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let value = secret()
        try vault.add(value, as: "staging-api-key")
        var leaky = job
        leaky.request = "Use \(value) for the staging tests"
        leaky.summary = "Ran them with \(Fake.percent(value))"
        let data = try API.encode(JobJSON(job: leaky), vault: vault)
        let text = String(decoding: data, as: UTF8.self)
        for copy in copies(of: value) { #expect(!text.contains(copy.text), Comment(rawValue: copy.how)) }
        #expect(object(data)["request"] as? String == "Use [vault: staging-api-key] for the staging tests")
        // A clean answer is as it was; none is written when the vault can't be read.
        #expect(try API.encode(JobJSON(job: job), vault: vault) == API.encode(JobJSON(job: job), vault: Vault(store: FileVault(folder: folder.appending(path: "none")))))
        chmod(store.file.path, 0o644)
        #expect(throws: Shell.Failure.self) { try API.encode(JobJSON(job: job), vault: vault) }
    }

    /// gitleaks' findings name files as the diff does: a secret in a name goes redacted.
    @Test func everyFindingHasItsFileNameRedacted() {
        let leaks = Leaks(["short-key": "abcdefgh"])
        let finding = Publish.Finding(file: "notes/abcdefgh.txt", line: 3, rule: "gitleaks generic-api-key")
        #expect(finding.redacted(by: leaks) == Publish.Finding(file: "notes/[vault: short-key].txt", line: 3, rule: "gitleaks generic-api-key"))
        #expect(!Publish.blocked(by: [finding.redacted(by: leaks)]).contains("abcdefgh"))
        #expect(finding.redacted(by: .empty) == finding)
    }
}

/// Review 4: the brain and the Lead, the files agents read, failing closed, the Mac's log, every
/// blob a push sends, and branch names and claim comments.
struct VaultAgentTests {
    /// (1) The brain and the Lead get the user's words without the vault's secrets, and none of
    /// Oby's variables that hold one.
    @Test func theBrainAndTheLeadGetRedactedTextAndNoVaultVariable() throws {
        let (vault, store, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let value = secret()
        try vault.add(value, as: "staging-api-key")
        let base = ["STAGING_API_KEY": value, "HEXED": Fake.hex(value), "PATH": "/usr/bin:/bin"]

        let brain = try ClaudeBrain(vault: vault).request(system: "Plan it.", user: "test staging with \(value)", base: base)
        #expect(brain.user == "test staging with [vault: staging-api-key]")
        #expect(brain.env["STAGING_API_KEY"] == .some(nil) && brain.env["HEXED"] == .some(nil))
        #expect(brain.env["PATH"] == nil)

        let lead = try ClaudeLead(model: "opus", vault: vault).request(system: "Lead.", user: "The user said:\n\(Fake.base64(value))", base: base)
        #expect(lead.user == "The user said:\n[vault: staging-api-key]")
        #expect(!lead.env.keys.contains("STAGING_API_KEY") && !lead.env.keys.contains("HEXED"))
        #expect(lead.env["PATH"] == .some("/usr/bin:/bin"))

        // (3) When the vault can't be read, neither is asked.
        chmod(store.file.path, 0o644)
        #expect(throws: Shell.Failure.self) { try ClaudeBrain(vault: vault).request(system: "s", user: "u", base: base) }
        #expect(throws: Shell.Failure.self) { try ClaudeLead(model: "opus", vault: vault).request(system: "s", user: "u", base: base) }
    }

    @Test func theBrainIsntRunWhenTheVaultCantBeRead() async throws {
        let (vault, store, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try vault.add(secret(), as: "staging-api-key")
        chmod(store.file.path, 0o644)
        let error = await #expect(throws: Shell.Failure.self) {
            try await ClaudeBrain(vault: vault).complete(system: "s", user: "u", schema: Data("{}".utf8), timeout: 5)
        }
        #expect(error?.message.contains("nothing goes to an agent") == true)
    }

    /// (2) The Lead's context files, a job's quoted issue and pull request, and its attachments are
    /// written without the vault's secrets.
    @Test func filesAgentsReadAreRedactedBeforeTheyreWritten() throws {
        let (vault, store, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let value = secret()
        try vault.add(value, as: "staging-api-key")
        let directory = try temporaryFolder()

        try Lead.writeContext(roadmap: "# Roadmap\n| 1 | uses \(value) |", jobs: "| job | \(Fake.percent(value)) |", to: directory, vault: vault)
        for file in ["roadmap.md", "jobs.md"] {
            let text = try String(contentsOf: directory.appending(path: ".oby/context/\(file)"), encoding: .utf8)
            for copy in copies(of: value) { #expect(!text.contains(copy.text), Comment(rawValue: file)) }
            #expect(text.contains("[vault: staging-api-key]"))
        }

        let worktree = try temporaryFolder()
        let notes = directory.appending(path: "notes-1a2b3c.txt"), shot = directory.appending(path: "screenshot-1a2b3c.png")
        try "the key is \(value)\n".write(to: notes, atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE]).write(to: shot)
        var work = job
        work.pr = nil
        work.issue = 12
        work.attachments = [notes.path, shot.path]
        let issue = try JSONSerialization.data(withJSONObject: [
            "url": "https://github.com/deskree-inc/oby/issues/12", "author": ["login": "someone"],
            "title": "Staging", "body": "Use \(value) to log in.", "comments": [["author": ["login": "other"], "body": Fake.hex(value)]],
        ])
        let prepared = try Workspace.inputs(work, pullRequest: nil, issue: issue, in: worktree, allowedAttachmentsFolder: directory, vault: vault)
        #expect(prepared.attachments == [notes.path, shot.path])
        for file in ["issue-12.md", "notes-1a2b3c.txt"] {
            let text = try String(contentsOf: worktree.appending(path: ".oby/inputs/\(file)"), encoding: .utf8)
            for copy in copies(of: value) { #expect(!text.contains(copy.text), Comment(rawValue: file)) }
            #expect(text.contains("[vault: staging-api-key]"), Comment(rawValue: file))
        }
        #expect(try Data(contentsOf: worktree.appending(path: ".oby/inputs/screenshot-1a2b3c.png")) == Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE]))

        // A binary file that holds a secret can't be redacted: it stops the job, naming the secret.
        try (Data([0xFF, 0xFE]) + Data(value.utf8) + Data([0x00])).write(to: shot)
        let error = #expect(throws: Shell.Failure.self) { try Attachments.copy(work, into: worktree, allowedFolder: directory, vault: vault) }
        #expect(error?.message.contains("staging-api-key") == true && error?.message.contains(value) == false)

        // (3) When the vault can't be read, no file is written.
        chmod(store.file.path, 0o644)
        let other = try temporaryFolder()
        #expect(throws: Shell.Failure.self) { try Lead.writeContext(roadmap: "r", jobs: "j", to: other, vault: vault) }
        #expect(!FileManager.default.fileExists(atPath: other.appending(path: ".oby/context").path))
        #expect(throws: Shell.Failure.self) { try Workspace.inputs(work, pullRequest: nil, issue: issue, in: other, vault: vault) }
        #expect(!FileManager.default.fileExists(atPath: other.appending(path: ".oby/inputs/issue-12.md").path))
    }

    /// (4) The Mac's log goes through the same `text` as the runner's: OSLog gets it redacted.
    @Test func everyLogLineIsRedactedBeforeItsWritten() throws {
        let (vault, _, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let value = secret()
        try vault.add(value, as: "staging-api-key")
        let said = Logger.jobs.text("job 1: \("gh said 401 for \(value)", privacy: .public)", vault: vault)
        #expect(said == "job 1: gh said 401 for [vault: staging-api-key]")
        #expect(Logger.jobs.text("job 1: \(value)", vault: vault) == "job 1: <private>")
    }

    /// (5) The scan reads every file each pushed commit has whole: a value over lines whose first
    /// line was there already shows in no hunk.
    @Test func everyNewFileInThePushIsScannedWhole() async throws {
        let (vault, _, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try vault.add("aaaa!\nbbbb?", as: "two-lines")
        let repo = try temporaryFolder()
        let git = { (arguments: [String]) in try await AlreadyOnBaseTests.git(arguments, in: repo) }
        try await Shell.ok(["git", "-C", repo.path, "init", "--quiet", "-b", "dev"])
        try "intro\naaaa!\n".write(to: repo.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "notes.txt"])
        try await git(["commit", "--quiet", "-m", "notes"])
        try await git(["update-ref", "refs/remotes/origin/dev", "dev"])
        try await git(["switch", "--quiet", "-c", "oby/fix-4"])
        try "intro\naaaa!\nbbbb?\n".write(to: repo.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try await git(["commit", "--quiet", "-am", "more notes"])
        try "intro\n".write(to: repo.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try await git(["commit", "--quiet", "-am", "fewer notes"])

        let leaks = try vault.leaks()
        // The hunks alone miss it: the first line was there already.
        let diff = try await Shell.ok(["git", "-C", repo.path, "log", "-p", "--format=", "refs/remotes/origin/dev..oby/fix-4"])
        #expect(Publish.findings(inDiff: diff, leaks: leaks).isEmpty)
        #expect(try await Publish.blobFindings(repo, since: "refs/remotes/origin/dev", head: "oby/fix-4", leaks: leaks)
                == [Publish.Finding(file: "notes.txt", line: 2, rule: "vault secret two-lines")])
        #expect(try await Publish.scan(repo, base: "dev", head: "oby/fix-4", vault: vault)
                .contains(Publish.Finding(file: "notes.txt", line: 2, rule: "vault secret two-lines")))
        // With an empty vault nothing is read whole.
        #expect(try await Publish.blobFindings(repo, since: "refs/remotes/origin/dev", head: "oby/fix-4", leaks: .empty).isEmpty)
    }

    /// (5) A secret a merge brought in and a later commit took out is in a blob the push sends.
    @Test func aBlobAMergeBroughtInIsScanned() async throws {
        let (vault, _, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let value = secret()
        try vault.add(value, as: "staging-api-key")
        let repo = try temporaryFolder()
        let git = { (arguments: [String]) in try await AlreadyOnBaseTests.git(arguments, in: repo) }
        try await Shell.ok(["git", "-C", repo.path, "init", "--quiet", "-b", "dev"])
        try await AlreadyOnBaseTests.commit("README.md", in: repo)
        try await git(["update-ref", "refs/remotes/origin/dev", "dev"])
        try await git(["switch", "--quiet", "-c", "side"])
        try await AlreadyOnBaseTests.commit("side.txt", in: repo)
        try await git(["switch", "--quiet", "-c", "oby/fix-5", "dev"])
        try await git(["merge", "--quiet", "--no-ff", "--no-commit", "side"])
        try "key: \(Fake.base64(value))\n".write(to: repo.appending(path: "config.yml"), atomically: true, encoding: .utf8)
        try await git(["add", "config.yml"])
        try await git(["commit", "--quiet", "-m", "Merge side"])
        try await git(["rm", "--quiet", "config.yml"])
        try await git(["commit", "--quiet", "-m", "remove config"])
        #expect(try await Publish.blobFindings(repo, since: "refs/remotes/origin/dev", head: "oby/fix-5", leaks: vault.leaks())
                == [Publish.Finding(file: "config.yml", line: 1, rule: "vault secret staging-api-key, base64")])
    }

    /// (6) The branch's name goes out with a push and in the claim comment: both are scanned first.
    @Test func branchNamesAndClaimCommentsAreScanned() async throws {
        let (vault, _, folder) = scratch()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try vault.add("branchsecret123", as: "branch-key")
        var leaky = job
        leaky.branch = "oby/fix-branchsecret123"
        let findings = try await Publish.scan(texts: Publish.outgoing(leaky, messages: "fix: it", title: "fix: it"), vault: vault)
        #expect(findings.contains(Publish.Finding(file: "branch name", line: 1, rule: "vault secret branch-key")))
        #expect(!Publish.blocked(by: findings).contains("branchsecret123"))
        let error = await #expect(throws: Shell.Failure.self) { try await Lead.claimNote(leaky, vault: vault) }
        #expect(error?.message.hasPrefix("Not posted: possible secret in claim comment:1 (vault secret branch-key)") == true)
        #expect(error?.message.contains("branchsecret123") == false)
        #expect(try await Lead.claimNote(job, vault: vault) == "Oby is working on this on the branch `\(job.branch)` (job \(job.id)).")
    }
}

/// (3) The desk fails closed: when the vault can't be read, no agent starts, no message or check
/// goes, and the job says why.
@MainActor
final class VaultClosedDeskTests {
    final class Agent: AgentRun {
        var onEvent: (AgentEvent) -> Void = { _ in }
        var prompts: [String] = []
        var sent: [String] = []
        func start(prompt: String, onEvent: @escaping (AgentEvent) -> Void) throws {
            prompts.append(prompt)
            self.onEvent = onEvent
        }
        func send(_ text: String) { sent.append(text) }
        func end() {}
        func stop() {}
        func kill() {}
    }

    let folder: URL
    let desk: Desk
    let agent = Agent()
    let vault: Vault
    let store: FileVault
    let value = secret()

    init() throws {
        folder = try temporaryFolder()
        store = FileVault(folder: folder.appending(path: "vault"))
        vault = Vault(store: store)
        try vault.add(value, as: "staging-api-key")
        desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.makeAgent = { [agent] _, _, _ in agent }
        desk.prepare = { $0 }
        desk.countCommits = { _, _ in 1 }
        desk.vault = vault
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func dispatch(_ id: String, check: String? = nil) async throws {
        var work = job
        work.id = id
        work.kind = .fix
        work.pr = nil
        work.issue = 7
        work.base = "dev"
        work.branch = "oby/fix-7-\(id)"
        work.task = "Run the staging tests with \(value)."
        work.check = check
        desk.dispatch(work)
        for _ in 0..<500 where desk.job(id)?.status == .queued { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theAgentGetsTheTaskWithoutTheSecret() async throws {
        try await dispatch("open")
        let prompt = try #require(agent.prompts.first)
        #expect(!prompt.contains(value) && prompt.contains("Run the staging tests with [vault: staging-api-key]."))
        try desk.message("open", "and use \(Fake.base64(value)) too")
        #expect(agent.sent == ["and use [vault: staging-api-key] too"])
    }

    @Test func noAgentStartsAndTheJobSaysWhy() async throws {
        chmod(store.file.path, 0o644)
        try await dispatch("closed")
        let ended = try #require(desk.job("closed"))
        #expect(agent.prompts.isEmpty)
        #expect(ended.status == .failed && ended.summary.contains("The vault can't be read"))
    }

    @Test func noMessageOrCheckGoesOnceTheVaultCantBeRead() async throws {
        try await dispatch("later", check: "true")
        #expect(agent.prompts.count == 1)
        chmod(store.file.path, 0o644)
        #expect(throws: Shell.Failure.self) { try self.desk.message("later", "keep going") }
        #expect(agent.sent.isEmpty)
        agent.onEvent(.turnEnded(summary: "done", failed: false))
        for _ in 0..<500 where desk.job("later")?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        let ended = try #require(desk.job("later"))
        #expect(ended.status == .failed && ended.summary.contains("The check didn't run: The vault can't be read"))
        #expect(agent.sent.isEmpty)
    }
}
