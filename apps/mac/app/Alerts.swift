import AppKit

/// Where an alert opens the window, and what the window may be showing already.
nonisolated enum AlertPlace: Equatable, Sendable {
    /// A runner job's page.
    case job(String)
    /// One of this Mac's own jobs (the Swift desk's).
    case localJob(String)
    case conversation(String)
    /// The window, on the conversation shown.
    case window

    /// What the window shows on `top`, with `conversation` the conversation shown: nil for Home,
    /// Settings and the rest, where no alert's thing is.
    static func shown(_ top: WindowStep?, conversation: String?) -> AlertPlace? {
        switch top {
        case .job(let id, let local): local ? .localJob(id) : .job(id)
        case .session(let id): .job(id)
        case .talk: conversation.map(AlertPlace.conversation)
        default: nil
        }
    }
}

/// One Mac alert, as the feed posts it: macOS replaces an alert with the same `id`, and stacks
/// those with the same `thread` (one job's, one conversation's).
nonisolated struct Alert: Equatable, Sendable {
    var id: String
    var title: String
    var subtitle = ""
    var body: String
    var category: Category
    var thread: String
    /// The ids the click and the buttons act on (`Alerts.answer`).
    var info: [String: String] = [:]
    /// The options its buttons pick, in their order: an answer names the alert's own, never newer ones.
    var options: [String] = []
    var sound = true

    /// Its buttons under Options, and the Reply field when there is one.
    nonisolated struct Category: Equatable, Hashable, Sendable {
        var id: String
        var buttons: [Button]
        /// The Reply field's placeholder, or nil for none.
        var reply: String?
    }

    nonisolated struct Button: Equatable, Hashable, Sendable {
        var id: String
        var title: String
        var destructive = false
        /// Opens the window (Open, Publish with Touch ID); every other button answers from the alert,
        /// and only on an unlocked Mac.
        var opens = false
    }
}

/// What Oby alerts for, and what an alert's buttons do (#862, #863, #613). The owner's rule of
/// 2026-10-23: an alert only when something needs the owner, when a job they started ends, when Oby
/// answers away from the window, or when an outside item needs them; never for progress, an FYI, or
/// what the window shows. One alert per thing, replaced in place, gone once it's settled anywhere.
/// An alert says only obid's own words (an item's `title` and `text`), never a quoted field.
enum Alerts {
    static let inboxKey = "inbox"
    static let conversationKey = "conversation"
    static let saidKey = "said"
    static let questionKey = "question"
    static let optionsKey = "options"
    /// What a job's alert said (`RunnerFeed.said`): its Reply goes only while the job still needs that.
    static let noticeKey = "notice"

    static let openButton = Alert.Button(id: "open", title: "Open", opens: true)
    static let replyButton = "reply"
    static let startButton = "start"
    static let alwaysButton = "always"
    /// "option.0": the alert's first option.
    static func optionButton(_ index: Int) -> String { "option.\(index)" }

    /// Words an answer takes, as obid's `POST /v1/inbox/{id}/answer` and a deny's `message` do.
    static let mostWords = 2000
    /// What a collapsed alert shows of its body, where its buttons are pressed: three lines of the
    /// system font at 13 points, 269 points wide (measured on macOS 27, 2026-10-23), taken a little
    /// smaller here.
    // ponytail: the banner as measured; measure it again if macOS draws it differently.
    static let shownLines = 3
    static let shownWidth: CGFloat = 260
    static let shownFont = NSFont.systemFont(ofSize: 13.5)

    /// An ask shows whole in a collapsed alert: plain text (no control character but a newline or a
    /// tab, no format character such as a bidi override or a zero-width space, no other line or
    /// paragraph separator, which could hide or reorder what's shown), at most `shownLines` lines as
    /// macOS wraps them. Only then may the alert allow or start it: nothing is allowed or started
    /// that the owner couldn't read.
    static func fits(_ text: String) -> Bool {
        let plain = text.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control: scalar == "\n" || scalar == "\t"
            case .format, .lineSeparator, .paragraphSeparator: false
            default: true
            }
        }
        guard plain else { return false }
        let size = NSSize(width: shownWidth, height: .greatestFiniteMagnitude)
        let height = (text as NSString).boundingRect(with: size, options: .usesLineFragmentOrigin, attributes: [.font: shownFont]).height
        return Int((height / NSLayoutManager().defaultLineHeight(for: shownFont)).rounded()) <= shownLines
    }

    /// The lines with something on them: an alert shows no blank ones.
    static func compact(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
    }

    /// The first lines of `text`, at most `most` characters.
    static func lines(_ text: String, most: Int = 200) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= most ? text : String(text.prefix(most - 1)) + "…"
    }

    // MARK: The inbox's own asks (#862)

    /// An inbox item alerts by itself: open, not put off, from the last hour (an older one is a
    /// replay), not told already, and a decision only the owner makes that no job's alert says: a
    /// Confirm, a Start (not a teammate's request, which reads as one), a question (the orchestrator's,
    /// the supervisor's) unless its job alerts for it (`jobAlerts`), or a permission with no job (the
    /// conversation's shell). A job's own permission alerts as the job.
    static func alerts(_ item: InboxItem, kind: String, jobAlerts: Bool, told: Set<String>, now: Date) -> Bool {
        guard item.waiting(at: now), item.created > now.addingTimeInterval(-3600), !told.contains(item.id) else { return false }
        switch kind {
        case RunnerConfirm.kind: return true
        case "start": return item.options.contains(Inbox.start)
        case "question": return !jobAlerts
        case "permission": return item.job.isEmpty
        default: return false
        }
    }

    /// The delivered alerts an inbox list settles: those of items that don't wait any more (answered,
    /// done or put off on any app, while this Mac was away, or before Oby last quit). `delivered`: each
    /// alert's identifier and its item's id.
    static func stale(_ delivered: [(id: String, item: String)], waiting: Set<String>) -> [String] {
        delivered.filter { !waiting.contains($0.item) }.map(\.id)
    }

    /// The conversation a shell ask is about: its id is `shell-<conversation>-<permission>`.
    static func shellConversation(_ id: String) -> String? {
        guard id.hasPrefix("shell-"), let dash = id.lastIndex(of: "-"), dash > id.index(id.startIndex, offsetBy: 5) else { return nil }
        return String(id[id.index(id.startIndex, offsetBy: 6)..<dash])
    }

    /// Where an item's card is: its job's page, else the conversation it came from.
    static func place(of item: InboxItem, conversation: String?) -> AlertPlace {
        if !item.job.isEmpty { return .job(item.job) }
        return (conversation ?? shellConversation(item.id)).map(AlertPlace.conversation) ?? .window
    }

    /// The item's alert: its title, its text, and its answers. Allow and Start only when the text shows
    /// whole (`fits`). The shell's Always allow stays in the window: the item doesn't say which rule it
    /// saves. A Confirm only opens its card, so the owner reads all of what it does and confirms it with
    /// Touch ID there (#776).
    static func alert(for item: InboxItem, kind: String, conversation: String?) -> Alert {
        let place = Self.place(of: item, conversation: conversation)
        let text = compact(item.text)
        let whole = fits(text)
        var alert = Alert(id: item.id, title: item.title, body: whole ? text : lines(text),
                          category: Alert.Category(id: "inbox.open", buttons: [openButton]), thread: thread(place))
        alert.info = info(place)
        alert.info[inboxKey] = item.id
        switch kind {
        case "permission" where whole:
            alert.category = Alert.Category(id: "inbox.permission", buttons: [
                Alert.Button(id: RunnerFeed.allowButton, title: Inbox.allow),
                Alert.Button(id: RunnerFeed.denyButton, title: Inbox.deny, destructive: true), openButton,
            ])
        case "permission":
            alert.category = Alert.Category(id: "inbox.deny", buttons: [Alert.Button(id: RunnerFeed.denyButton, title: Inbox.deny, destructive: true), openButton])
        case "start" where whole:
            alert.category = Alert.Category(id: "inbox.start", buttons: [Alert.Button(id: startButton, title: Inbox.start), openButton])
        case "question":
            alert.options = Array(item.options.prefix(Plan.Question.mostOptions))
            alert.category = options(alert.options, reply: "Reply to Oby…", prefix: "inbox.question")
        default: break
        }
        return alert
    }

    // MARK: Oby's answers (#862)

    /// Oby answered in a conversation the window isn't showing: a turn of Oby's in a conversation obid
    /// listed (`known`), not the one a job adds when it ends (its own alert says so), nor a routine's
    /// (a run started: progress), recent (an old one changed: a job dispatched from it), not told yet,
    /// and not the words beside an ask of that conversation's that alerted in the last minute
    /// (`asked`: a Start it?, a Confirm, a stalled job's question say it already).
    static func answers(_ turn: Turn, extras: TurnExtras, known: Bool, told: Set<String>, asked: Date?, now: Date) -> Bool {
        turn.who == .oby && known && !extras.ended && !extras.routine && !told.contains(turn.id)
            && !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && turn.date > now.addingTimeInterval(-600)
            && !(asked.map { $0 > now.addingTimeInterval(-60) } ?? false)
    }

    /// The alert the owner's words settle: Oby's answer in that conversation, read wherever they
    /// wrote (the Mac, the iPhone, the web).
    static func settled(by turn: Turn) -> String? {
        turn.who == .user ? turn.conversation.map(answerID) : nil
    }

    /// The alert of Oby's answer in `conversation`: one per conversation.
    static func answerID(_ conversation: String?) -> String { "turn-\(conversation ?? "talk")" }

    /// "Oby answered", the conversation's title, the reply's first lines; Reply, and a question's options.
    /// One per conversation (`turn-<conversation>`): a newer answer replaces it. `conversation` nil:
    /// the Mac's own desk, which has one thread.
    static func answer(_ text: String, in conversation: String?, title: String, question: (said: String, question: Plan.Question)? = nil) -> Alert {
        let place = conversation.map(AlertPlace.conversation) ?? .window
        var alert = Alert(id: answerID(conversation), title: question == nil ? "Oby answered" : "Oby asks",
                          subtitle: title, body: lines(text), category: options([], reply: "Reply to Oby…", prefix: "answer"),
                          thread: thread(place), info: info(place))
        if let question {
            let asks = question.question.text
            if !text.contains(asks) { alert.body = lines([text, asks].filter { !$0.isEmpty }.joined(separator: "\n")) }
            alert.options = Array(question.question.options.prefix(Plan.Question.mostOptions))
            alert.category = options(alert.options, reply: "Reply to Oby…", prefix: "talk")
            alert.info[saidKey] = question.said
            alert.info[questionKey] = question.question.text
        }
        return alert
    }

    // MARK: Jobs (#613, #863)

    /// A job's alert: the notice's words, and its answers. A permission offers Allow only when the
    /// whole ask shows (`fits`), Always allow only when a rule can be saved and the sentence saying
    /// which shows with it, and neither for a plan (Plan mode's plan is read on its page). Ready keeps
    /// Publish with Touch ID, in the window. Everything else takes a reply, for as long as the job
    /// still needs what the alert said (`noticeKey`).
    static func alert(_ notice: RunnerFeed.Notice, for job: Job, conversation: String?) -> Alert {
        let place = AlertPlace.job(job.id)
        let agent = Job.agentNames[job.agent] ?? job.agent
        let ended = [Job.Status.done, .failed, .stopped].contains(job.status)
        let tell = ended ? "Ask for a follow-up…" : "Tell \(agent)…"
        var alert = Alert(id: job.id, title: RunnerFeed.title(notice, for: job), body: RunnerFeed.body(notice, for: job),
                          category: Alert.Category(id: ended ? "job.ended" : "job.\(job.agent)", buttons: [openButton], reply: tell),
                          thread: thread(conversation.map(AlertPlace.conversation) ?? place), info: info(place))
        alert.info[noticeKey] = RunnerFeed.said(notice, for: job)
        switch notice {
        case .ready:
            alert.category = Alert.Category(id: "ready", buttons: [
                Alert.Button(id: RunnerFeed.publishButton, title: "Publish with Touch ID", opens: true), openButton,
            ])
        case .permission:
            guard let permission = job.permission else { break }
            alert.info[RunnerFeed.permissionKey] = permission.id
            let shown = compact(permission.detail.isEmpty || permission.title.contains(permission.detail)
                                ? permission.title : "\(permission.title)\n\(permission.detail)")
            let allows = permission.tool != "ExitPlanMode" && fits(shown)
            let saves = InboxWords.plain(permission.rule).map { permission.always ?? "Always allow \($0)" }
            let rule = allows ? saves.flatMap { fits(shown + "\n" + $0) ? $0 : nil } : nil
            alert.body = allows ? shown : lines(shown)
            if let rule { alert.body += "\n" + rule }
            var buttons = allows ? [Alert.Button(id: RunnerFeed.allowButton, title: Inbox.allow)] : []
            if rule != nil { buttons.append(Alert.Button(id: alwaysButton, title: Inbox.alwaysAllow)) }
            buttons += [Alert.Button(id: RunnerFeed.denyButton, title: Inbox.deny, destructive: true), openButton]
            alert.category = Alert.Category(id: "permission.\(rule != nil ? "rule" : allows ? "once" : "deny").\(job.agent)", buttons: buttons, reply: tell)
        default: break
        }
        return alert
    }

    // MARK: Answering from the alert (#863)

    /// What the window opens on for an alert's `info`.
    static func place(_ info: [AnyHashable: Any]) -> AlertPlace {
        if let job = info[RunnerFeed.jobKey] as? String { return .job(job) }
        if let job = info[IslandController.localJobKey] as? String { return .localJob(job) }
        if let conversation = info[conversationKey] as? String { return .conversation(conversation) }
        return .window
    }

    /// What a button or a typed reply does, from the alert's own ids: the ask it showed, the item it
    /// was, its options. Anything it can't do from outside the window (Open, a click, a Confirm, a
    /// button it doesn't know, no words, too many words) opens the window, the words kept as a draft.
    static func answer(_ action: String, typed: String?, info: [AnyHashable: Any]) -> AlertAnswer {
        let place = Self.place(info)
        let job = info[RunnerFeed.jobKey] as? String
        let item = info[inboxKey] as? String
        let ask = info[RunnerFeed.permissionKey] as? String
        let options = info[optionsKey] as? [String] ?? []
        let question = (info[saidKey] as? String).flatMap { said in (info[questionKey] as? String).map { (said, $0) } }
        let conversation = info[conversationKey] as? String
        let decisions: [String: (RunnerPermission.Decision, String)] = [
            RunnerFeed.allowButton: (.allow, Inbox.allow), alwaysButton: (.always, Inbox.alwaysAllow), RunnerFeed.denyButton: (.deny, Inbox.deny),
        ]
        if action == RunnerFeed.publishButton, let job { return .publish(job: job) }
        if let (decision, answer) = decisions[action] {
            if let job, let ask { return .permission(job: job, ask: ask, decision, message: nil) }
            // The shell's Always allow is the window's (`alert(for:)`).
            if let item, decision != .always { return .settle(item: item, answer: answer) }
        }
        if action == startButton, let item { return .settle(item: item, answer: Inbox.start) }
        if action.hasPrefix("option."), let index = Int(action.dropFirst(7)), options.indices.contains(index) {
            return words(options[index], item: item, question: question, conversation: conversation, place: place)
        }
        if action == replyButton, let typed = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty {
            guard typed.count <= mostWords else { return .open(place, draft: String(typed.prefix(mostWords))) }
            if let job, let ask { return .permission(job: job, ask: ask, .deny, message: typed) }
            if let job, item == nil { return .tell(job: job, words: typed, said: info[noticeKey] as? String) }
            return words(typed, item: item, question: question, conversation: conversation, place: place)
        }
        return .open(place)
    }

    /// An option picked or words typed: the item's answer, Oby's question answered (planned again,
    /// as the window does), or words to Oby in the conversation.
    private static func words(_ words: String, item: String?, question: (String, String)?, conversation: String?, place: AlertPlace) -> AlertAnswer {
        // Only the owner's tap in the window confirms (#776), whatever the words say.
        if words == RunnerConfirm.confirm { return .open(place) }
        if let item { return .settle(item: item, answer: words) }
        if let (said, question) = question { return .pick(conversation: conversation, said: said, question: question, option: words) }
        if let conversation { return .say(conversation: conversation, words: words) }
        return .open(place)
    }

    // MARK: Shared

    /// One stack per job, or per conversation for its work and Oby's answers there.
    static func thread(_ place: AlertPlace) -> String {
        switch place {
        case .job(let id), .localJob(let id): "job-\(id)"
        case .conversation(let id): "conversation-\(id)"
        case .window: "oby"
        }
    }

    private static func info(_ place: AlertPlace) -> [String: String] {
        switch place {
        case .job(let id): [RunnerFeed.jobKey: id]
        case .localJob(let id): [IslandController.localJobKey: id]
        case .conversation(let id): [conversationKey: id]
        case .window: [:]
        }
    }

    /// Reply, the options as buttons, and Open: a category per set of options, so each alert's
    /// buttons are its own.
    private static func options(_ options: [String], reply: String, prefix: String) -> Alert.Category {
        let buttons = options.enumerated().map { Alert.Button(id: optionButton($0.offset), title: $0.element) } + [openButton]
        return Alert.Category(id: ([prefix] + options).joined(separator: "\u{1F}"), buttons: buttons, reply: reply)
    }
}

/// What an alert's button or reply does (#863), or the window it opens instead.
nonisolated enum AlertAnswer: Equatable, Sendable {
    case open(AlertPlace, draft: String? = nil)
    /// Publish with Touch ID: the window opens on the job and asks.
    case publish(job: String)
    /// Allow, Always allow or Deny on the very ask the alert showed; words go with a deny.
    case permission(job: String, ask: String, RunnerPermission.Decision, message: String?)
    /// Words to a job (`POST /v1/jobs/{id}/messages`): to one that ended, a follow-up task. Only while
    /// the job still needs what its alert `said`: to a job waiting on an ask the alert didn't show, words
    /// would deny it.
    case tell(job: String, words: String, said: String?)
    /// An inbox item's option, or the owner's words (`POST /v1/inbox/{id}/answer`).
    case settle(item: String, answer: String)
    /// Words to Oby in that conversation, as typed in its box.
    case say(conversation: String, words: String)
    /// An option of Oby's question (or words in its place), planned again as the window does.
    case pick(conversation: String?, said: String, question: String, option: String)
}
