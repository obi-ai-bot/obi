import SwiftUI
import WebKit

/// Where a tab's stack can go: a kind of work's page, a task's page, a conversation (obid's by
/// id, nil for the latest or the one thread), the one Home's box just started, every task,
/// Archived, and what needs you.
enum Route: Hashable {
    case kind(WorkType)
    case task(String)
    case conversation(String?)
    case newConversation
    case all
    case archived
    case needs
}

extension EnvironmentValues {
    /// Opens a route over the stack the view is in.
    @Entry var push: (Route) -> Void = { _ in }
}

extension View {
    /// The way to open them, set on the stack itself so every page in it gets it.
    func pushes(onto path: Binding<[Route]>) -> some View {
        environment(\.push) { path.wrappedValue.append($0) }
    }

    /// Every page a tab's stack can open.
    func routes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .kind(let kind): KindPage(kind: kind)
            case .task(let id): TaskPage(id: id)
            case .conversation(let id): ConversationPage(id: id)
            case .newConversation: ConversationPage(id: nil, isNew: true)
            case .all: AllTasksPage()
            case .archived: ArchivedPage()
            case .needs: NeedsYouPage()
            }
        }
    }

    /// Sangam's dark page: the background behind everything, its ink for the bars' controls.
    func obyPage() -> some View {
        background(Tokens.bg)
            .toolbarBackground(Tokens.bg, for: .navigationBar)
            .scrollContentBackground(.hidden)
    }
}

/// Home (Sangam's Home.tsx): Oby on its stage, what's running and what needs you under it, a chip
/// for each kind of work, and the message box. What you send there starts a conversation and
/// opens it. A chip opens its kind's page; the list button, every task; Needs you, what only you
/// can answer.
struct HomeView: View {
    @Environment(Phone.self) private var phone
    @Environment(\.scenePhase) private var scenePhase
    let character: ObyCharacter
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        @Bindable var phone = phone
        NavigationStack(path: $phone.homePath) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { typing = false }
                .obyPage()
                .safeAreaInset(edge: .bottom) {
                    Composer(text: $text, prompt: HomeLine.placeholder(fullName: HomeLine.owner(ofMac: phone.link?.name) ?? ""),
                             typing: $typing, onSend: send)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: Route.all) { Image(systemName: "checklist") }
                            .accessibilityLabel("All tasks")
                    }
                    if !phone.active.isEmpty {
                        ToolbarItem(placement: .topBarLeading) {
                            // Every job on the runner, as ⌃⌥⌘. does on the Mac.
                            Button("Stop all", systemImage: "stop.circle") { Task { try? await phone.stopAll() } }
                                .tint(Tokens.danger)
                        }
                    }
                }
                .routes()
        }
        .pushes(onto: $phone.homePath)
        .onDisappear { phone.cancelVoice() }
        .onChange(of: scenePhase) { if scenePhase != .active { phone.leftForeground(background: scenePhase == .background) } }
        .onChange(of: phone.homePath) { if !phone.homePath.isEmpty { phone.cancelVoice(); typing = false } }
        .onChange(of: mood, initial: true) { character.mood = mood }
    }

    private var mood: String {
        if case .thinking = phone.talk { return "thinking" }
        return phone.active.contains(where: \.isWorking) ? "working" : "idle"
    }

    /// Oby a little above the middle, the line under it, and the chips.
    private var stage: some View {
        let work = phone.work
        let groups = WorkList.groups(work, by: .type)
        let running = work.count { $0.status == .running }, needs = work.count { $0.status == .needs }
        let waiting = InboxItem.waiting(phone.inbox).count
        return VStack(spacing: 16) {
            Spacer(minLength: 0)
            WebView(character.page)
                .webViewContentBackground(.hidden)
                .opacity(character.ready ? 1 : 0)
                .allowsHitTesting(false)
                .frame(width: 240, height: 200)
                .accessibilityElement()
                .accessibilityLabel("Oby")
            Text(HomeLine.attention(running: running, needs: needs))
                .font(Tokens.font(Tokens.textBase))
                .foregroundStyle(running + needs == 0 ? Tokens.text : Tokens.muted)
                .multilineTextAlignment(.center)
            if case .offline = phone.connection {
                Label(phone.offlineLine, systemImage: "wifi.exclamationmark")
                    .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.needs)
                    .multilineTextAlignment(.center)
            }
            CenteredFlow(spacing: 8) {
                // What only you can answer, first, so nothing waits unseen.
                if waiting > 0 {
                    HomeChip(label: "Needs you · \(waiting)", fresh: false, needs: true) { phone.homePath.append(.needs) }
                }
                ForEach(groups) { group in
                    HomeChip(label: group.label, fresh: group.fresh, needs: group.needs > 0) {
                        if let kind = group.type { phone.homePath.append(.kind(kind)) }
                    }
                }
            }
            .padding(.horizontal, Tokens.gutter)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Your tasks")
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
    }

    /// `spoken`: the draft has dictated words, so Oby may speak its reply.
    private func send(spoken: Bool) {
        phone.ask(text, spoken: spoken, new: true)
        text = ""
        typing = false
        phone.homePath.append(.newConversation)
    }
}

/// A kind of work's chip on Home: a blue dot ahead of its name while it holds a new task, an
/// orange one when something in it needs you; both can show.
struct HomeChip: View {
    let label: String
    let fresh: Bool
    let needs: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if fresh || needs {
                    HStack(spacing: 4) {
                        if fresh { Circle().fill(Tokens.unread).frame(width: 6, height: 6).accessibilityLabel("New") }
                        if needs { Circle().fill(Tokens.needs).frame(width: 6, height: 6).accessibilityLabel("Needs you") }
                    }
                }
                Text(label).font(Tokens.font(Tokens.textBase)).lineLimit(1)
            }
            .foregroundStyle(Tokens.text)
            .padding(.horizontal, 16).frame(height: 36)
            .background(Tokens.pill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// One kind of work's page (Sangam's GroupView.tsx): its name, Running and Completed tabs with
/// their counts, a card per task under the open tab, and under Completed the way to Archived.
struct KindPage: View {
    @Environment(Phone.self) private var phone
    @Environment(\.push) private var push
    let kind: WorkType
    /// The tab picked, or nil for the one it opens on.
    @State private var picked: WorkList.Tab?

    var body: some View {
        let items = WorkList.ranked(phone.work.filter { $0.type == kind })
        let tab = picked ?? WorkList.firstTab(items)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.label).font(Tokens.font(28, .semibold)).foregroundStyle(Tokens.ink)
                    .padding(.bottom, 12).accessibilityAddTraits(.isHeader)
                LineTabs(tab: tab, counts: Dictionary(uniqueKeysWithValues: WorkList.Tab.allCases.map { ($0, WorkList.items(items, in: $0).count) })) {
                    picked = $0
                }
                .padding(.bottom, 12)
                let cards = WorkList.items(items, in: tab)
                ForEach(cards) { TaskCard(item: $0) }
                if cards.isEmpty {
                    Text(tab == .done ? "Nothing completed yet" : "Nothing running")
                        .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.vertical, 8).padding(.horizontal, 4)
                }
                if tab == .done {
                    Button("Older ones are in Archived") { push(.archived) }
                        .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                        .padding(.top, 8).padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, Tokens.gutter).padding(.top, 8).padding(.bottom, 32)
        }
        .obyPage()
        .navigationBarTitleDisplayMode(.inline)
        // The tab it opens on stays put while you're on it, so a task arriving doesn't switch it.
        .onAppear { picked = picked ?? WorkList.firstTab(items) }
        .refreshable { await phone.reload() }
    }
}

/// Every task Home lists (Sangam's side panel): by kind of work or by status, each group's done
/// ones capped behind Show more; Clear done, and the way to Archived.
struct AllTasksPage: View {
    @Environment(Phone.self) private var phone
    @Environment(\.push) private var push
    @AppStorage(GroupBy.key) private var groupBy = GroupBy.type
    @State private var more: Set<String> = []
    @State private var problem: String?

    var body: some View {
        let groups = WorkList.groups(phone.work, by: groupBy)
        List {
            if groups.isEmpty {
                Text(phone.loaded ? "Nothing yet. Ask Oby for something on Home." : "Reaching the runner…")
                    .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted)
                    .listRowBackground(Color.clear)
            }
            ForEach(groups) { group in
                let shown = WorkList.shown(group, more: more.contains(group.id))
                Section {
                    ForEach(shown.rows) { item in
                        Button { push(.task(item.id)) } label: { TaskRow(item: item) }
                            .listRowBackground(Tokens.surface)
                    }
                    if shown.hidden > 0 {
                        Button(more.contains(group.id) ? "Show less" : "Show \(shown.hidden) more") {
                            if more.contains(group.id) { more.remove(group.id) } else { more.insert(group.id) }
                        }
                        .font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted)
                        .listRowBackground(Tokens.surface)
                    }
                } header: {
                    Text("\(group.label) · \(group.count) \(group.countLabel)").font(Tokens.font(Tokens.textMd, .medium)).foregroundStyle(Tokens.item)
                        .textCase(nil)
                }
            }
            Section {
                Button("Archived") { push(.archived) }.foregroundStyle(Tokens.ink).listRowBackground(Tokens.surface)
            } footer: {
                if let problem { Text(problem).foregroundStyle(Tokens.danger) }
            }
        }
        .obyPage()
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await phone.reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Group by", selection: $groupBy) {
                        ForEach(GroupBy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    // Through the runner (it keeps the time), so the Mac's window clears too.
                    Button("Clear done") {
                        Task { do { try await phone.clear(); problem = nil } catch { problem = error.localizedDescription } }
                    }
                    .disabled(!phone.visibleJobs.contains { $0.clearable(among: phone.jobs) })
                } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Group by")
            }
        }
    }
}

/// A task in a list: its mark, its agent's mark, its title, and how long ago.
private struct TaskRow: View {
    let item: WorkList.Item<Job>

    var body: some View {
        HStack(spacing: 10) {
            AgentMark(agent: item.job.agent).font(Tokens.font(12, .semibold)).frame(width: 16).foregroundStyle(Tokens.muted)
            Text(item.job.heading).font(Tokens.font(Tokens.textBase))
                .foregroundStyle(item.status == .done ? Tokens.doneTitle : Tokens.openTitle).lineLimit(1)
            Spacer(minLength: 8)
            Text(TaskFacts.ago(item.job)).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
            WorkMarkView(mark: item.mark)
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.mark.rawValue)
    }
}

/// Archived (Sangam's ArchiveView.tsx), kept by this iPhone: the done tasks that left Home, most
/// recently done first, with a search over them.
struct ArchivedPage: View {
    @Environment(Phone.self) private var phone
    @Environment(\.push) private var push
    @State private var query = ""

    var body: some View {
        let all = phone.archived.sorted { ($0.finished ?? $0.created) > ($1.finished ?? $1.created) }
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = all.filter { q.isEmpty || "\($0.heading) \($0.agentName) \($0.repoName)".localizedCaseInsensitiveContains(q) }
        List {
            ForEach(shown) { job in
                Button { push(.task(job.id)) } label: {
                    HStack(spacing: 10) {
                        AgentMark(agent: job.agent).font(Tokens.font(12, .semibold)).frame(width: 16).foregroundStyle(Tokens.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.heading).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.item).lineLimit(1)
                            Text(TaskMeta.line(job, account: phone.accountName(job.account))).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(ConversationOrder.ago(job.finished ?? job.created)).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                    }
                    .frame(minHeight: 44)
                }
                .listRowBackground(Tokens.surface)
            }
            if shown.isEmpty {
                Text(all.isEmpty ? "Nothing archived yet" : "Nothing archived matches “\(q)”")
                    .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).listRowBackground(Color.clear)
            }
        }
        .searchable(text: $query, prompt: "Search archived tasks")
        .obyPage()
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Needs you: everything only you can answer, the longest-waiting first, each as its decision.
struct NeedsYouPage: View {
    @Environment(Phone.self) private var phone

    var body: some View {
        // Every half minute: what was put off comes back.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let items = InboxItem.waiting(phone.inbox, now: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Needs you").font(Tokens.font(28, .semibold)).foregroundStyle(Tokens.ink).padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.line(now: context.date)).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).lineLimit(1)
                            InboxDecision(item: item, openTask: true)
                        }
                    }
                    if items.isEmpty {
                        Text("Nothing needs you").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted)
                    }
                }
                .padding(.horizontal, Tokens.gutter).padding(.top, 8).padding(.bottom, 32)
            }
        }
        .obyPage()
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await phone.reload() }
    }
}
