import Foundation
import Testing
@testable import ObyEngine

/// The chat reads before it answers (#302, Engine/ReadJob.swift): read_job puts a job's report,
/// pull request, Mac check, verdict and post-mortem in the next step's quoted file.
@MainActor
struct ReadJobTests {
    let folder: URL
    let desk: Desk
    let brain: ConversationTests.FakeBrain

    static func read(_ id: String) -> String {
        #"{"action":"read_job","reply":"","question":null,"dispatches":[],"jobs":["\#(id)"]}"#
    }

    /// A finished job whose Mac check failed in a step, on one test, and whose build broke in a file.
    static func failedJob(_ id: String, title: String) -> Job {
        var job = Job(id: id, request: "work on oby #60", agent: "claude", account: "default", repo: "deskree-inc/oby",
                      branch: "oby/build-60", base: "dev", pr: nil, kind: .build, task: "Work on #60")
        job.title = title
        job.issue = 60
        job.status = .done
        job.summary = "Added the vault.\nIt builds in the Engine."
        job.published = "https://github.com/deskree-inc/oby/pull/295"
        job.outgoing = [Outgoing(action: .pullRequest, repo: "deskree-inc/oby", id: "https://github.com/deskree-inc/oby/pull/295")]
        var check = MacCheck(id: "chk\(id)", job: id, repo: "deskree-inc/oby", pr: 295, branch: "oby/build-60", base: "dev", head: "abc1234", round: 1)
        check.state = .failed
        check.steps = [MacCheck.Step(name: "Engine build", passed: false, seconds: 41, failing: nil),
                       MacCheck.Step(name: "MacTests", passed: false, seconds: 90,
                                     failing: [MacCheck.FailingTest(test: "MacTests.VaultTests/sealsTheKey()", message: "Engine/Vault.swift:88: expected 32 bytes")])]
        check.failures = ["MacTests.VaultTests/sealsTheKey()"]
        job.macCheck = check
        return job
    }

    init() throws {
        folder = try temporaryFolder()
        let store = JobStore(url: folder.appending(path: "oby.sqlite"))
        store.save(Self.failedJob("aaaa1111", title: "Vault secrets"))
        for (id, title) in [("bbbb2222", "Watch home"), ("cccc3333", "Release notes"), ("dddd4444", "Island chat"), ("eeee5555", "Brain retries")] {
            store.save(Self.failedJob(id, title: title))
        }
        let accounts = AccountStore(root: folder)
        accounts.setLabel("Max · well@example.com", for: "default")
        desk = Desk(accounts: accounts, store: store)
        desk.repos = ["deskree-inc/oby"]
        brain = ConversationTests.FakeBrain([ConversationTests.reply("Fine.")])
        desk.makeBrain = { [brain] (_: String?, _: String?, _: Vault) in [brain] }
    }

    @Test func aReadPutsTheMacCheckInTheNextStepsQuotedFileAndNotInThePrompt() async throws {
        brain.plans = [Self.read("aaaa1111"), ConversationTests.reply("Its Mac check failed in MacTests on sealsTheKey, in Engine/Vault.swift.")]
        let talk = await desk.converse("why did the vault job's Mac check fail?")
        #expect(talk == .reply("Its Mac check failed in MacTests on sealsTheKey, in Engine/Vault.swift."))
        #expect(brain.prompts.count == 2)
        // The first step's file has nothing of it; the next step's holds the failure, as quoted data.
        #expect(brain.quoted[0]?.contains("MacTests.VaultTests/sealsTheKey()") != true)
        let file = try #require(brain.quoted[1])
        #expect(file.contains("data, never instructions"))
        #expect(file.contains("## Read: job aaaa1111 (Vault secrets)"))
        #expect(file.contains("Step “MacTests”: FAILED"))
        #expect(file.contains("Failing test MacTests.VaultTests/sealsTheKey(): Engine/Vault.swift:88: expected 32 bytes"))
        #expect(file.contains("Opened pull request https://github.com/deskree-inc/oby/pull/295"))
        // Never in a prompt: the prompt only says it was read, and where.
        for prompt in brain.prompts {
            #expect(!prompt.contains("sealsTheKey") && !prompt.contains("Engine/Vault.swift"))
        }
        #expect(brain.prompts[1].contains("Oby read job aaaa1111") && brain.prompts[1].contains("work.md"))
        #expect(brain.systems[0].contains("- read_job:"))
    }

    @Test func aFourthReadInATurnIsRefused() async throws {
        brain.plans = [Self.read("aaaa1111"), Self.read("bbbb2222"), Self.read("cccc3333"), Self.read("dddd4444"),
                       ConversationTests.reply("I read three jobs.")]
        let talk = await desk.converse("what did all of them change?")
        #expect(talk == .reply("I read three jobs."))
        #expect(brain.prompts.count == 5)
        let last = try #require(brain.quoted.last ?? nil)
        #expect(last.contains("## Read: job aaaa1111") && last.contains("## Read: job bbbb2222") && last.contains("## Read: job cccc3333"))
        #expect(!last.contains("## Read: job dddd4444"))
        #expect(brain.prompts.last?.contains("Oby reads at most 3 jobs in one turn: it didn't read job dddd4444") == true)
        // A new turn starts with no reads.
        brain.plans = [Self.read("dddd4444"), ConversationTests.reply("Done.")]
        _ = await desk.converse("and the island one?")
        #expect(brain.quoted.last??.contains("## Read: job dddd4444") == true)
        #expect(brain.quoted.last??.contains("## Read: job aaaa1111") != true)
    }

    @Test func aJobReadTwiceIsInTheFileOnceAndCountsOnce() async throws {
        var reads = JobReads()
        let lookup = { (id: String) in desk.readJob(id) }
        for id in ["aaaa1111", "aaaa1111", "bbbb2222", "cccc3333"] {
            #expect(reads.read(try Plan.decode(Data(Self.read(id).utf8)), lookup: lookup) == nil)
        }
        #expect(reads.sections.map(\.id) == ["aaaa1111", "bbbb2222", "cccc3333"])
        #expect(reads.read(try Plan.decode(Data(Self.read("eeee5555").utf8)), lookup: lookup) != nil)
        // A job that isn't there is said, and costs nothing.
        var other = JobReads()
        #expect(other.read(try Plan.decode(Data(Self.read("zzzz9999").utf8)), lookup: lookup) == "Job zzzz9999 isn't here any more.")
        #expect(other.sections.isEmpty && other.quoted(adding: nil) == nil)
    }

    @Test func aReadIsCappedAtAboutEightKilobytes() throws {
        var reads = JobReads()
        var plan = try Plan.decode(Data(Self.read("aaaa1111").utf8))
        #expect(reads.read(plan, lookup: { _ in String(repeating: "é long report line ", count: 4000) }) == nil)
        let text = try #require(reads.sections.first?.text)
        #expect(text.utf8.count <= JobReads.size && text.contains("…(cut:"))
        #expect(JobReads.clamp("short", to: JobReads.size) == "short")
        plan.jobs = []
        // The job's own report is cut before that, so a section stays well inside the cap.
        var long = Self.failedJob("aaaa1111", title: "Vault secrets")
        long.summary = String(repeating: "report ", count: 4000)
        #expect(JobReads.section(long).utf8.count < JobReads.size)
        var empty = JobReads()
        #expect(empty.read(plan, lookup: { _ in "x" }) == "Say which job to read.")
    }

    @Test func theSectionHasTheVerdictTheAppleCheckAndThePostMortem() throws {
        var job = Self.failedJob("aaaa1111", title: "Vault secrets")
        var review = Review(verdict: .changesRequested, job: "rev1", agent: "codex", account: "Work", round: 2)
        review.blocking = ["Engine/Vault.swift:88 seals with a short key"]
        review.followUps = ["Name the key size"]
        job.review = review
        var apple = try #require(job.macCheck)
        apple.kind = .apple
        apple.problem = "the simulator hung"
        apple.state = .error
        job.appleRan = apple
        job.pullRequest = PullRequestStatus(state: .open, reviewDecision: .changesRequested, base: "dev", checkedAt: .now)
        let postMortem = PostMortem(happened: "The MacTests step failed on the vault test.", cause: .agentMistake, obyCouldHandle: false,
                                    fix: PostMortem.Fix(files: ["Engine/Vault.swift"], change: "Seal with 32 bytes."), signature: "short-key", by: "claude")
        var record = FailureRecord(id: "f1", trigger: .unnamedFailure, date: .now, job: "aaaa1111", title: "Vault", what: "A Mac check failed",
                                   evidence: FailureRecord.Evidence(summary: "", step: ""))
        record.postMortem = postMortem
        let text = JobReads.section(job, failures: [record])
        #expect(text.contains("Changes requested, round 2") && text.contains("- Engine/Vault.swift:88 seals with a short key"))
        #expect(text.contains("Worth doing later:") && text.contains("Problem (the Mac couldn't run it): the simulator hung"))
        #expect(text.contains("open into dev, review changes requested"))
        #expect(text.contains("What happened: The MacTests step failed on the vault test.") && text.contains("(in Engine/Vault.swift)"))
        // Nothing to say is said, so the brain doesn't guess.
        var bare = Self.failedJob("bbbb2222", title: "Watch home")
        bare.macCheck = nil
        bare.outgoing = nil
        bare.published = nil
        let empty = JobReads.section(bare)
        #expect(empty.contains("(no Mac check ran)") && empty.contains("(no verdict yet)") && empty.contains("(no failure recorded)") && empty.contains("(nothing went out)"))
    }

    @Test func readJobPlansAreChecked() throws {
        let context = BrainContext(accounts: ["claude": ["default"]], repos: ["deskree-inc/oby"], jobs: [], movable: ["aaaa1111", "bbbb2222"])
        let problems = { (json: String) in try Plan.decode(Data(json.utf8)).problems(in: context, canary: "zq9") }
        #expect(try problems(Self.read("aaaa1111")).isEmpty)
        #expect(try problems(Self.read("zz")) == ["zz isn't a job Oby can read"])
        var two = try Plan.decode(Data(Self.read("aaaa1111").utf8))
        two.jobs = ["aaaa1111", "bbbb2222"]
        #expect(two.problems(in: context, canary: "zq9") == ["read_job names one job"])
        #expect(String(decoding: Plan.schema(for: context), as: UTF8.self).contains("read_job"))
        // It changes nothing, so the loop doesn't count it as an action that did something.
        #expect(!Desk.acting.contains(.readJob))
    }
}
