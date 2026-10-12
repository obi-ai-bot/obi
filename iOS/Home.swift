import SwiftUI
import WebKit

/// Home, the glance (#11): Oby, what's going on, the Inbox, the jobs, and the field where you
/// type a task. The thread itself is the Chat tab (iOS/Chat.swift).
struct HomeView: View {
    @Environment(Phone.self) private var phone
    @Environment(\.scenePhase) private var scenePhase
    let character: ObyCharacter
    @State private var text = ""
    @FocusState private var typing: Bool
    /// The scroll view's height, so an empty Home can put Oby in the middle of it.
    @State private var height: CGFloat = 0
    /// The job screens open, so a notification can open its job.
    @State private var path: [String] = []
    /// Why the last Dismiss or Clear done didn't go through, until the next one does.
    @State private var problem: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if case .offline(let why) = phone.connection {
                        Label(why, systemImage: "wifi.exclamationmark")
                            .font(.footnote).foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                    }
                    // What only you can answer, before the jobs.
                    InboxSection()
                    ForEach(groups) { section in
                        Text(section.group.rawValue)
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.top, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.jobs) { job in
                            NavigationLink(value: job.id) { JobRow(job: job) }
                                .buttonStyle(.plain)
                                // Swipe left on a job that needs you to let it go.
                                .modifier(SwipeToDismiss(enabled: job.needsYou) { Task { await dismiss(job.id) } })
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(.red).padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .animation(.spring(duration: 0.8, bounce: 0.35), value: centered)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .refreshable { await phone.reload() }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationDestination(for: String.self) { JobScreen(id: $0) }
            .toolbar {
                // Only when it would take something: jobs that need you stay until you Dismiss them.
                if jobs.contains(where: \.clearable) {
                    ToolbarItem(placement: .topBarLeading) {
                        // Through the runner, so the Mac's island clears too.
                        Button("Clear done") { Task { await clear() } }
                    }
                }
                if jobs.contains(where: \.isActive) {
                    ToolbarItem(placement: .topBarTrailing) {
                        // Every job on the runner, as ⌃⌥⌘. does on the Mac.
                        Button("Stop all", systemImage: "stop.circle", role: .destructive) { Task { await stopAll() } }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { Composer(text: $text, typing: $typing, onSend: send) }
            // The plan and the question are sheets here; Chat shows them in the thread.
            .sheet(isPresented: sheetShown) { sheet }
            .onDisappear { phone.cancelVoice() }
            .onChange(of: scenePhase) { if scenePhase != .active { phone.leftForeground(background: scenePhase == .background) } }
            .onChange(of: path) { if !path.isEmpty { phone.cancelVoice() } }
            .onChange(of: phone.opening, initial: true) {
                guard let id = phone.opening else { return }
                phone.opening = nil
                phone.cancel()
                path = [id]
            }
            .onChange(of: mood, initial: true) { character.mood = mood }
            .onChange(of: centered) {
                // Off to work with a grin; back in the middle with a hello.
                character.mood = mood
                character.play(centered ? "Hello" : "Grin")
            }
        }
    }

    /// Nothing to show: Oby waits big in the middle of Home, and the first job sends it to its corner.
    private var centered: Bool { phone.loaded && jobs.isEmpty }

    /// Every job but those that finished by the last Clear done, on any app, and need you no more.
    private var jobs: [Job] { phone.jobs.filter { $0.listed(after: phone.clearedAt) } }

    /// The jobs in the groups both apps show: needs you, working, in review, done.
    private var groups: [JobList.Section<Job>] { JobList.groups(jobs, by: \.group) }

    private var mood: String {
        if case .thinking = phone.talk { return "thinking" }
        return phone.active.isEmpty ? "idle" : "working"
    }

    private var header: some View {
        // One layout that changes shape, so Oby stays the same web view as it moves.
        let layout = centered ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        let size: CGFloat = centered ? 220 : 104
        return layout {
            // Drawn at the big size and scaled, so the page never resizes mid-move.
            WebView(character.page)
                .webViewContentBackground(.hidden)
                .frame(width: 220, height: 220)
                .scaleEffect(size / 220)
                .frame(width: size, height: size)
                .keyframeAnimator(initialValue: Hop(), trigger: centered) { oby, hop in
                    oby.offset(y: hop.y).rotationEffect(.degrees(hop.angle)).scaleEffect(hop.scale)
                } keyframes: { _ in
                    // Crouch, leap, land.
                    KeyframeTrack(\.y) {
                        CubicKeyframe(10, duration: 0.12)
                        SpringKeyframe(-36, duration: 0.28, spring: .snappy)
                        SpringKeyframe(0, duration: 0.5, spring: .bouncy)
                    }
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(0.9, duration: 0.12)
                        SpringKeyframe(1.12, duration: 0.28, spring: .snappy)
                        SpringKeyframe(1, duration: 0.5, spring: .bouncy)
                    }
                    KeyframeTrack(\.angle) {
                        CubicKeyframe(0, duration: 0.12)
                        SpringKeyframe(-12, duration: 0.25, spring: .snappy)
                        SpringKeyframe(8, duration: 0.2, spring: .snappy)
                        SpringKeyframe(0, duration: 0.4, spring: .bouncy)
                    }
                }
                .accessibilityLabel("Oby")
            VStack(alignment: centered ? .center : .leading, spacing: 4) {
                switch phone.talk {
                case .thinking(let said):
                    Text("Thinking…").font(.title3.weight(.semibold))
                    Text("You said “\(said)”").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    Button("Cancel waiting") { phone.cancel() }
                    Text("Requests already sent may still start jobs.")
                        .font(.caption).foregroundStyle(.secondary)
                case .reply(let reply):
                    ReadingText(reply, weight: .medium, alignment: centered ? .center : .leading)
                    Text("Type a task below.").font(.subheadline).foregroundStyle(.secondary)
                default:
                    // The same line as the Mac's notch and island (Shared/JobList.swift).
                    Text(Summary.line(working: phone.active.count, needs: needs))
                        .font(.title3.weight(.semibold))
                    Text(subline).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(centered ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        }
        .frame(maxWidth: .infinity, minHeight: centered ? height * 0.72 : nil)
        .padding(.top, 4)
    }

    /// What needs you among the jobs Home shows: ready to publish, failed, interrupted or out of reviews.
    private var needs: String? { NeedsYou.line(jobs) }

    private var subline: String {
        switch phone.connection {
        case .live: "On \(phone.host)."
        case .connecting: "Reaching the runner…"
        case .offline: "The runner isn't answering."
        }
    }

    /// `spoken`: the draft has dictated words, so Oby may speak its reply.
    private func send(spoken: Bool) {
        phone.ask(text, spoken: spoken)
        text = ""
        typing = false
    }

    /// Lets go of a job that needs you: the runner keeps it, and it stops counting here and on the Mac.
    private func dismiss(_ id: String) async {
        do {
            try await phone.dismiss(id)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Stop all: every queued and running job on the runner stops now.
    private func stopAll() async {
        do {
            try await phone.stopAll()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Clear done: the runner records the time, and the finished jobs go from here and from the Mac's island.
    private func clear() async {
        do {
            try await phone.clear()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Only while Home is the tab in front: on Chat, the card is in the thread.
    private var sheetShown: Binding<Bool> {
        Binding {
            guard phone.tab == .home else { return false }
            switch phone.talk {
            case .plan, .question: return true
            default: return false
            }
        } set: { shown in
            if !shown { phone.cancel() }
        }
    }

    @ViewBuilder private var sheet: some View {
        switch phone.talk {
        case .plan(let drafts) where drafts.count == 1:
            ScrollView { PlanCard(draft: drafts[0], onEdit: edit) }
                .background(Color(uiColor: .systemGroupedBackground))
                .presentationDetents([.large])
        case .plan(let drafts):
            ScrollView { PlansCard(drafts: drafts, onEdit: edit) }
                .background(Color(uiColor: .systemGroupedBackground))
                .presentationDetents([.large])
        case .question(let said, let question):
            QuestionSheet(said: said, question: question)
                .presentationDetents([.medium])
        default:
            EmptyView()
        }
    }

    /// Edit on a plan card: its words go back in the field.
    private func edit(_ said: String) {
        text = said
        phone.cancel()
        typing = true
    }
}

/// The dispatch card's mode: one of the four, or the runner's default (Settings › Permissions).
struct ModeMenu: View {
    @Binding var mode: RunnerMode?
    let fallback: RunnerMode?

    var body: some View {
        Menu {
            Picker("Mode", selection: $mode) {
                Text("Default (\(fallback?.label ?? "the runner's"))").tag(RunnerMode?.none)
                ForEach(RunnerMode.allCases) { mode in
                    Label {
                        Text(mode.label)
                        Text(mode.help)
                    } icon: {
                        Image(systemName: mode.symbol)
                    }
                    .tag(RunnerMode?.some(mode))
                }
            }
        } label: {
            Label((mode ?? fallback)?.label ?? "Default", systemImage: (mode ?? fallback)?.symbol ?? "hand.raised").lineLimit(1)
        }
    }
}

/// Oby's leap between the middle of Home and its corner.
private struct Hop {
    var y: CGFloat = 0
    var angle: Double = 0
    var scale: CGFloat = 1
}

/// Swipe a row left to uncover Dismiss, as a List's swipe actions do; Home's rows are in a
/// ScrollView, which keeps vertical drags for scrolling. Dismiss closes the row and lets the job go.
private struct SwipeToDismiss: ViewModifier {
    let enabled: Bool
    let dismiss: () -> Void
    @State private var offset: CGFloat = 0
    @State private var open = false
    private static let width: CGFloat = 96

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                if enabled, offset < 0 {
                    Button {
                        close()
                        dismiss()
                    } label: {
                        Text("Dismiss").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: Self.width).frame(maxHeight: .infinity)
                            .background(.red, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
            }
            .gesture(drag, including: enabled ? .all : .subviews)
            .onChange(of: enabled) { if !enabled { close() } }
            .accessibilityAction(named: "Dismiss") { if enabled { dismiss() } }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                // Only a sideways swipe; the scroll view keeps the vertical ones.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let start: CGFloat = open ? -Self.width : 0
                offset = min(0, max(-Self.width - 24, start + value.translation.width))
            }
            .onEnded { value in
                let end = (open ? -Self.width : 0) + value.translation.width
                withAnimation(.snappy) {
                    open = end < -Self.width / 2
                    offset = open ? -Self.width : 0
                }
            }
    }

    private func close() {
        withAnimation(.snappy) {
            open = false
            offset = 0
        }
    }
}

/// One job: what it is, what it's doing now, how it ended.
struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentMark(agent: job.agent)
                .font(.body.weight(.semibold))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.heading).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let pipeline = job.pipeline {
                    Text(pipeline.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(job.line).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    StatusPill(badge: job.badge)
                    if let verdict = job.verdictLine {
                        Text(verdict).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// The plan, before anything runs: agent, account, repository, branch, how it loops, and the
/// stronger model when the work looks complex.
struct PlanCard: View {
    @Environment(Phone.self) private var phone
    let draft: Draft
    let onEdit: (String) -> Void
    @State private var branch = ""
    @State private var accountID = ""
    @State private var rounds = 1
    @State private var check = ""
    @State private var stronger = false
    /// The mode picked for this job, or nil for the runner's default.
    @State private var mode: RunnerMode?
    @State private var sending = false
    @State private var problem: String?

    private var account: Account? {
        phone.signedIn.first { $0.id == accountID } ?? phone.signedIn.first { $0.id == draft.job.account }
    }

    private var validBranch: Bool {
        branch.wholeMatch(of: /[A-Za-z0-9._\/-]{1,100}/) != nil && !branch.hasPrefix("-") && !branch.contains("..")
            && !branch.hasSuffix("/") && !branch.hasSuffix(".lock")
    }

    /// One line of up to 200 characters, or empty for none.
    private var validCheck: Bool {
        let command = check.trimmingCharacters(in: .whitespaces)
        return command.count <= 200 && !command.contains(where: \.isNewline)
    }

    private var ready: Bool { validBranch && validCheck && account != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("You said “\(draft.said)”").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                Text(draft.reply).font(.title3.weight(.semibold))
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    tile("Agent") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account?.agent == "codex" ? "Codex" : "Claude Code")
                            if let models = phone.models {
                                Text((account?.agent == "codex" ? models.codex : models.claude).label)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    tile(phone.signedIn.count > 1 ? "Account · tap to change" : "Account") {
                        Menu {
                            ForEach(phone.signedIn) { account in
                                Button(account.title) { accountID = account.id }
                            }
                        } label: {
                            Text(account?.title ?? "No account").lineLimit(1)
                        }
                        .disabled(phone.signedIn.count < 2)
                    }
                }
                GridRow {
                    tile("Repository") { Text(draft.job.repo).lineLimit(1).minimumScaleFactor(0.8) }
                    tile("Branch") {
                        TextField("Branch", text: $branch)
                            .font(.subheadline.monospaced().weight(.semibold))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(validBranch ? Color.primary : Color.red)
                    }
                }
                GridRow {
                    tile("Done when · a command that must pass") {
                        TextField("Optional, like swift test", text: $check)
                            .font(.subheadline.monospaced().weight(.semibold))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(validCheck ? Color.primary : Color.red)
                    }
                    .gridCellColumns(2)
                }
                GridRow {
                    tile("Rounds") {
                        Stepper(rounds == 1 ? "1, no loop" : "Up to \(rounds)", value: $rounds, in: 1...10)
                    }
                    .gridCellColumns(2)
                }
                if phone.defaultMode != nil {
                    GridRow {
                        tile("Mode · tap to change") { ModeMenu(mode: $mode, fallback: phone.defaultMode) }
                            .gridCellColumns(2)
                    }
                }
            }
            if let model = draft.strongerModel(for: account?.agent ?? draft.job.agent) {
                tile("This looks complex") { StrongerModel(model: model, plan: account?.label, on: $stronger) }
            }
            Label("Works in Oby's own copy of the repository. Nothing is pushed or posted.", systemImage: "checkmark.shield")
                .font(.footnote).foregroundStyle(.secondary)
            if draft.guessed {
                Label("Oby's brain didn't answer, so this plan is a guess. Check it before you dispatch.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button(action: dispatch) {
                    Text(sending ? "Dispatching…" : "Dispatch").font(.headline).foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(Color.primary.opacity(ready ? 1 : 0.4), in: Capsule())
                }
                .disabled(!ready || sending)
                pill("Edit") { onEdit(draft.said) }
                pill("Cancel") { phone.cancel() }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear {
            branch = draft.job.branch
            accountID = draft.job.account
            rounds = draft.job.rounds ?? 1
            check = draft.job.check ?? ""
            mode = RunnerMode(draft.job.mode)
        }
    }

    private func dispatch() {
        var draft = draft
        // Before the account changes the job's agent: the offer is for the routed tool.
        let model = stronger ? draft.strongerModel(for: account?.agent ?? draft.job.agent) : nil
        draft.job.branch = branch
        if let account {
            draft.job.account = account.id
            draft.job.agent = account.agent
        }
        draft.job.rounds = rounds
        let command = check.trimmingCharacters(in: .whitespaces)
        draft.job.check = command.isEmpty ? nil : command
        draft.job.model = model
        draft.job.mode = mode?.rawValue
        sending = true
        Task {
            defer { sending = false }
            do { try await phone.dispatch(draft) } catch { problem = error.localizedDescription }
        }
    }
}

/// Several jobs from one message: one row each, with its own account and stronger model, and
/// Dispatch all. Each job keeps the plan's rounds and check.
struct PlansCard: View {
    @Environment(Phone.self) private var phone
    let drafts: [Draft]
    let onEdit: (String) -> Void
    /// The account each draft goes to, by job id: the routed one unless the user picks another.
    @State private var picked: [String: String] = [:]
    /// The drafts whose stronger model is on, by job id.
    @State private var stronger: Set<String> = []
    /// The mode every job gets, or nil for the runner's default.
    @State private var mode: RunnerMode?
    @State private var sending = false
    @State private var problem: String?

    private var ready: Bool { drafts.allSatisfy { account(of: $0) != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("You said “\(drafts[0].said)”").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                Text("Oby will start \(drafts.count) jobs.").font(.title3.weight(.semibold))
            }
            ForEach(drafts, id: \.job.id) { row($0) }
            if phone.defaultMode != nil {
                tile("Mode for all · tap to change") { ModeMenu(mode: $mode, fallback: phone.defaultMode) }
            }
            Label("Each works in Oby's own copy of its repository. Nothing is pushed or posted.", systemImage: "checkmark.shield")
                .font(.footnote).foregroundStyle(.secondary)
            if drafts.contains(where: \.guessed) {
                Label("Oby's brain didn't answer, so this plan is a guess. Check it before you dispatch.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button(action: dispatchAll) {
                    Text(sending ? "Dispatching…" : "Dispatch all \(drafts.count)").font(.headline).foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(Color.primary.opacity(ready ? 1 : 0.4), in: Capsule())
                }
                .disabled(!ready || sending)
                pill("Edit") { onEdit(drafts[0].said) }
                pill("Cancel") { phone.cancel() }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func row(_ draft: Draft) -> some View {
        let account = account(of: draft)
        // Sent already: Dispatch all failed on a later one and will send only the rest.
        let sent = phone.jobs.contains { $0.id == draft.job.id }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.job.heading).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(details(draft)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if sent {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Sent")
                }
            }
            Menu {
                ForEach(phone.signedIn) { account in
                    Button(account.title) { picked[draft.job.id] = account.id }
                }
            } label: {
                Label(account?.title ?? "No account", systemImage: "person.crop.circle")
                    .font(.footnote.weight(.semibold)).lineLimit(1)
            }
            .disabled(phone.signedIn.count < 2 || sent)
            if let model = draft.strongerModel(for: account?.agent ?? draft.job.agent) {
                StrongerModel(model: model, plan: account?.label, on: Binding {
                    stronger.contains(draft.job.id)
                } set: { on in
                    if on { stronger.insert(draft.job.id) } else { stronger.remove(draft.job.id) }
                })
                .disabled(sent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func account(of draft: Draft) -> Account? {
        phone.signedIn.first { $0.id == picked[draft.job.id] } ?? phone.signedIn.first { $0.id == draft.job.account }
    }

    /// "deskree-inc/oby · oby/fix-42 · until swift test passes"
    private func details(_ draft: Draft) -> String {
        var parts = [draft.job.repo, draft.job.branch]
        if let check = draft.job.check {
            parts.append("until \(check) passes")
        } else if let rounds = draft.job.rounds, rounds > 1 {
            parts.append("up to \(rounds) rounds")
        }
        return parts.joined(separator: " · ")
    }

    private func dispatchAll() {
        let edited = drafts.map { draft in
            var edited = draft
            let account = account(of: draft)
            edited.job.model = stronger.contains(draft.job.id) ? draft.strongerModel(for: account?.agent ?? draft.job.agent) : nil
            edited.job.mode = mode?.rawValue
            if let account {
                edited.job.account = account.id
                edited.job.agent = account.agent
            }
            return edited
        }
        sending = true
        Task {
            defer { sending = false }
            do {
                try await phone.dispatch(all: edited)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The offer for complex work: the stronger model, off until the user turns it on. Astra on a
/// ChatGPT Plus plan gets a warning, because it uses that plan's limits fast.
struct StrongerModel: View {
    let model: String
    /// The account's label, like "Plus · name@example.com".
    let plan: String?
    @Binding var on: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Use \(ModelChoice.name(model))", isOn: $on)
                .font(.subheadline.weight(.semibold))
            if model == "gpt-6-astra", plan?.hasPrefix("Plus") == true {
                Label("Astra uses a Plus plan's limits fast.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }
}

/// A plan card's box: a small label over its value.
private func tile(_ label: String, @ViewBuilder value: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label).font(.caption).foregroundStyle(.secondary)
        value().font(.subheadline.weight(.semibold))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12).padding(.vertical, 10)
    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
}

private func pill(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title).font(.headline)
            .padding(.horizontal, 18).frame(height: 48)
            .background(Color.primary.opacity(0.1), in: Capsule())
    }
    .buttonStyle(.plain)
}

/// The brain needs one more thing: pick an option, the recommended one first, or say your own.
struct QuestionSheet: View {
    @Environment(Phone.self) private var phone
    let said: String
    let question: Question

    var body: some View {
        ScrollView {
            DecisionCard(title: question.text, plan: question.plan, options: question.cardOptions,
                         onChoose: { phone.answer($0.answer, said: said, question: question) },
                         onWords: { phone.answer($0, said: said, question: question) })
                .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
