import Foundation
import Testing
@testable import Oby

/// What the window shows at launch from the runner's last answers (`RunnerFeed.Kept`), and how long
/// a dropped runner waits for its next try (`RunnerFeed.pause`). No runner needed.
@MainActor
struct RunnerKeptTests {
    static let url = "http://127.0.0.1:7777"
    static let jobs = #"[{"account":"default","agent":"claude","base":"dev","branch":"oby/investigate-4bbb14","check":null,"commits":0,"created":"2026-10-10T00:04:01Z","finished":"2026-10-10T00:04:45Z","id":"4bbb145a","issue":null,"kind":"investigate","model":null,"notes":null,"pr":null,"published":null,"repo":"deskree-inc/oby","request":"count the Swift files","round":1,"rounds":1,"session":"862ca2c8-5263-4eb8-9862-56a5f6ca1821","started":"2026-10-10T00:04:02Z","status":"done","step":"","summary":"8 files.","task":"Count the Swift files in Engine/"}]"#
    static let kept = RunnerFeed.Kept(url: url, jobs: Data(jobs.utf8), inbox: Data("[]".utf8), conversations: nil)

    /// A feed that keeps its answers in a folder of the test's own, never the user's Caches.
    func feed(in folder: URL) -> RunnerFeed {
        let feed = RunnerFeed()
        feed.keptFile = folder.appending(path: "Oby").appending(path: "runner-feed.json")
        return feed
    }

    func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "RunnerKeptTests-\(UUID().uuidString)")
    }

    func mode(_ path: String) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }

    /// Kept, it comes back as it was, the user's alone, and shows for its own runner; actions wait
    /// until the runner answers again.
    @Test func keptAnswersComeBackForTheirRunner() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = feed(in: folder)
        feed.keep(Self.kept)
        let saved = try JSONDecoder().decode(RunnerFeed.Kept.self, from: Data(contentsOf: feed.keptFile))
        #expect(saved == Self.kept)
        #expect(try mode(feed.keptFile.path) == 0o600)
        #expect(try mode(feed.keptFile.deletingLastPathComponent().path) == 0o700)

        let next = self.feed(in: folder)
        #expect(next.showKept(for: Self.url))
        #expect(next.jobs.map(\.id) == ["4bbb145a"])
        #expect(next.showingKept)
    }

    /// While kept answers show, actions wait; with no runner each says what it always said.
    @Test func actionsWaitForTheLiveRunner() throws {
        let runner = Runner(base: URL(string: Self.url)!, token: "t")
        func said(_ act: () throws -> Runner) -> String? {
            do { _ = try act(); return nil } catch { return (error as? RunnerError)?.message }
        }
        #expect(said { try RunnerFeed.acting(runner, showingKept: true, missing: "none") } == RunnerFeed.reconnecting)
        #expect(said { try RunnerFeed.acting(runner, showingKept: false, missing: "none") } == nil)
        #expect(said { try RunnerFeed.acting(nil, showingKept: true, missing: "The runner isn't set up.") } == "The runner isn't set up.")
        #expect(said { try RunnerFeed().acting() } == "Set the runner's URL in Settings first.")
    }

    /// Another runner's answers (followed since, while Oby was closed), or a file that doesn't read
    /// (another shape, or jobs that don't decode), show nothing, and the file goes.
    @Test func anotherRunnersOrUnreadableAnswersAreNotShownAndGo() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        feed(in: folder).keep(Self.kept)
        let other = feed(in: folder)
        #expect(!other.showKept(for: "https://tetrix-lab:8790"))
        #expect(other.jobs.isEmpty && !other.showingKept)
        #expect(!FileManager.default.fileExists(atPath: other.keptFile.path))

        feed(in: folder).keep(Self.kept)
        try Data("{not json".utf8).write(to: other.keptFile)
        #expect(!feed(in: folder).showKept(for: Self.url))
        #expect(!FileManager.default.fileExists(atPath: other.keptFile.path))

        var wrong = Self.kept
        wrong.jobs = Data(#"{"jobs": "not a list"}"#.utf8)
        feed(in: folder).keep(wrong)
        let unread = feed(in: folder)
        #expect(!unread.showKept(for: Self.url))
        #expect(unread.jobs.isEmpty && !unread.showingKept)
        #expect(!FileManager.default.fileExists(atPath: unread.keptFile.path))
    }

    /// While Oby hosts tests, a feed never points at the user's own file.
    @Test func aTestsFeedNeverUsesTheUsersFile() {
        #expect(RunnerFeed().keptFile != RunnerFeed.keptURL)
        #expect(RunnerFeed().keptFile != RunnerFeed().keptFile)
    }

    /// Following another runner drops the last one's answers from the disk, and what shows of them;
    /// launch keeps them to show (`droppingKept: false`).
    @Test func forgettingTheRunnerDropsWhatWasKept() {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = feed(in: folder)
        feed.keep(Self.kept)
        #expect(feed.showKept(for: Self.url))
        feed.forget()
        #expect(!FileManager.default.fileExists(atPath: feed.keptFile.path))
        #expect(!feed.showingKept && feed.jobs.isEmpty)

        feed.keep(Self.kept)
        feed.forget(droppingKept: false)
        #expect(FileManager.default.fileExists(atPath: feed.keptFile.path))
    }

    /// The wait goes in steps, and stops after the first once the window is open: counted by how
    /// often it asks, so a slow machine can't fail it.
    @Test func theWaitEndsAfterAStepOnceTheWindowIsOpen() async {
        let feed = RunnerFeed()
        var asked = 0
        feed.windowOpen = { asked += 1; return false }
        await feed.pause(0.375, steps: 0.125)
        // Three steps, the window asked after each but the last.
        #expect(asked == 2)

        asked = 0
        feed.windowOpen = { asked += 1; return true }
        await feed.pause(0.375, steps: 0.125)
        #expect(asked == 1)
    }
}
