import SwiftUI
import WebKit

/// Oby, what's going on, the jobs, and the field where you type a task.
struct HomeView: View {
    @Environment(Phone.self) private var phone
    let character: ObyCharacter
    @State private var text = ""
    @State private var settings = false
    @FocusState private var typing: Bool
    /// Jobs that finished by this time (the runner's clock) are hidden from Home only; the runner keeps them all.
    @AppStorage("home.clearedAt") private var clearedAt: Double = 0
    /// The scroll view's height, so an empty Home can put Oby in the middle of it.
    @State private var height: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if case .offline(let why) = phone.connection {
                        Label(why, systemImage: "wifi.exclamationmark")
                            .font(.footnote).foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                    }
                    ForEach(jobs) { job in
                        NavigationLink(value: job.id) { JobRow(job: job) }
                            .buttonStyle(.plain)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .animation(.spring(duration: 0.8, bounce: 0.35), value: centered)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.black)
            .navigationDestination(for: String.self) { JobScreen(id: $0) }
            .toolbar {
                if jobs.contains(where: { !$0.isActive }) {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear done") {
                            clearedAt = phone.jobs.compactMap(\.finished).max()?.timeIntervalSince1970 ?? clearedAt
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .bottom) { field }
            .sheet(isPresented: sheetShown) { sheet }
            .sheet(isPresented: $settings) { SettingsScreen() }
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

    /// Running jobs, then the ones that finished after the last Clear done.
    private var jobs: [Job] {
        phone.visibleJobs.filter { $0.isActive || ($0.finished?.timeIntervalSince1970 ?? 0) > clearedAt }
    }

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
                    Text("You said “\(said)”").font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                case .reply(let reply):
                    Text(reply).font(.headline)
                    Text("Type a task below.").font(.subheadline).foregroundStyle(.white.opacity(0.6))
                default:
                    let working = phone.active.count
                    Text(working == 0 ? "All quiet." : working == 1 ? "1 agent is working." : "\(working) agents are working.")
                        .font(.title3.weight(.semibold))
                    Text(subline).font(.subheadline).foregroundStyle(.white.opacity(0.6))
                }
            }
            .multilineTextAlignment(centered ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        }
        .frame(maxWidth: .infinity, minHeight: centered ? height * 0.72 : nil)
        .padding(.top, 4)
    }

    private var subline: String {
        switch phone.connection {
        case .live: "Nothing needs you. On \(phone.host)."
        case .connecting: "Reaching the runner…"
        case .offline: "The runner isn't answering."
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("Type a task, like “Review oby PR #12”", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(text.isEmpty ? 0.4 : 1), in: Circle())
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 18)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(Color.black)
    }

    private func send() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        phone.ask(text)
        text = ""
        typing = false
    }

    private var sheetShown: Binding<Bool> {
        Binding {
            switch phone.talk {
            case .plan, .question: true
            default: false
            }
        } set: { shown in
            if !shown { phone.cancel() }
        }
    }

    @ViewBuilder private var sheet: some View {
        switch phone.talk {
        case .plan(let draft):
            PlanCard(draft: draft) { edit in
                text = edit
                phone.cancel()
                typing = true
            }
            .presentationDetents([.medium, .large])
        case .question(let said, let question):
            QuestionSheet(said: said, question: question)
                .presentationDetents([.medium])
        default:
            EmptyView()
        }
    }
}

/// Oby's leap between the middle of Home and its corner.
private struct Hop {
    var y: CGFloat = 0
    var angle: Double = 0
    var scale: CGFloat = 1
}

/// One job: what it is, what it's doing now, how it ended.
struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.agent == "codex" ? "circle.hexagongrid" : "asterisk")
                .font(.body.weight(.semibold))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(job.line).font(.footnote).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(status: job.status)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct StatusPill: View {
    let status: Job.Status

    var body: some View {
        let (text, color): (String, Color) = switch status {
        case .queued: ("Starting", .blue)
        case .running: ("Working", .blue)
        case .done: ("Done", .green)
        case .failed: ("Failed", .red)
        case .stopped: ("Stopped", .gray)
        case .interrupted: ("Interrupted", .gray)
        }
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
    }
}

/// The plan, before anything runs: agent, account, repository and branch.
struct PlanCard: View {
    @Environment(Phone.self) private var phone
    let draft: Draft
    let onEdit: (String) -> Void
    @State private var branch = ""
    @State private var accountID = ""
    @State private var sending = false
    @State private var problem: String?

    private var account: Account? {
        phone.signedIn.first { $0.id == accountID } ?? phone.signedIn.first { $0.id == draft.job.account }
    }

    private var validBranch: Bool {
        branch.wholeMatch(of: /[A-Za-z0-9._\/-]{1,100}/) != nil && !branch.hasPrefix("-") && !branch.contains("..")
            && !branch.hasSuffix("/") && !branch.hasSuffix(".lock")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("You said “\(draft.said)”").font(.footnote).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                Text(draft.reply).font(.title3.weight(.semibold))
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    tile("Agent") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account?.agent == "codex" ? "Codex" : "Claude Code")
                            if let models = phone.models {
                                Text((account?.agent == "codex" ? models.codex : models.claude).label)
                                    .font(.caption).foregroundStyle(.white.opacity(0.55))
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
                            .foregroundStyle(validBranch ? .white : .red)
                    }
                }
            }
            Label("Works in Oby's own copy of the repository. Nothing is pushed or posted.", systemImage: "checkmark.shield")
                .font(.footnote).foregroundStyle(.white.opacity(0.6))
            if draft.guessed {
                Label("Oby's brain didn't answer, so this plan is a guess. Check it before you dispatch.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button(action: dispatch) {
                    Text(sending ? "Dispatching…" : "Dispatch").font(.headline).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(.white.opacity(validBranch && account != nil ? 1 : 0.4), in: Capsule())
                }
                .disabled(!validBranch || account == nil || sending)
                pill("Edit") { onEdit(draft.said) }
                pill("Cancel") { phone.cancel() }
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .onAppear {
            branch = draft.job.branch
            accountID = draft.job.account
        }
    }

    private func dispatch() {
        var draft = draft
        draft.job.branch = branch
        if let account {
            draft.job.account = account.id
            draft.job.agent = account.agent
        }
        sending = true
        Task {
            defer { sending = false }
            do { try await phone.dispatch(draft) } catch { problem = error.localizedDescription }
        }
    }

    private func tile(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.55))
            value().font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline)
                .padding(.horizontal, 18).frame(height: 48)
                .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The brain needs one more thing: pick an option, or close and type it.
struct QuestionSheet: View {
    @Environment(Phone.self) private var phone
    let said: String
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.text).font(.title3.weight(.semibold)).padding(.bottom, 6)
            ForEach(question.options, id: \.self) { option in
                Button { phone.answer(option, said: said, question: question) } label: {
                    Text(option).font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black)
    }
}
