import Foundation
import Network
import OSLog
import Security
import UIKit

/// The jobs as Home's work (#496, as the Mac's `SidebarSections.work`): each one's kind, where it
/// stands, and whether it's new; and what's been archived.
nonisolated enum PhoneWork {
    /// Latest first (by when it finished, else when it was made). New: made after `since` (this
    /// launch) and not opened since (`seen`). Needs you: a decision is open on it, its own or one
    /// of `inbox` (what waits now, `InboxItem.waiting`), whatever its agent is doing (Sangam's
    /// tasks.ts). No teammates yet: the runner doesn't say who asked.
    static func items(_ jobs: [Job], inbox: [InboxItem] = [], since: Date, seen: Set<String>) -> [WorkList.Item<Job>] {
        let asked = Set(inbox.map(\.job))
        return jobs.enumerated()
            .sorted { ($0.element.finished ?? $0.element.created, -$0.offset) > ($1.element.finished ?? $1.element.created, -$1.offset) }
            .map { _, job in
                let decides = job.needsYou || job.waitsForAnswer || job.waitsForPermission || asked.contains(job.id)
                let status: WorkStatus = decides ? .needs : job.isActive ? .running : .done
                return WorkList.Item(id: job.id, job: job, type: .of(review: job.kind == "review", issue: job.issue, requester: nil, routine: job.routine != nil),
                                     status: status, queued: job.status == .queued, fresh: job.created > since && !seen.contains(job.id))
            }
    }

    /// Archived (#280), kept by the phone alone: finished jobs Clear done took off Home, and the
    /// ones you let go (Dismiss). The runner keeps them all; this lists the ones it sent.
    /// `here`: the tasks archived on this iPhone (a task's ⋮); one that runs again comes back.
    static func archived(_ jobs: [Job], clearedAt: Date?, here: Set<String> = []) -> [Job] {
        jobs.filter { !$0.isActive && ($0.dismissed != nil || here.contains($0.id) || !$0.listed(after: clearedAt, among: jobs)) }
    }

    /// The Inbox (docs/oby-ux.md row 10): of what waits now, the decisions with no task on Home,
    /// so each one is somewhere. The rest live with their task.
    static func loose(_ inbox: [InboxItem], among items: [WorkList.Item<Job>]) -> [InboxItem] {
        let listed = Set(items.map(\.id))
        return inbox.filter { !listed.contains($0.job) }
    }

    /// Where Home's "needs you" leads: the decision that has waited longest (`inbox` is what waits
    /// now, longest first), on its task's page, or the Inbox when it has no task on Home; with no
    /// inbox item (an older runner), the first task that needs you.
    static func firstNeeding(_ items: [WorkList.Item<Job>], inbox: [InboxItem]) -> Route? {
        if let first = inbox.first {
            return items.contains { $0.id == first.job } ? .task(first.job) : .inbox
        }
        return WorkList.ranked(items).first { $0.status == .needs }.map { .task($0.id) }
    }

    /// Home's Running (docs/ios-design.md: Sangam has these in his side panel): up to three open
    /// tasks, in the side panel's order.
    static func running(_ items: [WorkList.Item<Job>]) -> [WorkList.Item<Job>] {
        Array(WorkList.ranked(items.filter { $0.status != .done }).prefix(3))
    }

    /// What a Running row says it's on: the decision that waits ("Needs you · Question"), else
    /// "Queued" and what for, else its live step.
    static func step(_ item: WorkList.Item<Job>, decision: InboxItem?) -> String {
        let job = item.job
        if item.status == .needs {
            let kind = decision.map { AskKind.label($0.kind, plan: job.question?.plan != nil) }
                ?? (job.waitsForPermission ? "Permission" : job.waitsForAnswer ? AskKind.label("question", plan: job.question?.plan != nil)
                    : job.reviewNeedsYou ? AskKind.label("review") : job.mergeNeedsYou ? AskKind.label("merge") : AskKind.label("failed"))
            return "Needs you · \(kind)"
        }
        if item.queued { return job.waiting.map { "Queued · \($0.text)" } ?? "Queued" }
        return job.step.isEmpty ? "Working" : job.step
    }

    /// Home's Recent: the three latest conversations.
    static func recent(_ conversations: [RunnerConversation]) -> [RunnerConversation] {
        Array(conversations.sorted { $0.latest > $1.latest }.prefix(3))
    }
}

/// The phone's view of the runner: its jobs and accounts, kept live while the app is open, and
/// the conversation that turns words into a plan.
@Observable
final class Phone {
    /// What Oby answered: a reply (the work it started shows as job cards under its turn, #269),
    /// or a question.
    enum Talk: Equatable {
        case none
        case thinking(String)
        case queued(String)
        case question(said: String, Question)
        case reply(String)
    }

    let voice = PhoneVoice()
    /// The side panel, open on one of its sections, or nil while it's closed (PhoneRoot).
    var panel: PanelSection?
    /// The panel's groups folded away with their chevron (Sangam's Sidebar.tsx), kept while Oby runs.
    var panelFolded: Set<String> = []
    /// The runner's conversation, read in pages and followed over `turn` events, for the Chat
    /// tab's thread (apps/shared/ConversationModel.swift): one thread for every device (#11).
    let conversation = ConversationModel()
    /// What this iPhone said and the runner hasn't listed yet (ChatThread): the runner adds the
    /// user's turn with Oby's answer, so the words show here from the moment they're sent.
    private(set) var echoes: [Turn] = []
    /// Why an echo's request didn't go through, by echo id: the words stay in the thread with the
    /// reason, to try again or edit, until the runner lists them after all.
    private(set) var failures: [String: String] = [:]
    /// What each echo sent, by echo id, to send it again.
    @ObservationIgnored private var requests: [String: Request] = [:]
    /// The echo of the request under way, or nil: the one Cancel or a new request lets go of.
    /// Never another (an older failed one, say): the runner may settle this one before the
    /// request answers, and then `echoes.last` is someone else.
    @ObservationIgnored private var pending: String?

    private struct Request: Sendable {
        var said: String
        var answer: (question: String, option: String)?
        var voice: Bool
        /// The conversation the words join (obid, #493), or nil for the latest; `new` starts one.
        var conversation: String? = nil
        var new = false
    }

    /// obid's conversations (#493), pinned first, or nil from a runner that keeps one thread.
    private(set) var conversations: [RunnerConversation]?
    /// The conversation the thread shows: one of obid's by id, or nil for the latest (the one
    /// thread of a runner without conversations).
    private(set) var current: String?
    /// A conversation is being started (Home's box) and obid hasn't named it yet: the thread
    /// holds only its words until it does.
    private(set) var startingNew = false
    /// Oby's words for a conversation that comes before obid names it to this phone (`adopt`):
    /// kept, and shown once it does.
    private var heldDeltas: [TurnDelta] = []
    /// The conversation Oby's answer under way (`talk`) belongs to.
    private var talkIn: String?
    /// The last line said in each conversation, by id, for its row in the list.
    private(set) var previews: [String: String] = [:]
    /// When this launch began, and the tasks opened since: a task is new (blue) until it's opened.
    let since = Date.now
    private(set) var seen: Set<String> = []
    func markSeen(_ id: String) { seen.insert(id) }

    /// Home's work: every job Home lists, with its kind and where it stands.
    var work: [WorkList.Item<Job>] { PhoneWork.items(visibleJobs, inbox: answering, since: since, seen: seen) }
    /// The Inbox: what waits now with no task on Home.
    var loose: [InboxItem] { PhoneWork.loose(answering, among: work) }
    /// The decisions that wait on you now, longest first: not those answered here while the Mac
    /// was out of reach, which wait to go (docs/oby-ux.md row 18).
    var answering: [InboxItem] { InboxItem.waiting(inbox).filter { !waitsToSend(answer: $0.id) } }
    /// An answer, or words, given while the Mac was out of reach: they wait on this iPhone, marked
    /// "Sends when your Mac is back", and go when it is.
    func waitsToSend(answer id: String) -> Bool { offlineQueue.answers.contains { $0.id == id } }
    func waitsToSend(echo id: String) -> Bool { offlineQueue.messages.contains { $0.id == id } }
    /// Archived: done jobs that left Home (Clear done, Dismiss).
    var archived: [Job] { PhoneWork.archived(jobs, clearedAt: clearedAt, here: archivedHere) }
    /// Tasks archived with their ⋮ (Sangam's Archive task), kept by this iPhone: obid has no
    /// archive yet (docs/oby-ux.md row 22, A7).
    private(set) var archivedHere = Set(UserDefaults.standard.stringArray(forKey: "phone.archived") ?? []) {
        didSet { UserDefaults.standard.set(Array(archivedHere), forKey: "phone.archived") }
    }
    func archive(_ id: String) { archivedHere.insert(id) }
    /// What Oby's answering or asking in the thread shown, else nothing.
    var talkHere: Talk { talkIn == current ? talk : .none }
    @ObservationIgnored private let speaker = PhoneSpeaker()
    @ObservationIgnored private var planning: Task<Void, Never>?
    @ObservationIgnored private var spoken = false
    var speakReplies = UserDefaults.standard.object(forKey: "voice.speakReplies") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(speakReplies, forKey: "voice.speakReplies")
            if !speakReplies { speaker.stop() }
        }
    }

    /// Tap the mic: Oby stops talking, and what you say goes to `update` as it's heard. A reply
    /// still on its way stays silent: speaking it would take the microphone's audio session.
    func dictate(update: @escaping (String) -> Void) {
        guard !voice.active, !voice.finishing else { return }
        spoken = false
        speaker.stop()
        voice.start(context: PhoneSpeech.context(repos: jobs.map(\.repo)), update: update)
    }

    func cancelVoice() {
        spoken = false
        voice.cancel()
        speaker.stop()
    }

    /// The app left the front: dictation stops and keeps its words, and a microphone still being
    /// prepared never opens. Except for the permission prompt dictation itself asked for, which
    /// makes the app inactive too: preparation carries on through it.
    func leftForeground(background: Bool) {
        if background || !voice.asking { voice.finish() }
        spoken = false
        speaker.stop()
    }

    /// A runner that isn't a paired Mac, at the address Settings › Runner gives; nil on a fresh
    /// iPhone, which talks to nobody until it pairs (docs/oby-ux.md row 33).
    var runnerURL: URL? {
        didSet {
            UserDefaults.standard.set(runnerURL, forKey: "runner.url")
            stop()
            // Another runner: nothing the last one said holds, and what it pushes with reaches
            // nothing any more (Notifications.swift). Not in `init`, which runs this with oldValue nil.
            if oldValue != nil, runnerURL != oldValue { PushRelay.forget() }
            conversation.forget()
            forgetConversations()
            forgetGitHub()
            echoes = []
            failures = [:]
            requests = [:]
            pending = nil
            restoreQueuedMessages(for: offlineQueueTarget)
            start()
        }
    }
    /// The Mac this iPhone is linked to (#285, apps/shared/RemoteRoute.swift), kept in the defaults;
    /// nil until pairing, or Settings › Your Mac, gives one. Then the Mac is where the calls go.
    var link: MacLink? {
        didSet {
            if oldValue?.identity != link?.identity {
                // What the last Mac pushes with reaches nothing any more (Notifications.swift). Not
                // in `init`, which runs this with oldValue nil (NotificationTests.aLaunchKeepsTheSealingKey).
                if oldValue != nil { PushRelay.forget() }
                conversation.forget()
                forgetConversations()
                forgetGitHub()
                echoes = []
                failures = [:]
                requests = [:]
                pending = nil
            }
            if let link, let data = try? link.encoded() {
                UserDefaults.standard.set(data, forKey: "mac.link")
            } else {
                UserDefaults.standard.removeObject(forKey: "mac.link")
                GatewayTokenStore.remove()
                RelayStore.remove()
                relay = nil
                pairedUntil = nil
            }
            restoreQueuedMessages(for: offlineQueueTarget)
            if loop != nil { finder.find(named: bonjourName) { [weak self] url in self?.lan = url } }
            reroute()
        }
    }
    /// The Mac's Obysphere relay (#1278), when this iPhone paired through it: then every request
    /// goes sealed through it, never to a gateway. Its token and the Mac's pinned key are in the
    /// keychain (RelayStore); a new key comes only with pairing again.
    @ObservationIgnored private(set) var relay: PhoneRelay? {
        didSet { if oldValue !== relay { Task { [oldValue] in await oldValue?.hangUp() } } }
    }
    /// The name Bonjour looks for: none for a Mac reached through its Obysphere, whose gateway
    /// refuses this iPhone's token.
    private var bonjourName: String? { link?.relayed == nil ? link?.name : nil }
    /// The gateway's address on the local network while Bonjour sees the linked Mac (MacFinder);
    /// nil away from home.
    private(set) var lan: URL? {
        didSet { if lan != oldValue { reroute() } }
    }
    /// The way to the Mac now: home or away. Nil with no Mac linked: then the runner at `runnerURL`.
    /// A hostname only chooses a route; the gateway still requires the paired device token. An
    /// old hand-entered link without that token must not send requests to a gateway that will 401.
    var route: RemoteRoute? { RemoteRoute.choose(lan: lan, link: link, paired: GatewayTokenStore.read() != nil) }
    /// Where the calls go: the linked Mac by its route, else the runner.
    var base: URL {
        #if DEBUG
        // `-ObySampleOffline YES`: no runner, the linked Mac's gateway either (the link stays).
        if Self.offline { return Runner.nowhere }
        #endif
        // A linked Mac with no route now (its token unreadable while the iPhone is locked) is
        // reached by nothing else: never another runner's address.
        return route?.url ?? (link == nil ? runnerURL : nil) ?? Runner.nowhere
    }
    /// A stable identity for the logical runner, unaffected by switching between its home and
    /// tunnel routes. Unpaired runners use their configured URL.
    private var offlineQueueTarget: String {
        if let link { return "mac:\(link.relayed == nil ? link.hostname.lowercased() : link.identity)" }
        return "runner:\(runnerURL?.absoluteString ?? "")"
    }
    @ObservationIgnored private let finder = MacFinder()
    var talk: Talk = .none
    private(set) var connection: RunnerConnection
    private(set) var lastSeen: Date? = UserDefaults.standard.object(forKey: "runner.lastSeen") as? Date
    private(set) var host = ""
    /// The job list arrived at least once, so an empty list really is empty.
    private(set) var loaded = false
    /// Your work on GitHub as the Mac's obid finds it (Review PR and Issues), nil from a runner that doesn't list it.
    private(set) var gitHubWork: GitHubWork?
    /// The GitHub items put off with Later, until Oby quits.
    var gitHubLater: Set<String> = []
    /// Bumped by every change of runner, so an answer from the last one is dropped.
    @ObservationIgnored private var gitHubChanges = 0
    /// The session the phone shows (#785): its job's `transcript` events go to it, and it reads
    /// what it missed when the connection comes back.
    @ObservationIgnored var liveSession: LiveSession?
    private(set) var jobs: [Job] = [] {
        didSet {
            // Published, dismissed or running again, here or on the Mac: its alert goes.
            // A question waiting for its answer keeps its alert too.
            let needed = Set(oldValue.filter { $0.needsYou || $0.waitsForAnswer }.map(\.id))
            let done = Set(jobs.filter { !$0.needsYou && !$0.waitsForAnswer && needed.contains($0.id) }.map(\.id))
            if !done.isEmpty { Task { await Notifications.clear(done) } }
            // One Live Activity update at a time, in order.
            syncing = Task { [jobs, syncing] in
                await syncing?.value
                await JobsActivity.sync(jobs)
            }
            // A plain HTTP download: never for a Mac reached sealed, through its Obysphere.
            if link?.relayed == nil { JobWaiter.shared.wait(for: jobs, runner: base) }
        }
    }
    /// The jobs whose pages are open (TaskPage): a new list keeps them, even older than its 50.
    @ObservationIgnored private var onScreen: Set<String> = []
    /// The Live Activity's latest update, so a background wake can wait for it to land.
    @ObservationIgnored private var syncing: Task<Void, Never>?
    private(set) var accounts: [Account] = []
    /// Counts the `routine` events (#395): Settings › Routines reads the routines again on each.
    private(set) var routineChanges = 0
    /// obid's routines (#395), for the next runs on Home's Routines page; none from a runner without.
    private(set) var routines: [RunnerRoutine] = []
    /// What waits in the runner's inbox, put-off items too: answered on the Mac, it goes from here too.
    private(set) var inbox: [InboxItem]
    private let offlineQueue: OfflineQueue
    private(set) var models: ModelSettings?
    /// The mode new jobs get by default, as the runner last said, or nil from a runner without modes.
    private(set) var defaultMode: RunnerMode?
    /// When Clear done was last pressed, here or on the Mac (the runner's clock), or nil: Home
    /// hides the jobs that finished by then. The runner keeps them all.
    private(set) var clearedAt: Date?
    private var loop: Task<Void, Never>?
    /// What's open over Home: the app's one stack.
    var homePath: [Route] = []
    /// The job whose notification's Publish was tapped; its screen publishes once it's ready.
    var publishing: String?

    /// Why the Mac can't be reached, the same line on every screen, or nil.
    var notice: ReachNotice? {
        ReachNotice.of(connection, online: online, status: refusal, paired: link != nil, lastSeen: lastSeen, expires: pairedUntil)
    }
    /// When this iPhone's pairing ends (the gateway's 30 days), from the answer that paired it.
    private(set) var pairedUntil = UserDefaults.standard.object(forKey: "gateway.expiresAt") as? Date {
        didSet { UserDefaults.standard.set(pairedUntil, forKey: "gateway.expiresAt") }
    }
    /// The refusal to keep after a failed request: its status when the runner answered; a 401
    /// stays through errors with none (a dropped connection), until a request succeeds, so the
    /// screen doesn't flip between Connect and Home.
    static func refusal(after error: Error, was: Int?) -> Int? {
        let status = (error as? RunnerError)?.status
        return status == nil && was == 401 ? 401 : status
    }
    /// Connect instead of Home: no Mac and no runner yet, or the Mac stopped taking this iPhone.
    var needsPairing: Bool { Self.needsPairing(linked: link != nil, runner: runnerURL, notice: notice) }
    static func needsPairing(linked: Bool, runner: URL?, notice: ReachNotice?) -> Bool {
        (!linked && runner == nil) || notice == .removed || notice == .expired
    }
    /// This iPhone has a network path (NWPathMonitor).
    private(set) var online = true
    @ObservationIgnored private var path: NWPathMonitor?
    /// The HTTP status of the last refusal (a 401 from the gateway: this iPhone was removed).
    private(set) var refusal: Int?

    init(offlineQueue: OfflineQueue = OfflineQueue(), connection: RunnerConnection = .connecting, inbox: [InboxItem] = []) {
        self.offlineQueue = offlineQueue
        self.connection = connection
        self.inbox = inbox
        runnerURL = UserDefaults.standard.url(forKey: "runner.url")
        #if DEBUG
        // `-ObySampleOffline YES`: the sample screens reach no runner at all, whatever the
        // simulator's settings say (the default runner is a real one).
        if Self.offline, !UserDefaults.standard.bool(forKey: "ObySampleUnpaired") { runnerURL = Runner.nowhere }
        #endif
        // Only a device token the keychain says isn't there unpairs: launched in the background while
        // the iPhone is locked (the Watch asking, an alert's answer), it can't be read, and the
        // pairing stays for when it can.
        if let data = UserDefaults.standard.data(forKey: "mac.link"), !GatewayTokenStore.isMissing() {
            let saved = try? JSONDecoder().decode(MacLink.self, from: data)
            if saved?.relayed != nil {
                // A Mac paired through its Obysphere is reached through its relay alone: never
                // restored as a tunnel pairing, and not at all once its relay is gone.
                if RelayStore.isMissing() {
                    link = nil
                } else {
                    link = saved
                    loadRelay()
                }
            } else {
                link = try? MacLink.paired(data)
            }
        } else {
            // A link saved before gateway pairing cannot authenticate the Mac. Require pairing
            // again instead of restoring a link that sends requests the gateway will reject.
            UserDefaults.standard.removeObject(forKey: "mac.link")
        }
        JobsActivity.watchTokens { [weak self] in self?.runner }
        conversation.page = { [weak self] before, limit in
            guard let self, !startingNew else { return [] }
            let turns = try await runner.conversationTurns(id: current, before: before, limit: limit)
            conversation.note(turns)
            return turns.map(\.turn)
        }
        conversation.lookUp = { [weak self] id in try await self?.runner.artifact(id) }
        offlineQueue.bindUnscopedEntries(to: offlineQueueTarget)
        restoreQueuedMessages(for: offlineQueueTarget)
        #if DEBUG
        if let sample = GitHubWork.sample { gitHubWork = sample }
        if SampleTasks.on { jobs = SampleTasks.jobs; conversations = SampleTasks.conversations; accounts = SampleTasks.accounts; loaded = true; SampleTasks.talk(self) }
        // `-ObySampleUnreachable YES`: the Mac out of reach since 40 minutes ago, for the notice's screenshots.
        if UserDefaults.standard.bool(forKey: "ObySampleUnreachable") { self.connection = .offline(""); self.lastSeen = .now.addingTimeInterval(-2400) }
        #endif
    }

    /// The thread shown: the runner's turns and this iPhone's words for it still on their way, by time.
    var thread: [Turn] {
        let here = echoes.filter { (requests[$0.id]?.conversation ?? nil) == current }
        return conversation.thread(with: ChatThread.pending(here, runner: conversation.runnerTurns))
    }

    /// Opens a conversation's thread: obid's `id`, or nil for the latest (one thread).
    func show(_ id: String?) {
        guard id != current || startingNew else { return }
        current = id
        startingNew = false
        conversation.forget()
        Task { await conversation.reload() }
    }

    /// Where a job's page goes for its conversation: obid's (`.some(id)`), the one thread
    /// (`.some(nil)`) when the runner keeps only that and a turn of it started the job, or nil.
    func conversation(of job: Job) -> String?? {
        if conversations != nil { return job.conversation.map { .some($0) } }
        return ConversationModel.started(job.id, in: conversation.runnerTurns) ? .some(nil) : nil
    }

    /// Another runner: its GitHub feed and what was put off go, and answers still on their way from the last one are dropped.
    private func forgetGitHub() {
        gitHubChanges += 1
        gitHubWork = nil
        gitHubLater = []
    }

    /// Applies obid's answer about GitHub to the feed as it is by then, unless the runner changed meanwhile.
    private func readGitHub(_ ask: () async throws -> GitHubWork?) async {
        let asked = gitHubChanges
        let answer = await GitHubWork.ask(ask)
        guard gitHubChanges == asked else { return }
        gitHubWork = answer.applied(to: gitHubWork)
    }

    private func forgetConversations() {
        conversations = nil
        current = nil
        startingNew = false
        previews = [:]
    }

    /// A conversation's last line, for its row, when this phone hasn't seen one yet.
    func preview(_ id: String) async {
        guard previews[id] == nil, let last = try? await runner.conversation(id: id, limit: 1).last else { return }
        previews[id] = last.text
    }

    /// Renames or pins a conversation; obid's answer puts it in place.
    func update(_ id: String, title: String? = nil, pinned: Bool? = nil) async throws {
        take(try await runner.updateConversation(id, title: title, pinned: pinned))
    }

    /// Forgets a conversation; the jobs it started stay.
    func delete(_ id: String) async throws {
        try await runner.deleteConversation(id)
        take(RunnerConversation(id: id, title: "", deleted: true))
    }

    private func take(_ changed: RunnerConversation) {
        // The conversation Home's words started, named as the turn begins: the thread shown, its
        // steps and Stop are that one's from now on, before Oby's answer comes.
        if startingNew, let pending, let request = requests[pending], request.new,
           !(conversations ?? []).contains(where: { $0.id == changed.id }),
           ConversationOrder.started(by: request.said, changed) {
            adopt(changed.id, echo: pending)
        }
        if let list = conversations { conversations = ConversationOrder.placed(changed, in: list) }
        if changed.deleted, changed.id == current { show(nil) }
        if changed.deleted { Drafts.keep("", as: Drafts.conversation(changed.id)) }
    }

    var runner: Runner {
        // Paired with a Mac, a 401 means the pairing ended: say which, never the Tailscale line.
        let refused = link.map { _ in (pairedUntil.map { $0 <= .now } ?? false) ? ReachNotice.expired : ReachNotice.removed }
        return Runner(base: base, token: GatewayTokenStore.read(), refused: refused.map { "\($0.title). \($0.detail)" },
                      relay: base == RemoteRoute.relayBase ? loadRelay() : nil)
    }

    /// The relay of a Mac paired through its Obysphere: read from the keychain once it can be (not
    /// while the iPhone is locked: a Watch request after unlocking finds it here, in the background
    /// too), and only the one the link pinned.
    @discardableResult
    private func loadRelay() -> PhoneRelay? {
        if relay == nil, let pinned = link?.relayed, let kept = RelayStore.read(), kept.pinned == pinned { relay = PhoneRelay(kept) }
        return relay
    }

    /// Pairs with a Mac's gateway (#284): the invitation's QR secret or its six-digit code buys this
    /// iPhone's device token, kept in the keychain, and the Mac becomes the linked one. The QR code
    /// carries the Mac's link; a typed code learns it from the answer.
    func pairGateway(url: URL, credential: String, link: MacLink? = nil) async throws {
        let answer = try await GatewayPairing.redeem(at: url, credential: credential, name: UIDevice.current.name)
        guard var link = link ?? answer.link else {
            throw RunnerError(message: "The Mac didn't say how to reach it away from home. Pair with its QR code instead.")
        }
        link.relayed = nil
        RelayStore.remove()
        relay = nil
        pairedUntil = answer.expiresAt
        refusal = nil
        self.link = link
    }

    /// Pairs through the Mac's Obysphere (#1278): the QR code's secret, sealed to the Mac's key from
    /// the same code, buys the device token, and the relay with that key is kept in the keychain.
    /// Only a new QR code from the Mac pins another key.
    func pairRelay(_ link: RelayLink, credential: String, mac: MacLink, connect: @escaping PhoneRelay.Connect = PhoneRelay.urlSession) async throws {
        let relay = PhoneRelay(link, connect: connect)
        do {
            let answer = try await GatewayPairing.redeem(at: RemoteRoute.relayBase, credential: credential, name: UIDevice.current.name) {
                try await relay.data(for: $0)
            }
            do { try RelayStore.save(link) } catch {
                GatewayTokenStore.remove()
                throw error
            }
            pairedUntil = answer.expiresAt
        } catch {
            // Nothing paired: its socket goes too.
            await relay.hangUp()
            throw error
        }
        self.relay = relay
        refusal = nil
        var mac = mac
        mac.relayed = link.pinned
        self.link = mac
    }
    var active: [Job] { jobs.filter(\.isActive) }
    var signedIn: [Account] { accounts.filter(\.signedIn) }

    /// The jobs Home lists: all but the settled ones (`Job.settled`) that finished by the last Clear
    /// done, newest first. Home puts them in their groups (JobList.groups), as the Mac's window does.
    var visibleJobs: [Job] { jobs.filter { $0.listed(after: clearedAt, among: jobs) && ($0.isActive || !archivedHere.contains($0.id)) } }

    // MARK: Staying live

    /// The app is in front: looks for the linked Mac on the local network, and follows the runner
    /// (or the Mac) from there.
    func start() {
        finder.find(named: bonjourName) { [weak self] url in self?.lan = url }
        // Its keychain item couldn't be read at launch (the iPhone was locked): now it can.
        loadRelay()
        // Opening the app is the person asking: the relay may open again at once.
        Task { [relay] in await relay?.resume() }
        if path == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] update in
                let online = update.status == .satisfied
                Task { @MainActor in self?.online = online }
            }
            monitor.start(queue: .main)
            path = monitor
        }
        follow()
    }

    /// The app went to the background: no connection, no battery spent.
    func stop() {
        finder.stop()
        path?.cancel()
        path = nil
        unfollow()
        Task { [relay] in await relay?.hangUp() }
    }

    /// The way to the Mac changed (home to away, or back, or just paired): followed anew, keeping
    /// the thread, while the app is in front (`path` watches the network only then).
    private func reroute() {
        guard path != nil else { return }
        unfollow()
        follow()
    }

    /// Follows the runner's events and, once it's following, fetches everything; after any drop it
    /// tries again, waiting a little longer each time.
    private func follow() {
        guard loop == nil else { return }
        #if DEBUG
        // `-ObySampleOffline YES`: the sample screens reach no runner at all (a simulator's
        // settings may name a real one).
        if Self.offline { return }
        #endif
        // Nobody to follow yet: Connect is the first screen.
        guard route != nil || runnerURL != nil else { return }
        loop = Task {
            var wait = 1.0
            while !Task.isCancelled {
                do {
                    // Following first, then fetching (`connected`): what changes in between waits in
                    // the stream and applies over what was fetched.
                    for try await event in runner.events() {
                        guard case .connected = event else { apply(event); continue }
                        try await connected()
                        wait = 1
                    }
                } catch {
                    if Task.isCancelled { return }
                    refusal = Self.refusal(after: error, was: refusal)
                    connection = .offline(error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(wait))
                wait = min(wait * 2, 15)
            }
        }
    }

    /// The runner follows this app now: everything it has, fetched.
    private func connected() async throws {
        let status = try await runner.status()
        host = status.runner.host
        accounts = status.accounts
        models = status.models
        clearedAt = status.clearedAt
        defaultMode = RunnerMode(status.permissions?.mode)
        await take(try await runner.jobs())
        inbox = try await runner.inbox()
        await readGitHub { try await runner.gitHubWork() }
        await readRoutines()
        do { conversations = try await runner.conversations() } catch {
            Logger.phone.error("listing conversations failed: \(error.localizedDescription, privacy: .public)")
        }
        // The thread's latest page every time: what was said on the Mac while the connection was
        // down is in it.
        await conversation.reload()
        loaded = true
        // Alerts whose job needs nothing any more, if their clearing push didn't arrive.
        await Notifications.clear(Set(jobs.filter { !$0.needsYou && !$0.waitsForAnswer }.map(\.id)))
        connection = .live
        refusal = nil
        lastSeen = .now
        UserDefaults.standard.set(lastSeen, forKey: "runner.lastSeen")
        // Jobs dispatched from the Mac or the runner API notify too, so ask on connecting.
        Notifications.ask()
        await flushQueued()
        await flushQueuedInbox()
        do { _ = try await registerDevice(again: true) } catch {
            Logger.phone.error("registering this iPhone failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// iOS woke Oby because a job ended (JobWaiter): fetch the list, and wait until the Live
    /// Activity says how it ended before iOS suspends Oby again.
    func catchUp() async {
        JobWaiter.shared.reconnect()
        guard let fresh = try? await runner.jobs() else { return }
        await take(fresh)
        await syncing?.value
    }

    /// obid's routines again; an answer that fails keeps what was read.
    func readRoutines() async {
        do { routines = try await runner.routines() ?? [] } catch {
            Logger.phone.error("listing routines failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pull to refresh: fetch the job list now, without waiting for the runner's next event.
    func reload() async {
        do {
            await take(try await runner.jobs())
            inbox = try await runner.inbox()
            await readGitHub { try await runner.gitHubWork() }
            loaded = true
        } catch {
            Logger.phone.error("reloading jobs failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Has the Mac's obid read GitHub again; the feed it answers replaces this one.
    func refreshGitHubWork() async {
        #if DEBUG
        if GitHubWork.sample != nil { return }
        #endif
        await readGitHub { try await runner.refreshGitHubWork() }
    }

    /// One tap on a GitHub item: Oby's job on it (a review, or a fix), listed at once.
    func startGitHubWork(_ id: String) async throws {
        let asked = gitHubChanges
        let job = try await runner.startGitHubWork(id)
        guard gitHubChanges == asked else { return }
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
    }

    private func unfollow() {
        loop?.cancel()
        loop = nil
        if connection == .live { connection = .connecting }
        JobsActivity.markStale()
    }

    #if DEBUG
    /// Debug builds launched with `-ObySampleOffline YES`, or run with `OBY_OFFLINE=1` (a test
    /// host: `TEST_RUNNER_OBY_OFFLINE=1 xcodebuild test`), reach no runner at all: a simulator's
    /// default runner is a real one.
    static let offline = UserDefaults.standard.bool(forKey: "ObySampleOffline") || ProcessInfo.processInfo.environment["OBY_OFFLINE"] == "1"

    /// The sample screens' made-up events (SampleTasks), through the same path as obid's.
    func sample(_ event: RunnerEvent) { apply(event) }
    #endif

    private func apply(_ event: RunnerEvent) {
        switch event {
        case .job(let job):
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.insert(job, at: 0) }
        case .accounts(let accounts):
            self.accounts = accounts
        case .cleared(let date):
            clearedAt = date
        case .connected:
            if let liveSession { Task { await liveSession.catchUp() } }
        case .inbox(let item):
            // One that's done leaves the list.
            inbox.removeAll { $0.id == item.id }
            if item.isOpen { inbox.append(item) }
        case .turn(let turn, let extras):
            if let id = turn.conversation { previews[id] = turn.text }
            if turn.conversation == nil || (turn.conversation == current && !startingNew) { conversation.apply(turn, extras) }
            // The runner listed what this iPhone said: its echo has done its job.
            settleEchoes()
        case .step(let step):
            if ConversationOrder.shows(step, in: current, startingNew: startingNew) { conversation.apply(step) }
        case .delta(let delta):
            if ConversationOrder.shows(delta.conversation, in: current, startingNew: startingNew) { conversation.apply(delta) }
            else if startingNew, delta.conversation != nil { heldDeltas.append(delta) }
        case .artifact(let artifact):
            conversation.apply(artifact)
        case .github(let work):
            gitHubWork = work
        case .conversation(let changed):
            take(changed)
        case .routine:
            routineChanges += 1
            Task { await readRoutines() }
        case .transcript(let event):
            liveSession?.apply(event)
        }
    }

    /// Drops the echoes the runner has listed, with what went with them.
    private func settleEchoes() {
        echoes = ChatThread.pending(echoes, runner: conversation.runnerTurns)
        let kept = Set(echoes.map(\.id))
        failures = failures.filter { kept.contains($0.key) }
        requests = requests.filter { kept.contains($0.key) }
    }

    /// Lets go of an echo: cancelled, edited, or sent again.
    private func drop(echo id: String) {
        echoes.removeAll { $0.id == id }
        failures[id] = nil
        requests[id] = nil
        if pending == id { pending = nil }
    }

    // MARK: Planning

    /// `new`: Home's box, which starts a conversation of its own on obid (#493); the thread then
    /// holds just these words until obid names it.
    func ask(_ words: String, spoken: Bool = false, new: Bool = false) {
        guard let said = ChatThread.words(words) else { return }
        cancelVoice()
        self.spoken = spoken
        let starts = new && conversations != nil
        if starts {
            current = nil
            startingNew = true
            heldDeltas = []
            conversation.forget()
        }
        plan(said, answer: nil, voice: spoken, new: starts)
    }

    /// The user picked one of the brain's options.
    func answer(_ option: String, said: String, question: Question) {
        plan(said, answer: (question.text, option))
    }

    /// Why Stop didn't go through, under the steps; nil once it did or a new turn began.
    private(set) var stopProblem: String?

    /// Stop: the runner ends the turn Oby is working on (`POST /v1/conversation/stop`), and what
    /// ran meanwhile shows as ended. The request for the plan stays: the runner answers it.
    func stopTurn() async {
        do {
            // obid stops the latest turn in any conversation unless it's told which (#493).
            try await runner.stopConversation(talkIn ?? current)
            stopProblem = nil
            conversation.settleSteps()
        } catch let error as RunnerError where error.status == 404 {
            stopProblem = "This runner can't stop a turn yet."
        } catch {
            stopProblem = error.localizedDescription
        }
    }

    func cancel() {
        planning?.cancel()
        planning = nil
        spoken = false
        speaker.stop()
        // The words the user gave up on leave the thread, as on the Mac; the runner still lists
        // them with its answer if it got them, and then they show.
        dropPending()
        talk = .none
    }

    /// Lets go of the request under way's echo, if it's still in the thread.
    private func dropPending() {
        if let pending { drop(echo: pending) }
        pending = nil
    }

    /// Try again on words that didn't go through: the same request, sent anew.
    func retry(echo id: String) {
        guard let request = requests[id] else { return }
        removeQueued(id)
        drop(echo: id)
        // The same id: if the first request reached obid after all, it keeps the words once.
        plan(request.said, answer: request.answer, voice: request.voice, new: request.new, id: id)
    }

    /// Edit on words that didn't go through: they leave the thread for the field.
    func discard(echo id: String) {
        removeQueued(id)
        drop(echo: id)
    }

    /// `id`: the echo's, given again by Try again; obid's turn of the words takes it.
    private func plan(_ said: String, answer: (question: String, option: String)?, voice: Bool = false, new: Bool = false,
                      id: String = UUID().uuidString.lowercased()) {
        planning?.cancel()
        speaker.stop()
        dropPending()
        stopProblem = nil
        talk = .thinking(said)
        // The thread shows the words as the runner will list them: an answer is its option.
        let echo = Turn(id: id, who: .user, text: answer?.option ?? said, voice: voice ? true : nil)
        echoes.append(echo)
        let request = Request(said: said, answer: answer, voice: voice, conversation: current, new: new)
        requests[echo.id] = request
        talkIn = current
        pending = echo.id
        if connection != .live {
            offlineQueue.queue(OfflineMessage(id: echo.id, said: said, question: answer?.question, option: answer?.option, voice: voice,
                                              target: offlineQueueTarget, conversation: request.conversation, new: request.new ? true : nil))
            talk = .queued(said)
            pending = nil
            return
        }
        send(request, echo: echo)
    }

    private func removeQueued(_ id: String) {
        offlineQueue.removeMessage(id)
    }

    private func restoreQueuedMessages(for target: String) {
        for item in offlineQueue.messages where item.target == target {
            requests[item.id] = Request(said: item.said, answer: item.question.flatMap { question in item.option.map { (question, $0) } }, voice: item.voice,
                                        conversation: item.conversation, new: item.new ?? false)
            if !echoes.contains(where: { $0.id == item.id }) {
                echoes.append(Turn(id: item.id, who: .user, text: item.option ?? item.said, voice: item.voice ? true : nil))
            }
        }
    }

    private func flushQueued() async {
        let target = offlineQueueTarget
        guard offlineQueue.messages.contains(where: { $0.target == target }) else { return }
        let destinationRunner = runner
        await offlineQueue.flushMessages(for: target) { [weak self] item in
            guard let self else { throw CancellationError() }
            let request = requests[item.id] ?? Request(
                said: item.said,
                answer: item.question.flatMap { question in item.option.map { (question, $0) } },
                voice: item.voice,
                conversation: item.conversation,
                new: item.new ?? false
            )
            let echo = echoes.first(where: { $0.id == item.id }) ?? Turn(id: item.id, who: .user, text: item.option ?? item.said, voice: item.voice ? true : nil)
            let planned = try await destinationRunner.planned(request.said, answer: request.answer,
                                                              conversation: request.conversation, new: request.new, id: item.id)
            apply(planned, request: request, echo: echo)
        }
    }

    private func flushQueuedInbox() async {
        let target = offlineQueueTarget
        guard offlineQueue.answers.contains(where: { $0.target == target }) else { return }
        let destinationRunner = runner
        await offlineQueue.flushAnswers(for: target) { [weak self] item in
            guard let self else { throw CancellationError() }
            do {
                apply(.inbox(try await destinationRunner.settle(item.id, answer: item.answer, done: item.done, later: item.later)))
            } catch {
                if OfflineQueue.isAlreadySettled(error) {
                    throw OfflineQueue.FlushError.alreadySettled
                }
                throw error
            }
        }
    }

    private func send(_ request: Request, echo: Turn) {
        planning = Task {
            do {
                let planned = try await runner.planned(request.said, answer: request.answer,
                                                       conversation: request.conversation, new: request.new, id: echo.id)
                guard !Task.isCancelled else { return }
                apply(planned, request: request, echo: echo)
            } catch {
                // The request didn't go through (or the runner answered with an error): the words
                // stay in the thread with why, to try again or edit. If the runner got them after
                // all (a timeout), its turn settles the echo as usual.
                if !Task.isCancelled {
                    failures[echo.id] = error.localizedDescription
                    finish(.reply(error.localizedDescription), started: [], request: request, echo: echo)
                }
            }
        }
    }

    /// Applies a response the runner accepted, shared by live sends and the sequential offline
    /// flush. The queue removes its message only after this operation's network call succeeds.
    private func apply(_ planned: PlannedTurn, request: Request, echo: Turn) {
        if request.new, let id = planned.conversation { adopt(id, echo: echo.id) }
        let result = planned.result
        let talk: Talk
        let started: [Job]
        switch result {
        case .question(let said, let question):
            talk = .question(said: said, question)
            started = []
        case .reply(let text, let jobs):
            talk = .reply(text)
            started = jobs
        case .none:
            talk = .none
            started = []
        }
        finish(talk, started: started, request: request, echo: echo)
    }

    /// obid named the conversation Home's words started: the words, Oby's answer and the thread
    /// shown (when it's still that one) are that conversation's now.
    private func adopt(_ id: String, echo: String) {
        requests[echo]?.conversation = id
        requests[echo]?.new = false
        if talkIn == nil { talkIn = id }
        guard startingNew else { return }
        startingNew = false
        current = id
        for delta in heldDeltas where delta.conversation == id { conversation.apply(delta) }
        heldDeltas = []
        Task { await conversation.reload(arriving: true) }
    }

    private func finish(_ talk: Talk, started: [Job], request: Request, echo: Turn) {
        if pending == echo.id { pending = nil }
        // Answered: the runner has the words, whatever its event missed (a failure keeps them).
        if failures[echo.id] == nil { drop(echo: echo.id) }
        conversation.settleLatestSteps()
        self.talk = talk
        for job in started { apply(.job(job)) }
        if !started.isEmpty { Notifications.ask() }
        if request.voice, speakReplies {
            switch talk {
            case .reply(let text): speaker.say(text)
            case .question(_, let question): speaker.say(question.text)
            default: break
            }
        }
    }

    // MARK: Jobs

    /// A notification was tapped: open its job on Home, and publish it if that's what was tapped.
    func open(_ id: String, publish: Bool) {
        panel = nil
        homePath = [.task(id)]
        publishing = publish ? id : nil
    }

    /// A notification about a conversation was tapped: its thread opens on Home.
    func open(conversation id: String) {
        panel = nil
        homePath = [.conversation(id)]
    }

    func stop(_ id: String) async throws {
        apply(.job(try await runner.stop(id)))
    }

    /// Stop all: every job on the runner stops now, and shows here as stopped.
    func stopAll() async throws {
        for job in try await runner.stopAll().jobs { apply(.job(job)) }
    }

    /// Lets go of a job that needs you; its alert clears with the runner's answer.
    func dismiss(_ id: String) async throws {
        apply(.job(try await runner.dismiss(id)))
    }

    /// Starts a job that waits for its start condition now (#216).
    func startNow(_ id: String) async throws {
        apply(.job(try await runner.startNow(id)))
    }

    /// Moves a job to another tool, account or model; the runner picks what's left nil.
    func move(_ id: String, agent: String?, account: String?, model: String?) async throws {
        apply(.job(try await runner.move(id, agent: agent, account: account, model: model)))
    }

    /// Clear done: the runner records the time, and Home here and the Mac's window hide the jobs
    /// that finished by then.
    func clear() async throws {
        clearedAt = try await runner.clear()
    }

    /// Settles an inbox item: an answer goes to its job, `done` lets it go, `later` puts it off.
    func settle(_ id: String, answer: String? = nil, done: Bool? = nil, later: Date? = nil) async throws {
        // Only the owner's tap confirms (#776): Face ID signs the item's title. A Confirm is never
        // queued offline (its signature is stale after two minutes); Cancel and Later still are.
        if answer == "Confirm", let item = inbox.first(where: { $0.id == id && $0.kind == "confirm" }) {
            guard connection == .live else { throw RunnerError(message: Self.confirmNeedsTheMac) }
            guard DeviceKey.isAvailable else { throw RunnerError(message: "Confirming needs Face ID on your iPhone.") }
            let device = try await registerDevice()
            let title = item.title
            let approval: Approval
            do {
                approval = try await Task.detached { try DeviceKey.approveConfirm(item: id, title: title, device: device) }.value
            } catch {
                throw RunnerError(message: "Nothing was confirmed: Face ID didn't approve it.")
            }
            apply(.inbox(try await runner.settle(id, answer: "Confirm", approval: approval)))
            return
        }
        guard connection == .live else {
            // The decision stays where it is, marked, until obid takes the answer (or says it was
            // settled meanwhile: then the inbox fetched on connecting no longer has it).
            offlineQueue.queue(OfflineInboxAnswer(id: id, answer: answer, done: done, later: later, target: offlineQueueTarget))
            return
        }
        apply(.inbox(try await runner.settle(id, answer: answer, done: done, later: later)))
    }

    /// A job's screen opened or closed: while it's open, new lists keep its job.
    func showing(_ id: String, _ shown: Bool) {
        if shown { onScreen.insert(id) } else { onScreen.remove(id) }
    }

    /// A new list from the runner, the latest 50. A job whose screen is open stays even when it's
    /// older than those, fetched again so it's current.
    private func take(_ fresh: [Job]) async {
        let (kept, refetch) = JobList.keeping(fresh, old: jobs, onScreen: onScreen, id: \.id, created: \.created)
        var list = kept
        #if DEBUG
        if SampleTasks.on { list = SampleTasks.jobs.filter { sample in !list.contains { $0.id == sample.id } } + list }
        #endif
        jobs = list
        for id in refetch {
            guard let job = try? await runner.job(id) else { continue }
            jobs = JobList.placed(job, in: jobs, id: \.id, created: \.created)
        }
    }

    /// A job older than the list's 50 (an inbox item or a notification opened it): fetched, and
    /// kept among the others in age order.
    func fetch(_ id: String) async {
        guard !jobs.contains(where: { $0.id == id }) else { return }
        do {
            let job = try await runner.job(id)
            guard !jobs.contains(where: { $0.id == id }) else { return }
            jobs = JobList.placed(job, in: jobs, id: \.id, created: \.created)
        } catch {
            Logger.phone.error("fetching job \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tells the job's agent something; the runner answers with the job, running again.
    func tell(_ id: String, _ text: String) async throws {
        apply(.job(try await runner.tell(id, text)))
    }

    /// The exact sentence publishing this job would carry out.
    func publishAction(_ id: String) async throws -> String {
        try await runner.publishAction(id)
    }

    /// Face ID signs the action; the runner checks the signature, then pushes and opens a draft PR.
    func publish(_ id: String, action: String) async throws -> URL {
        guard DeviceKey.isAvailable else { throw RunnerError(message: "Publishing needs Face ID on your iPhone.") }
        let device = try await registerDevice()
        let approval = try await Task.detached { try DeviceKey.approve(job: id, action: action, device: device) }.value
        let url = try await runner.publish(id, approval: approval)
        if var job = jobs.first(where: { $0.id == id }) {
            job.published = url.absoluteString
            apply(.job(job))
        }
        return url
    }

    // MARK: Permissions

    /// Changes a running job's mode (the job screen's Mode menu).
    func setMode(_ id: String, _ mode: RunnerMode) async throws {
        apply(.job(try await runner.setMode(id, mode)))
    }

    /// Allow, Always allow or Deny on what a job's agent waits for; words go with a deny.
    func answer(_ job: Job, _ decision: RunnerPermission.Decision, message: String? = nil) async throws {
        guard let permission = job.permission else { return }
        apply(.job(try await runner.answer(job.id, permission: permission.id, decision, message: message)))
    }

    /// An alert's answer (#865, Notifications.swift) to the inbox item it showed, which obid refuses
    /// with 409 when it was answered already. Never queued: the alert says when it didn't go.
    func answer(alert item: String, _ answer: String) async throws {
        apply(.inbox(try await runner.settle(item, answer: answer)))
    }

    /// Settings › Permissions: the mode new jobs get.
    func setDefaultMode(_ mode: RunnerMode) async throws {
        try await runner.setDefaultMode(mode)
        defaultMode = mode
    }

    // MARK: Models

    func setModels(_ models: ModelSettings) async throws {
        self.models = try await runner.setModels(models)
    }

    // MARK: This phone's publishing key

    /// What a Confirm says without a connection to the Mac: it isn't queued (#776).
    nonisolated static let confirmNeedsTheMac = "Confirm needs a connection to your Mac."

    /// By the linked Mac (its identity: the hostname, the same at home and away, or its relay and key), or by the runner's.
    private var deviceKey: String { "device.\(link?.identity ?? runnerURL?.host() ?? runnerURL?.absoluteString ?? "")" }
    var deviceID: String? { UserDefaults.standard.string(forKey: deviceKey) }

    /// Registers the phone's Face ID key with the runner and returns its id. On every connection it
    /// registers `again`: the runner keeps a known key's id, and a reinstalled runner learns it anew.
    func registerDevice(again: Bool = false) async throws -> String {
        if !again, let deviceID { return deviceID }
        guard DeviceKey.isAvailable else { throw RunnerError(message: "Publishing needs Face ID on your iPhone.") }
        let id = try await runner.register(name: "iPhone", publicKey: try DeviceKey.publicKey())
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }
}

extension Logger {
    nonisolated static let phone = Logger(subsystem: "com.deskree.oby", category: "phone")
}

/// Redeeming a pairing invitation at a Mac's gateway (`POST /v1/pairing`, docs/runner-api.md):
/// the credential is the QR code's secret or the six digits the Mac shows, and the answer's token
/// goes to the keychain (GatewayTokenStore) and nowhere else. Tests give their own transport.
enum GatewayPairing {
    struct Answer: Decodable, Equatable {
        var token: String
        /// The Mac's name and tunnel hostname, so a typed code links the Mac as the QR code would.
        var link: MacLink?
        /// When the pairing ends: 30 days (docs/runner-api.md, "Redeeming").
        var expiresAt: Date?
    }

    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    static func redeem(at url: URL, credential: String, name: String,
                       transport: Transport = { try await URLSession.shared.data(for: $0) }) async throws -> Answer {
        struct Body: Encodable { var credential: String; var name: String }
        var request = URLRequest(url: url.appending(path: "v1/pairing"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Runner.encoder.encode(Body(credential: credential, name: name))
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let said = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw RunnerError(message: said ?? "The Mac refused this pairing invitation.", status: (response as? HTTPURLResponse)?.statusCode)
        }
        let answer = try Runner.decoder.decode(Answer.self, from: data)
        try GatewayTokenStore.save(answer.token)
        return answer
    }
}

/// This iPhone's device token for the linked Mac's gateway, in the keychain only.
enum GatewayTokenStore {
    private static let service = "com.deskree.oby.gateway"

    /// Whether the keychain says there's no such item: not when it can't be read now (the iPhone
    /// locked, a background launch), which isn't the same as gone.
    static func isMissing(account: String = "device-token") -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound
    }

    static func read(account: String = "device-token") -> String? {
        var result: AnyObject?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, account: String = "device-token") throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        try Self.validateSave(updateStatus: status) {
            SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }

    static func validateSave(updateStatus: OSStatus, add: () -> OSStatus) throws {
        guard updateStatus == errSecSuccess || updateStatus == errSecItemNotFound else {
            throw RunnerError(message: "The iPhone couldn't keep the Mac's device token.")
        }
        if updateStatus == errSecItemNotFound, add() != errSecSuccess {
            throw RunnerError(message: "The iPhone couldn't keep the Mac's device token.")
        }
    }

    static func remove(account: String = "device-token") {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// The Mac's Obysphere relay this iPhone paired through (RelayLink): beside the device token, in
/// the keychain only and on this device only (no backup or iCloud copy carries it), so its token and
/// the Mac's pinned key never reach the defaults. Pairing again replaces it; unpairing deletes it.
enum RelayStore {
    static func read() -> RelayLink? {
        GatewayTokenStore.read(account: "relay").flatMap { try? JSONDecoder().decode(RelayLink.self, from: Data($0.utf8)) }
    }

    static func save(_ link: RelayLink) throws {
        try GatewayTokenStore.save(String(decoding: try JSONEncoder().encode(link), as: UTF8.self), account: "relay")
    }

    static func isMissing() -> Bool { GatewayTokenStore.isMissing(account: "relay") }

    static func remove() { GatewayTokenStore.remove(account: "relay") }
}
