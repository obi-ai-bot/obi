import Foundation

/// The limits Oby holds every job to (case 3.1). Swift enforces them; no prompt states them, so an
/// agent can't talk its way past one. A job that hits one stops, keeps its branch, pushes nothing,
/// and says one more round is possible (`Job.limit`).
// ponytail: the same for every repository; Oby tunes them per repo once it learns how you decide (X.4).
nonisolated struct JobLimits: Equatable, Sendable {
    /// How long one round's agent turn may take, in seconds.
    var round: TimeInterval = 15 * 60
    /// How long a whole job may take, every round and check included, in seconds.
    var job: TimeInterval = 45 * 60
    /// How long one run of the job's check may take, in seconds: then it's ended and fails.
    var testRun: TimeInterval = 10 * 60
    /// Claude Code's `--max-turns`: the most tool turns it takes for one message, so for one round.
    /// Codex has no such switch: the round's timer alone holds it.
    var maxTurns = 200
    /// Denied actions in a row that stop the job: the agent keeps trying what Oby won't allow.
    var denials = 3

    /// "15 minutes", "1 minute" or "0.5 seconds": how a limit reads in a summary.
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        if minutes >= 1, minutes == minutes.rounded() { return "\(Int(minutes)) minute\(minutes == 1 ? "" : "s")" }
        return String(format: "%g second%@", seconds, seconds == 1 ? "" : "s")
    }
}

/// What a failing round looks like, to tell whether the next one made progress (case 3.1): the
/// failing tests' ids plus the end of the check's output, with what changes from run to run
/// (times, durations, addresses, ids) taken out. The same fingerprint twice in a row stops the job.
nonisolated enum Fingerprint {
    /// How many of the output's last lines count.
    static let tail = 20

    static func of(_ check: Rounds.Check) -> String {
        (failingTests(check.output) + ["--"] + normalized(check.output) + ["--"] + check.problems).joined(separator: "\n")
    }

    /// The ids of the tests the output says failed, sorted, from the common runners' formats:
    /// Swift Testing, XCTest, pytest, Jest and Vitest, Go and Rust.
    static func failingTests(_ output: String) -> [String] {
        var ids = Set<String>()
        for line in output.split(separator: "\n").map(String.init) {
            let plain = line.replacing(/\x{1B}\[[0-9;]*[A-Za-z]/, with: "")
            if let match = plain.firstMatch(of: /✘ Test (.+?) (?:failed|recorded an issue)\b/) { ids.insert(String(match.1)) }
            else if let match = plain.firstMatch(of: /Test Case '(.+?)' failed/) { ids.insert(String(match.1)) }
            else if let match = plain.firstMatch(of: /^FAILED (\S+)/) { ids.insert(String(match.1)) }
            else if let match = plain.firstMatch(of: /--- FAIL: (\S+)/) { ids.insert(String(match.1)) }
            else if let match = plain.firstMatch(of: /^test (\S+) \.\.\. FAILED/) { ids.insert(String(match.1)) }
            else if let match = plain.firstMatch(of: /^\s*(?:✕|×) (.+?)(?: \(\d+(?:\.\d+)? ?m?s\))?\s*$/) { ids.insert(String(match.1)) }
            else if let match = plain.firstMatch(of: /^\s*● (.+?)\s*$/) { ids.insert(String(match.1)) }
        }
        return ids.sorted()
    }

    /// The output's last non-empty lines with colors, times, durations, addresses and ids taken
    /// out and spaces squeezed: two runs of the same failure read the same.
    static func normalized(_ output: String) -> [String] {
        let lines = output.split(separator: "\n").map { line in
            String(line)
                .replacing(/\x{1B}\[[0-9;]*[A-Za-z]/, with: "")
                .replacing(/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:[.,]\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?/, with: "<time>")
                .replacing(/\b\d{1,2}:\d{2}:\d{2}(?:[.,]\d+)?\b/, with: "<time>")
                .replacing(/\b\d+(?:\.\d+)?\s*(?:seconds?|secs?|s|milliseconds?|ms|µs|us|ns|minutes?|mins?)\b/, with: "<duration>")
                .replacing(/0x[0-9A-Fa-f]+/, with: "<address>")
                .replacing(/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/, with: "<id>")
                .replacing(/\b(?=[0-9a-f]*\d)[0-9a-f]{8,}\b/, with: "<id>")
                .replacing(/\b(?:pid|process) \d+/, with: "<pid>")
                .replacing(/\s+/, with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        return Array(lines.filter { !$0.isEmpty }.suffix(tail))
    }
}

/// Test integrity (case 3.2): Oby compares the job's work with the commit its branch started
/// from and fails a round that clearly weakens the tests: deletes a test file or moves it out of
/// the tests, adds a skip marker, lowers the number of tests or of assertions, or changes test or CI
/// config (the test settings in build files too). Other edits to existing tests and moved test
/// files don't fail it: they're flagged for review. New tests are fine.
// ponytail: a skip the Lead approves with a reason (#62's `.enabled(if: bubblewrapRuns)`) is the
// exception path still to build.
nonisolated enum Integrity {
    /// One file in the diff: its path before (nil when it's new) and after (nil when it's
    /// deleted), and the lines added and removed.
    struct Change: Equatable, Sendable {
        var old: String?
        var new: String?
        var added: [String] = []
        var removed: [String] = []
    }

    struct Report: Equatable, Sendable {
        /// What weakens the tests: any of these fails the round.
        var problems: [String] = []
        /// Other changes to existing tests, flagged for review without failing the round.
        var notes: [String] = []
    }

    /// What the work is compared with: the commit Oby recorded when it set the worktree up, which
    /// an agent can't move the way it can move a ref. Jobs from before that compare with the pull
    /// request's head or the base on origin.
    static func ref(_ job: Job) -> String? {
        job.startCommit ?? job.pr.map { "refs/oby/pr-\($0)" } ?? job.base.map { "refs/remotes/origin/\($0)" }
    }

    /// What the worktree's work (committed or not) does to the tests since it left `ref`. Fails
    /// closed: when git can't say, that's the problem.
    static func check(worktree: URL, against ref: String) async -> Report {
        let git = ["git", "-c", "core.quotePath=false", "-C", worktree.path]
        guard let base = try? await Shell.ok(git + ["merge-base", ref, "HEAD"]),
              let diff = try? await Shell.run(git + ["diff", "--no-color", "--no-ext-diff", "-U0", "-M", base]), diff.status == 0 else {
            return Report(problems: ["Oby couldn't compare the tests with \(ref)"])
        }
        var changes = self.changes(String(decoding: diff.out, as: UTF8.self))
        // Files the agent made and didn't commit count too: they're in the worktree the check ran in.
        let untracked = ((try? await Shell.ok(git + ["ls-files", "--others", "--exclude-standard"])) ?? "").split(separator: "\n").map(String.init)
        for path in untracked where isTest(path) || isConfig(path) {
            let text = (try? String(contentsOf: worktree.appending(path: path), encoding: .utf8)) ?? ""
            changes.append(Change(old: nil, new: path, added: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)))
        }
        return report(changes)
    }

    /// The files a `git diff -U0 -M` names, with their added and removed lines.
    static func changes(_ diff: String) -> [Change] {
        var changes: [Change] = []
        var inHunk = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                // The fallback for files with no ---/+++ lines (binary, mode only): `a/X b/X`.
                let paths = line.dropFirst("diff --git a/".count).components(separatedBy: " b/")
                let path = paths.count == 2 ? paths[1] : nil
                changes.append(Change(old: path, new: path))
                inHunk = false
                continue
            }
            guard !changes.isEmpty else { continue }
            let last = changes.count - 1
            if line.hasPrefix("@@") { inHunk = true; continue }
            if inHunk {
                if line.hasPrefix("+") { changes[last].added.append(String(line.dropFirst())) }
                else if line.hasPrefix("-") { changes[last].removed.append(String(line.dropFirst())) }
                continue
            }
            if line.hasPrefix("new file mode") { changes[last].old = nil }
            else if line.hasPrefix("deleted file mode") { changes[last].new = nil }
            else if line.hasPrefix("rename from ") { changes[last].old = String(line.dropFirst("rename from ".count)) }
            else if line.hasPrefix("rename to ") { changes[last].new = String(line.dropFirst("rename to ".count)) }
            else if line.hasPrefix("--- ") { changes[last].old = line == "--- /dev/null" ? nil : String(line.dropFirst("--- a/".count)) }
            else if line.hasPrefix("+++ ") { changes[last].new = line == "+++ /dev/null" ? nil : String(line.dropFirst("+++ b/".count)) }
        }
        return changes
    }

    /// What weakens the tests and what else changed in them, one line each, in the diff's order.
    static func report(_ changes: [Change]) -> Report {
        var report = Report()
        var tests = 0
        for change in changes {
            if let config = [change.old, change.new].compactMap({ $0 }).first(where: isConfig) {
                report.problems.append("changes test or CI config: \(config)")
            }
            if let file = change.new ?? change.old, let setting = testSetting(in: file) {
                let changed = (file.hasSuffix("Package.swift") ? [] : change.added) + change.removed
                if let line = changed.first(where: { $0.contains(setting) }) {
                    report.problems.append("changes the test settings in \(file): \(line.trimmingCharacters(in: .whitespaces).prefix(80))")
                }
            }
            let wasTest = change.old.map(isTest) ?? false, isTest = change.new.map(isTest) ?? false
            guard wasTest || isTest else { continue }
            if let old = change.old, wasTest {
                if change.new == nil {
                    report.problems.append("deletes the test file \(old)")
                } else if let new = change.new, new != old {
                    if isTest { report.notes.append("moves the test file \(old) to \(new)") }
                    else { report.problems.append("moves the test file \(old) out of the tests, to \(new)") }
                }
                if change.new != nil {
                    let lost = change.removed.count(where: { $0.contains(assertion) }) - change.added.count(where: { $0.contains(assertion) })
                    if lost > 0 {
                        report.problems.append("removes \(lost) assertion\(lost == 1 ? "" : "s") from \(change.new ?? old)")
                    } else if change.removed.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        report.notes.append("edits existing tests in \(change.new ?? old)")
                    }
                }
            }
            let path = change.new ?? change.old ?? ""
            for line in change.added where line.contains(skip) {
                report.problems.append("adds a skip marker in \(path): \(line.trimmingCharacters(in: .whitespaces).prefix(80))")
            }
            tests += change.added.count(where: { $0.contains(declaration) }) - change.removed.count(where: { $0.contains(declaration) })
        }
        if tests < 0 { report.problems.append("lowers the test count by \(-tests)") }
        return report
    }

    /// What a build file's test settings look like, for the build files that hold them: test
    /// targets in Package.swift (only removing one counts), the test scripts in package.json, and
    /// pytest's settings in pyproject.toml, setup.cfg and tox.ini.
    static func testSetting(in path: String) -> Regex<Substring>? {
        switch URL(filePath: path).lastPathComponent {
        case "Package.swift": /\btestTarget\b/
        case "package.json": /"test[\w:.-]*"\s*:/
        case "pyproject.toml", "setup.cfg": /pytest|testpaths|addopts|python_(?:files|classes|functions)|norecursedirs/
        default: nil
        }
    }

    /// A test file: in a folder of tests (`tests/`, `__tests__/`, `RunnerTests/`), or named like one.
    static func isTest(_ path: String) -> Bool {
        path.contains(/(?:^|\/)(?:tests?|__tests__|specs?|[A-Za-z0-9_]*Tests?)\//)
            || path.contains(/(?:^|\/)test_[^\/]*\.py$|_test\.(?:py|go|rb|exs?)$|\.(?:test|spec)\.[cm]?[jt]sx?$|(?:Tests?|Spec)\.(?:swift|java|kt|cs|m)$|_spec\.rb$/)
    }

    /// Test or CI config: CI workflows, and the test runners' own settings.
    static func isConfig(_ path: String) -> Bool {
        path.contains(/^\.github\/(?:workflows|actions)\/|^\.gitlab-ci\.yml$|^\.circleci\/|^\.travis\.yml$|(?:^|\/)Jenkinsfile$|^azure-pipelines\.yml$|^\.buildkite\/|^bitbucket-pipelines\.yml$/)
            || path.contains(/(?:^|\/)(?:jest|vitest|karma|playwright|cypress|mocha)\.config\.\w+$|(?:^|\/)\.mocharc(?:\.\w+)?$|(?:^|\/)(?:pytest\.ini|tox\.ini|conftest\.py|noxfile\.py|codecov\.ya?ml|\.nycrc(?:\.\w+)?)$|(?:^|\/)phpunit\.xml(?:\.dist)?$|\.xctestplan$/)
    }

    /// A line that skips, focuses or expects a test to fail, in the common frameworks.
    static let skip = /\.disabled\s*\(|\.enabled\s*\(\s*if\s*:|XCTSkip|XCTExpectFailure|withKnownIssue|\b(?:it|test|describe|context|suite)\.(?:skip|todo|only|fails)\b|\b(?:xit|xdescribe|xtest|fit|fdescribe)\s*\(|@pytest\.mark\.(?:skip|skipif|xfail)\b|\bpytest\.(?:skip|xfail)\s*\(|@unittest\.(?:skip\w*|expectedFailure)\b|\bt\.Skip(?:Now|f)?\s*\(|#\[ignore\b|@(?:Disabled|Ignore)\b/

    /// A line that asserts, in the common frameworks.
    static let assertion = /#expect\b|#require\b|\bXCT(?:Assert\w*|Fail|Unwrap)\b|\bexpect\s*\(|\bassert\w*\s*[(\s!]|\bt\.(?:Error|Errorf|Fatal|Fatalf|Fail)\b|\bshould\b|\.to(?:Be|Equal|Have)\w*\(/

    /// A line that declares a test: Swift Testing and XCTest, Jest and Vitest, pytest, Go, Rust, JUnit, RSpec.
    static let declaration = /^\s*(?:@Test\b|#\[(?:\w+::)?test\]|(?:(?:public|private|internal|async|override)\s+)*(?:func|def)\s+(?:test|Test)\w*\s*\(|(?:it|test)(?:\.\w+)*\s*\(|it\s+['"])/
}
