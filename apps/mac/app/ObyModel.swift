import Foundation
import Observation

/// What the Oby window, the menu bar and the talk key's pill share: the desk (this Mac's jobs),
/// the runner's feed, and what you're saying now. (The type keeps its old name; the notch is gone.)
@Observable
final class IslandModel {
    let desk: Desk
    let feed: RunnerFeed
    let availability: MacAvailability
    /// The update waiting to be installed, if any (apps/mac/app/Updater.swift).
    let updater: Updater
    /// What you say while you hold fn.
    let voice = Voice()
    /// Oby's reply, spoken, when you talked (apps/mac/app/Speech.swift).
    let speaker = Speaker()
    /// What goes with the next request: screenshots, what you copied.
    let tray = Tray()
    /// The talk key is down (or hands-free is on), and what you said isn't sent yet.
    var listening = false
    /// Where the talk key's turn is, for the pill over the screen while the window isn't showing it
    /// (apps/mac/app/TalkPill.swift); nil when no turn started by the key is under way.
    var turn: TalkStage?
    /// The runner's job whose alert's Publish was clicked: its screen starts publishing, once.
    var publishing: String?
    /// Settings' Remote access (apps/mac/app/RemoteAccess.swift), and the vault its Vault page lists:
    /// the app's own; nil in tests, which give Settings made-up ones when they show it.
    var remote: RemoteAccess?
    var vault: Vault?

    @MainActor init(desk: Desk, feed: RunnerFeed, updater: Updater = Updater(), availability: MacAvailability) {
        self.desk = desk
        self.feed = feed
        self.availability = availability
        self.updater = updater
    }

    /// Both chat surfaces read and send through this model.
    var thread: [Turn] { feed.conversation.thread(with: localTurns) }
    /// This Mac's own turns in the thread: the words on their way to the runner (`RunnerFeed.echoes`),
    /// and with one runner thread the history from before the runner planned; with obid's
    /// conversations (#493) no history, since each conversation is only its own turns.
    var localTurns: [Turn] { Self.localTurns(desk.turns, conversations: feed.conversationsOn, echoes: feed.shownEchoes) }
    nonisolated static func localTurns(_ turns: [Turn], conversations: Bool, echoes: [Turn] = []) -> [Turn] { conversations ? echoes : turns + echoes }
    /// The accounts a plan's card offers: the runner's when the runner on this Mac plans (#283),
    /// else this Mac's.
    var planAccounts: [AccountState] { (feed.local ? feed.accounts : desk.accounts.accounts).filter(\.signedIn) }
    var chatWindowVisible = false
    var readReply: String?
    var unreadReply: Bool { thread.last(where: { $0.who == .oby }).map { $0.id != readReply } ?? false }

    func markChatRead() { readReply = thread.last(where: { $0.who == .oby })?.id }

    func sendChat(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let said = tray.note.map { "\(text)\n\n\($0)" } ?? text
        // Through the runner, the words show in the thread now, not once it lists them (`RunnerFeed.Echo`).
        if desk.plansElsewhere() { feed.echo(said) }
        desk.ask(said, shown: text, attachments: tray.paths)
        tray.clear()
    }

    func stopChatJob(_ id: String, local: Bool) {
        if local { desk.stop(id) }
        else { Task { if let job = try? await feed.about(id, { try await $0.stop(id) }) { feed.apply(job) } } }
    }

    /// Agents working now, on this Mac and on the runner: not the jobs waiting their turn (#238).
    var working: Int { desk.jobs.count(where: \.isWorking) + feed.working }
    /// Jobs queued behind something, on this Mac and on the runner (`Job.waiting`).
    var waiting: Int { desk.jobs.count(where: \.isWaiting) + feed.waiting }

    /// Jobs and inbox items that wait for you, each job once: the menu bar's count, with `working`.
    /// It runs on every change to the jobs, so the list is put together once, not once per job (#511).
    var needsYou: Int {
        var waits = Set<String>()
        let all = desk.jobs + feed.jobs
        for (jobs, place) in [(desk.jobs, "mac"), (feed.jobs, "runner")] {
            for job in jobs where job.waitsForYou && job.listed(after: feed.clearedAt, among: all) { waits.insert("\(place)/\(job.id)") }
        }
        for entry in IslandInbox.entries(desk: desk, feed: feed, now: .now) {
            waits.insert(entry.item.job.isEmpty ? entry.id : "\(entry.local ? "mac" : "runner")/\(entry.item.job)")
        }
        return waits.count
    }

    /// What Oby does while the window shows it: listens while you talk, melts into Loading while
    /// the brain thinks (and comes back together when the answer lands), works while agents work.
    var mood: String {
        if listening { return "listening" }
        if case .thinking = desk.talk { return "loading" }
        return working == 0 ? "idle" : "working"
    }

    /// Whether a job is under Archived, not on Home (`ArchiveAfter.archives`): it's settled
    /// (`Job.settled`), and it was archived by hand on obid, an older Clear done took it, or it
    /// finished longer ago than Archive completed says. This Mac's own jobs go by time alone.
    func archived(_ job: Job, local: Bool, after: ArchiveAfter, now: Date = .now) -> Bool {
        after.archives(settled: job.settled(among: desk.jobs + feed.jobs), finished: job.finished,
                       archived: local ? nil : feed.extras[job.id]?.archived, clearedAt: feed.clearedAt, now: now)
    }

    /// Rename, Archive task and Delete task are obid's (`PATCH`, `/archive`, `DELETE /v1/jobs/{id}`):
    /// not for this Mac's own jobs, nor a runner that isn't obid.
    func managesJobs(local: Bool) -> Bool { !local && feed.conversationsOn }

    /// The one line the iPhone's Home says too (apps/shared/JobList.swift): who's working, and what
    /// needs you among the jobs listed.
    var summary: String {
        let all = desk.jobs + feed.jobs
        return Summary.line(working: working, waiting: waiting, needs: NeedsYou.line(all.filter { $0.listed(after: feed.clearedAt, among: all) }))
    }
}

extension Job {
    /// It needs an answer, a decision or a Publish: the jobs the window marks "Needs you".
    nonisolated var waitsForYou: Bool { needsYou || waitsForAnswer || waitsForPermission }
}
