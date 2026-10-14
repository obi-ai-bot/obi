import Foundation

/// The limits Oby holds every job to (case 3.1): 45 minutes a round, 3 hours a job, 20 minutes a
/// test run, decided 2026-10-11 after real rounds took 20 to 47 minutes. Swift enforces them; no prompt states them, so an
/// agent can't talk its way past one. A job that hits one stops, keeps its branch, pushes nothing,
/// and says one more round is possible (`Job.limit`).
// ponytail: the same for every repository; Oby tunes them per repo once it learns how you decide (X.4).
nonisolated struct JobLimits: Equatable, Sendable {
    /// How long one round's agent turn may take, in seconds.
    var round: TimeInterval = 45 * 60
    /// How long a whole job may take, every round and check included, in seconds.
    var job: TimeInterval = 3 * 3600
    /// How long one run of the job's check may take, in seconds: then it's ended and fails.
    var testRun: TimeInterval = 20 * 60
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

/// A round's clock (case 3.1, #203): it runs while the agent works, and stands still while the
/// agent waits for an Apple check it asked for (`oby-check apple`), queued for a Mac or running on
/// one, however long that takes: the job's cap, which counts everything, holds a check that never ends.
nonisolated struct RoundClock: Equatable, Sendable {
    var limit: TimeInterval
    var started: Date
    /// How long it stood still in the round's earlier waits.
    var waited: TimeInterval = 0
    /// When the wait it stands still for began, or nil while it runs.
    var since: Date?

    var standing: Bool { since != nil }

    /// How long it has stood still in the round, the wait under way included.
    func stood(at now: Date) -> TimeInterval { waited + (since.map { max(0, now.timeIntervalSince($0)) } ?? 0) }
    /// The agent's time in the round.
    func used(at now: Date) -> TimeInterval { now.timeIntervalSince(started) - stood(at: now) }
    func left(at now: Date) -> TimeInterval { limit - used(at: now) }

    /// A wait begins.
    mutating func pause(at now: Date) {
        guard since == nil else { return }
        since = now
    }

    /// The wait ended.
    mutating func resume(at now: Date) {
        waited = stood(at: now)
        since = nil
    }
}

/// What a failing round looks like, to tell whether the next one made progress (case 3.1): the
/// failing tests' ids plus the end of the check's output, with what changes from run to run
/// (times, durations, addresses, ids) taken out. The same fingerprint twice in a row stops the job.
nonisolated enum Fingerprint {
    /// How many of the output's last lines count.
    static let tail = 20

    static func of(_ check: Rounds.Check) -> String {
        ((check.failing ?? failingTests(check.output)) + ["--"] + normalized(check.output) + ["--"] + check.problems).joined(separator: "\n")
    }

    /// The ids of the tests the output says failed, sorted, from the common runners' formats:
    /// Swift Testing, XCTest, pytest, Jest and Vitest, Go and Rust.
    static func failingTests(_ output: String) -> [String] {
        var ids = Set<String>()
        for line in output.split(separator: "\n").map(String.init) {
            let plain = line.replacing(/\x{1B}\[[0-9;]*[A-Za-z]/, with: "")
            // Swift Testing's summary, `✘ Test run with 457 tests in 57 suites failed`, names no test.
            if plain.contains(/✘ Test run with \d+ tests?\b/) { continue }
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
        /// The whole file before and after, for the build files whose test settings span lines
        /// (Package.swift); nil otherwise.
        var before: String?
        var after: String?
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
    static func check(worktree: URL, against ref: String, trustedBaseTip: String? = nil) async -> Report {
        let git = ["git", "-c", "core.quotePath=false", "-C", worktree.path]
        // The start commit is immutable from the agent's job state. Oby may supply a freshly
        // fetched base tip to exclude base changes after a rebase; never resolve a mutable ref here.
        let fixed = ref.contains(/^[0-9a-f]{40}$/)
        let comparisonEnv: [String: String?] = ["GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": "/dev/null"]
        var comparison: String?
        if fixed, let trustedBaseTip,
           let candidate = try? await Shell.ok(git + ["merge-base", "HEAD", trustedBaseTip], env: comparisonEnv),
           (try? await Shell.ok(git + ["merge-base", "--is-ancestor", ref, candidate], env: comparisonEnv)) != nil {
            comparison = candidate
        }
        if comparison == nil {
            comparison = fixed ? ref : try? await Shell.ok(git + ["merge-base", ref, "HEAD"])
        }
        guard let base = comparison else {
            return Report(problems: ["Oby couldn't compare the tests with \(ref)"])
        }
        // Nothing the agent wrote gets a say in what the diff shows: no replacement objects or
        // grafts (refs/replace would redefine the start commit), no text conversion or external
        // diff, binary files as text, the attributes from the commit compared with, and the paths
        // as the parser reads them, whatever the config says about prefixes.
        let env: [String: String?] = ["GIT_ATTR_SOURCE": base, "GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": "/dev/null"]
        let diff = git + ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--text", "--no-relative",
                          "--src-prefix=a/", "--dst-prefix=b/", "-U0", "-M", base]
        func diffed(_ arguments: [String], reading after: (String) async -> String?) async -> [Change]? {
            guard let result = try? await Shell.run(diff + arguments, env: env), result.status == 0 else { return nil }
            var changes = self.changes(String(decoding: result.out, as: UTF8.self))
            for index in changes.indices where isBuildFile(changes[index].new ?? changes[index].old ?? "") {
                if let old = changes[index].old { changes[index].before = try? await Shell.ok(git + ["show", "\(base):\(old)"], env: env) }
                if let new = changes[index].new { changes[index].after = await after(new) }
            }
            return changes
        }
        // The commits, which are what Publish sends (tree to tree, so no filter runs), and the
        // worktree the check ran in, with what the agent didn't commit.
        guard let committed = await diffed(["HEAD"], reading: { try? await Shell.ok(git + ["show", "HEAD:\($0)"], env: env) }),
              var working = await diffed([], reading: { try? String(contentsOf: worktree.appending(path: $0), encoding: .utf8) }) else {
            return Report(problems: ["Oby couldn't compare the tests with \(ref)"])
        }
        let untracked = ((try? await Shell.ok(git + ["ls-files", "--others", "--exclude-standard"], env: env)) ?? "").split(separator: "\n").map(String.init)
        for path in untracked where isTest(path) || isConfig(path) {
            let text = (try? String(contentsOf: worktree.appending(path: path), encoding: .utf8)) ?? ""
            working.append(Change(old: nil, new: path, added: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)))
        }
        let both = [report(committed), report(working)]
        var merged = Report()
        for line in both.flatMap(\.problems) where !merged.problems.contains(line) { merged.problems.append(line) }
        for line in both.flatMap(\.notes) where !merged.notes.contains(line) { merged.notes.append(line) }
        return merged
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
            if let file = change.new ?? change.old, isBuildFile(file), let problem = settings(change, in: file) { report.problems.append(problem) }
            let wasTest = change.old.map(isTest) ?? false, isTest = change.new.map(isTest) ?? false
            guard wasTest || isTest else { continue }
            if let old = change.old, wasTest {
                if change.new == nil {
                    report.problems.append("deletes the test file \(old)")
                } else if let new = change.new, new != old {
                    if isTest { report.notes.append("moves the test file \(old) to \(new)") }
                    else { report.problems.append("moves the test file \(old) out of the tests, to \(new)") }
                }
                if let new = change.new {
                    for line in change.added where line.contains(disabler) {
                        report.problems.append("adds a line that turns tests off in \(new): \(line.trimmingCharacters(in: .whitespaces).prefix(80))")
                    }
                    let lost = change.removed.count(where: asserts) - change.added.count(where: asserts)
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

    /// The build files whose test settings Oby compares: Package.swift, package.json, pytest's
    /// pyproject.toml and setup.cfg, Xcode's schemes and projects.
    static func isBuildFile(_ path: String) -> Bool {
        ["Package.swift", "package.json", "pyproject.toml", "setup.cfg", "project.pbxproj"].contains(URL(filePath: path).lastPathComponent)
            || path.hasSuffix(".xcscheme")
    }

    /// How a build file's change weakens the tests, if it does. Whole files are compared where
    /// they were read (`before` and `after`), so a setting spread over lines counts; otherwise the
    /// changed lines are.
    static func settings(_ change: Change, in file: String) -> String? {
        let line = { (text: String) in "changes the test settings in \(file): \(text.trimmingCharacters(in: .whitespaces).prefix(80))" }
        let before = change.before ?? "", after = change.after ?? ""
        switch URL(filePath: file).lastPathComponent {
        case "Package.swift":
            // Each test target whole, however many lines it spans (`exclude:`, `sources:`, `path:`); new ones are fine.
            if let gone = testTargets(in: before).first(where: { !testTargets(in: after).contains($0) }) {
                return "changes " + (gone.firstMatch(of: /name:\s*"([^"]*)"/).map { "the test target \($0.1)" } ?? "a test target") + " in \(file)"
            }
            return testTargets(in: before).isEmpty ? change.removed.first(where: { $0.contains(/\btestTarget\b/) }).map(line) : nil
        case "package.json":
            // The test scripts it had and the test runners' own sections, as JSON values.
            if let old = json(before), let new = json(after) {
                let scripts = { (package: [String: Any]) in package["scripts"] as? [String: Any] ?? [:] }
                for (key, value) in scripts(old).sorted(by: { $0.key < $1.key }) where key.hasPrefix("test")
                    && !same(value, scripts(new)[key]) {
                    return "changes the test script \(key) in \(file)"
                }
                for key in ["jest", "vitest", "mocha", "ava", "c8", "nyc"] where !same(old[key], new[key]) {
                    return "changes the \(key) settings in \(file)"
                }
                return nil
            }
            return (change.added + change.removed).first(where: { $0.contains(/"test[\w:.-]*"\s*:/) }).map(line)
        case "pyproject.toml", "setup.cfg":
            return (change.added + change.removed).first(where: { $0.contains(/pytest|testpaths|addopts|python_(?:files|classes|functions)|norecursedirs/) }).map(line)
        case "project.pbxproj":
            // A test file excluded from its target, or taken out of a target's sources.
            if let excluded = exceptions(in: after).subtracting(exceptions(in: before)).sorted().first(where: isTest) {
                return "excludes \(excluded) from its target in \(file)"
            }
            let sources = { (lines: [String]) in Set(lines.compactMap { $0.firstMatch(of: /(\S+)\s+in\s+Sources\b/).map { String($0.1) } }.filter(isTest)) }
            return sources(change.removed).subtracting(sources(change.added)).sorted().first.map { "takes \($0) out of a target's sources in \(file)" }
        default:
            // An Xcode scheme: tests skipped, or a test target or plan taken out.
            if let added = change.added.first(where: { $0.contains(/[Ss]kipped|<Test\s/) }) { return line(added) }
            return change.removed.first(where: { $0.contains(/<TestableReference|<TestPlanReference/) }).map(line)
        }
    }

    /// The entries of every `membershipExceptions` list in an Xcode project: files kept out of a target.
    static func exceptions(in project: String) -> Set<String> {
        Set(project.matches(of: /membershipExceptions\s*=\s*\(([^)]*)\)/).flatMap { list in
            list.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }.filter { !$0.isEmpty })
    }

    private static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// Two JSON values are the same: both missing, or equal written out with sorted keys.
    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        let written = { (value: Any?) in value.flatMap { try? JSONSerialization.data(withJSONObject: [$0], options: .sortedKeys) } }
        return written(a) == written(b)
    }

    /// A line that really asserts: not commented out, and not one that can't fail (`#expect(true)`).
    static func asserts(_ line: String) -> Bool {
        line.contains(assertion) && !line.contains(/^\s*(?:\/\/|\/\*|\*|#(?:\s|$|#|!)|--\s)/) && !line.contains(trivial)
    }

    /// Each `.testTarget(…)` in a Package.swift, with its spaces squeezed: which tests SwiftPM
    /// finds and runs, however many lines it spans (`exclude:`, `sources:`, `path:`).
    static func testTargets(in package: String) -> [String] {
        var targets: [String] = []
        var rest = package[...]
        while let start = rest.range(of: ".testTarget(") {
            var depth = 0
            var end = start.upperBound
            for index in rest[start.lowerBound...].indices {
                if rest[index] == "(" { depth += 1 }
                if rest[index] == ")" { depth -= 1; if depth == 0 { end = rest.index(after: index); break } }
            }
            targets.append(String(rest[start.lowerBound..<end]).replacing(/\s+/, with: " "))
            rest = rest[end...]
        }
        return targets
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

    /// A line that keeps the tests below it from running: a bare `return`, a block comment opened
    /// and not closed, a branch that's never taken.
    static let disabler = /^\s*return\s*;?\s*$|^\s*\/\*(?!.*\*\/)|^\s*#if\s+(?:false|0)\b|^\s*if\s*\(?\s*(?:false|False|0)\s*\)?\s*[{:]\s*$/

    /// An assertion that can't fail.
    static let trivial = /#(?:expect|require)\s*\(\s*true\s*\)|\bXCTAssert(?:True)?\s*\(\s*true\s*[,)]|\bXCTAssertFalse\s*\(\s*false\s*[,)]|\bassert\s*\(?\s*(?:true|True|1)\s*\)?\s*$|\bexpect\s*\(\s*true\s*\)\.toBe(?:Truthy)?\(\s*(?:true)?\s*\)/

    /// A line that declares a test: Swift Testing and XCTest, Jest and Vitest, pytest, Go, Rust, JUnit, RSpec.
    static let declaration = /^\s*(?:@Test\b|#\[(?:\w+::)?test\]|(?:(?:public|private|internal|async|override)\s+)*(?:func|def)\s+(?:test|Test)\w*\s*\(|(?:it|test)(?:\.\w+)*\s*\(|it\s+['"])/
}
