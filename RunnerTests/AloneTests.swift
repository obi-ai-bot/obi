import Foundation
import Testing
@testable import ObyEngine

/// What lets Oby work alone (#62): every brain turn logged and kept, honest endings, unsigned
/// commits, and Oby's own secrets out of a job's reach.
struct BrainTurnTests {
    let context = BrainContext(accounts: ["auto": ["auto"], "claude": ["auto", "Personal"]], repos: ["deskree-inc/oby"])

    @Test func refusedPlansAreKeptWithTheirReasons() async {
        /// Answers with a repository it doesn't know, then with a good plan.
        final class Learner: BrainAdapter, @unchecked Sendable {
            let name = "learner"
            var calls = 0
            func complete(system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data {
                calls += 1
                let repo = calls == 1 ? "deskree-inc/nowhere" : "deskree-inc/oby"
                return Data(#"{"action":"dispatch","reply":"Oby will build #62.","question":null,"dispatches":[{"agent":"auto","account":"auto","repo":"\#(repo)","base_branch":null,"pr":null,"issue":62,"epic":null,"kind":"build","task":"Work on #62","inputs":[],"rounds":5,"check":"swift test","complexity":"routine"}]}"#.utf8)
            }
        }
        let result = await Planner(adapters: [Learner()]).plan("work on oby #62 until the tests pass", context: context)
        #expect(result.by == "learner")
        #expect(result.refused.count == 1)
        #expect(result.refused.first?.contains("deskree-inc/nowhere isn't a known repository") == true)
        // The refused plan itself, so the log shows what the brain wanted.
        #expect(result.refused.first?.contains(#""repo":"deskree-inc/nowhere""#) == true)
    }

    @Test func aTurnIsOneLineWithTheWordsTyped() throws {
        let job = Plan.Dispatch(agent: "auto", account: "auto", repo: "deskree-inc/oby", baseBranch: nil, pr: nil, issue: 62, epic: nil,
                                kind: .build, task: "Work on #62", inputs: [], rounds: 5, check: "swift test", complexity: .routine)
        let turn = BrainTurn(said: "work on Obi #62\nuntil the tests pass", by: "rules",
                             plan: Plan(action: .dispatch, reply: "Build in oby, issue #62.", dispatches: [job], question: nil),
                             refused: ["claude failed: not signed in"])
        #expect(!turn.line.contains("\n"))
        for part in [#""work on Obi #62\nuntil the tests pass""#, "dispatch by rules", "build deskree-inc/oby #62", "5 rounds",
                     "check `swift test`", "claude failed: not signed in"] {
            #expect(turn.line.contains(part), "\(part)")
        }
        let asked = BrainTurn(said: "OB", by: "claude", plan: Plan(action: .askUser, reply: "", dispatches: [],
                                                                    question: Plan.Question(text: "Which repository?", options: ["deskree-inc/oby"])))
        #expect(asked.line.contains("ask_user by claude") && asked.line.contains("Which repository?"))
    }

    @Test func recentTurnsAreKeptInTheDatabase() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "oby.sqlite")
        let plan = Plan(action: .ignore, reply: "", dispatches: [], question: nil)
        do {
            let store = JobStore(url: url)
            for n in 0..<(JobStore.keptTurns + 5) {
                store.save(BrainTurn(date: Date(timeIntervalSince1970: 1_791_582_173 + Double(n)), said: "turn \(n)", by: "claude", plan: plan))
            }
        }
        // Still there after a restart, newest first, and only the latest.
        let store = JobStore(url: url)
        #expect(store.turns(3).map(\.said) == ["turn \(JobStore.keptTurns + 4)", "turn \(JobStore.keptTurns + 3)", "turn \(JobStore.keptTurns + 2)"])
        #expect(store.turns(1000).count == JobStore.keptTurns)
        #expect(store.turns(1000).last?.said == "turn 5")
    }
}

struct HonestEndingTests {
    func job(_ kind: Plan.Kind) -> Job {
        Job(id: "ab12cd34", request: "work on oby #62", agent: "claude", account: "default", repo: "deskree-inc/oby",
            branch: "oby/\(kind.rawValue)-62", base: "dev", kind: kind, task: "Work on #62")
    }

    @Test func aBuildWithNoCommitsEndsAsNothingCommitted() {
        let summary = "I couldn't commit: gpg failed to sign the data.\n\nThe change is in the worktree."
        for kind in [Plan.Kind.build, .fix, .test] {
            let (status, text) = Job.ending(job(kind), .done, summary, made: 0)
            #expect(status == .failed)
            #expect(text == "Nothing committed: I couldn't commit: gpg failed to sign the data.\n\nThe change is in the worktree.")
            var ended = job(kind)
            (ended.status, ended.summary) = (status, text)
            #expect(ended.doneLine == "Nothing committed: \(ended.heading)")
        }
        #expect(Job.ending(job(.build), .done, "", made: 0).1 == "Nothing committed: the agent gave no reason.")
    }

    @Test func otherEndingsStayAsTheyAre() {
        #expect(Job.ending(job(.build), .done, "Done.", made: 2) == (.done, "Done."))
        // Not counted (no base), so not judged.
        #expect(Job.ending(job(.build), .done, "Done.", made: nil) == (.done, "Done."))
        // Reviews and investigations don't commit.
        #expect(Job.ending(job(.review), .done, "Looks good.", made: 0) == (.done, "Looks good."))
        #expect(Job.ending(job(.investigate), .done, "Found it.", made: 0) == (.done, "Found it."))
        #expect(Job.ending(job(.fix), .failed, "Tests fail.", made: 0) == (.failed, "Tests fail."))
        #expect(Job.ending(job(.fix), .stopped, "Stopped by you.", made: 0) == (.stopped, "Stopped by you."))
    }

    @Test func thePromptSaysCommitsAreUnsignedAndEmptyJobsShow() {
        let build = Prompts.agent(job(.build))
        #expect(build.contains("Commits here are unsigned: Oby signs them when it publishes."))
        #expect(build.contains("a build job that ends with no commits counts as nothing committed"))
        #expect(!Prompts.agent(job(.review)).contains("nothing committed"))
    }
}

struct GitIdentityTests {
    @Test func theProfileNamesWhoCommits() throws {
        let public_ = try #require(GitIdentity(user: Data(#"{"login":"well-prado","id":123,"name":"Wellington Prado","email":"wellington@deskree.com"}"#.utf8)))
        #expect(public_ == GitIdentity(name: "Wellington Prado", email: "wellington@deskree.com"))
        // No name and a private email: the login, and the noreply address GitHub credits to the owner.
        let hidden = try #require(GitIdentity(user: Data(#"{"login":"well-prado","id":123,"name":null,"email":null}"#.utf8)))
        #expect(hidden == GitIdentity(name: "well-prado", email: "123+well-prado@users.noreply.github.com"))
        #expect(GitIdentity(user: Data(#"{"message":"Bad credentials"}"#.utf8)) == nil)
        #expect(GitIdentity(user: Data("prose".utf8)) == nil)
    }

    @Test func agentsGetItFromTheEnvironment() {
        let identity = GitIdentity(name: "Wellington Prado", email: "wellington@deskree.com")
        let overrides = Agents.overrides(identity: identity)
        for key in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"] { #expect(overrides[key] == "Wellington Prado") }
        for key in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"] { #expect(overrides[key] == "wellington@deskree.com") }
        // The rest of the fence stays.
        #expect(overrides["GH_TOKEN"] == .some(nil) && overrides["GIT_CONFIG_KEY_0"] == "credential.helper")
        #expect(Agents.overrides(identity: nil)["GIT_AUTHOR_NAME"] == nil)
    }

    /// With no git config of anyone's (as in bubblewrap), the environment alone lets a commit through,
    /// and no config file changes.
    @Test func aCommitWorksWithNoConfig() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = folder.appending(path: "repo"), home = folder.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var env = Agents.overrides(identity: GitIdentity(name: "Wellington Prado", email: "wellington@deskree.com"))
        env.merge(["HOME": home.path, "XDG_CONFIG_HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]) { $1 }
        let git = { (arguments: [String]) in try await Shell.ok(["git", "-C", repo.path] + arguments, env: env) }
        _ = try await Shell.ok(["git", "init", "--quiet", repo.path], env: env)
        let config = try String(contentsOf: repo.appending(path: ".git/config"), encoding: .utf8)
        try "hello\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "a.txt"])
        _ = try await git(["commit", "--quiet", "-m", "test"])
        #expect(try await git(["log", "-1", "--format=%an <%ae> / %cn <%ce>"])
                == "Wellington Prado <wellington@deskree.com> / Wellington Prado <wellington@deskree.com>")
        #expect(try String(contentsOf: repo.appending(path: ".git/config"), encoding: .utf8) == config)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }
}

/// Bubblewrap needs user namespaces: a job's own check, already inside Oby's bubblewrap, can't nest one.
let bubblewrapRuns: Bool = {
    guard Agents.bubblewrap, FileManager.default.isExecutableFile(atPath: "/usr/bin/bwrap") else { return false }
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/bwrap")
    process.arguments = ["--ro-bind", "/", "/", "--", "/bin/true"]
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}()

/// Inside a box bubblewrap made (a job's own `swift test` on the runner), its pid 1 is bwrap.
let insideBubblewrap = (try? String(contentsOfFile: "/proc/1/comm", encoding: .utf8))?.hasPrefix("bwrap") == true

struct SecretFenceTests {
    /// A job on the runner tries to read gh's login and the APNs key, and gets nothing (case 2.2).
    @Test(.enabled(if: bubblewrapRuns))
    func aJobCantReadObysSecrets() throws {
        let worktree = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let home = Agents.home, apns = Workspace.root.appending(path: "apns").path
        let secrets = ["\(home)/.config/gh/hosts.yml", "\(apns)/apns.json"]
        let tries = "cat \(secrets.map { "'\($0)'" }.joined(separator: " ")) '\(apns)'/AuthKey_*.p8; ls -A '\(apns)' '\(home)/.config'"
        let process = Process(), out = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = Agents.sandboxed(["sh", "-c", tries], in: worktree, own: nil)
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let read = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(read.isEmpty, "\(String(decoding: read, as: UTF8.self))")
        #expect(process.terminationStatus != 0)
    }
}
