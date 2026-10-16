import AppKit
import SwiftUI

/// The sidebar's sections, as the window lists them: what each row says, with no view in the
/// way, so the tests read them (apps/mac/tests/SidebarTests.swift).
nonisolated enum SidebarSections {
    /// A job, this Mac's own or the runner's.
    struct JobRow: Identifiable, Equatable, Sendable {
        var job: Job
        var local: Bool
        var id: String { Self.id(job.id, local: local) }
        static func id(_ job: String, local: Bool) -> String { (local ? "mac/" : "runner/") + job }
    }

    /// What the conversation's icon says under the pointer: the last message, or a hello.
    static func obyPreview(_ last: String?) -> String {
        last ?? "Say hello to Oby"
    }

    /// What VoiceOver reads for the conversation's icon: what it says, and an unread reply.
    static func obyLabel(last: String?, unread: Bool) -> String {
        "Oby, \(obyPreview(last))" + (unread ? ", unread reply" : "")
    }

    /// Every job on Home as a task (#496), this Mac's and the runner's, latest first (by when it
    /// finished, else when it was created, so "the latest done" are the last to finish): its kind of
    /// work, where it stands, and whether it's new (created after `since`, when the window's state
    /// began, and not in `seen`, the rows opened since). The caller leaves out what Clear done took.
    ///
    /// No job lands in a teammate's group yet: the runner this Mac talks to doesn't say who asked
    /// for a job (only obid's jobs carry `obi.fromOwner`, docs/runner-api.md), so there's no
    /// requester to group by rather than one made up.
    static func work(local: [Job], runner: [Job], since: Date, seen: Set<String>) -> [WorkList.Item<JobRow>] {
        let rows = local.map { JobRow(job: $0, local: true) } + runner.map { JobRow(job: $0, local: false) }
        return rows
            .sorted {
                let left = $0.job.finished ?? $0.job.created, right = $1.job.finished ?? $1.job.created
                return left == right ? $0.id < $1.id : left > right
            }
            .map { row in
                let job = row.job
                let status: WorkStatus = job.needsYou || job.waitsForAnswer || job.waitsForPermission ? .needs : job.isActive ? .running : .done
                return WorkList.Item(id: row.id, job: row, type: .of(review: job.kind == .review, issue: job.issue, requester: nil),
                                     status: status, queued: job.status == .queued, fresh: job.created > since && !seen.contains(row.id))
            }
    }

    /// "WP" for Wellington Prado: the first letters of the first two names.
    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return parts.isEmpty ? "?" : String(parts).uppercased()
    }
}

extension IslandModel {
    /// Home's tasks (#496, `SidebarSections.work`), less what Clear done took (`lists`).
    func work(since: Date, seen: Set<String>) -> [WorkList.Item<SidebarSections.JobRow>] {
        SidebarSections.work(local: desk.jobs.filter(lists), runner: feed.jobs.filter(lists), since: since, seen: seen)
    }
}


/// The side panel (Sangam's Sidebar.tsx): the icon strip on the far left (Home, the conversation
/// with Oby, your account at the foot), and beside it Home's work, grouped by kind or by status
/// (#496, its ⋮ picks), each group folding open to its tasks. It opens from the left and pushes
/// the view over.
struct SidebarView: View {
    let model: IslandModel
    let state: ChatState
    let width: CGFloat
    let onNewTask: () -> Void
    let onOpenSettings: (SettingsTab) -> Void
    @AppStorage(GroupBy.key) private var groupBy = GroupBy.type
    @State private var search = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    /// Groups folded away; while searching, every group with a match opens.
    @State private var folded: Set<String> = []
    /// Groups showing all their done tasks (Show more), not just the latest few.
    @State private var more: Set<String> = []

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }
    private var work: [WorkList.Item<SidebarSections.JobRow>] { model.work(since: state.since, seen: state.seen) }
    private var groups: [WorkList.Group<SidebarSections.JobRow>] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let items = work.filter {
            query.isEmpty || $0.job.job.heading.localizedCaseInsensitiveContains(query)
                || $0.job.job.agentName.localizedCaseInsensitiveContains(query)
        }
        return WorkList.groups(items, by: groupBy)
    }

    var body: some View {
        HStack(spacing: 0) {
            IconStrip(model: model, state: state, work: work, onOpenSettings: onOpenSettings)
            content
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) { Tokens.edge.frame(width: 1) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Home").font(Tokens.font(Tokens.textTitle, .semibold)).foregroundStyle(Tokens.ink)
                    .lineLimit(1).frame(height: 32).padding(.horizontal, 10)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Menu {
                    Picker("Group by", selection: $groupBy) {
                        ForEach(GroupBy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { IconButton(symbol: "ellipsis", rotated: true) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Home options")
            }
            .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if searching { searchField.transition(.opacity.combined(with: .move(edge: .top))) }
                    PanelRow(symbol: "plus", title: "New task", action: onNewTask).padding(.bottom, 8)
                    ForEach(groups) { group($0) }
                    if groups.isEmpty {
                        Text(search.isEmpty ? "Nothing here yet. Ask Oby for something and it shows up here." : "No tasks match “\(search)”")
                            .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 16).padding(.top, state.chrome.bar)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Search, on the panel icon's row at the panel's right edge.
        .overlay(alignment: .topTrailing) {
            IconButton(symbol: "magnifyingglass", on: searching) {
                withAnimation(Tokens.warm) { searching.toggle() }
                if searching { searchFocused = true } else { search = "" }
            }
            .accessibilityLabel("Search")
            .padding(.trailing, 10).padding(.top, (state.chrome.bar - 32) / 2)
        }
        .background { WindowDragArea() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(Tokens.font(12)).foregroundStyle(Tokens.muted)
            TextField("Search", text: $search).textFieldStyle(.plain).font(Tokens.font(Tokens.textMd))
                .foregroundStyle(Tokens.ink).focused($searchFocused)
                .onExitCommand { withAnimation(Tokens.warm) { searching = false }; search = "" }
        }
        .padding(.horizontal, 10).frame(height: 34)
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(searchFocused ? Tokens.lineFocus : Tokens.line) }
        .padding(.bottom, 8)
    }

    /// One group: its label folds it (a chevron after it; folded, an orange dot when something in it
    /// needs you; its count when anything's open), then its rows, then Show more past the latest done.
    private func group(_ group: WorkList.Group<SidebarSections.JobRow>) -> some View {
        let open = !folded.contains(group.id) || !search.isEmpty
        let shown = WorkList.shown(group, more: more.contains(group.id))
        return VStack(alignment: .leading, spacing: 1) {
            GroupHead(group: group, open: open) {
                withAnimation(Tokens.warm) { _ = folded.formSymmetricDifference([group.id]) }
            } onOpen: {
                if let kind = group.type { state.trail.start(.group(kind)) }
            }
            if open {
                ForEach(shown.rows) { TaskRow(item: $0, model: model, state: state) }
                if shown.hidden > 0 {
                    Button(more.contains(group.id) ? "Show less" : "Show \(shown.hidden) more") { more.formSymmetricDifference([group.id]) }
                        .buttonStyle(PanelButtonStyle(color: Tokens.muted, font: Tokens.font(Tokens.textSm), height: 30))
                }
                Color.clear.frame(height: 12)
            }
        }
        .padding(.top, 4)
    }
}

/// A group's label row: 12-point label, a chevron right after it (down while open, up folded),
/// then at the right the orange dot (folded) and the count.
private struct GroupHead: View {
    let group: WorkList.Group<SidebarSections.JobRow>
    let open: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Text(group.label).font(Tokens.font(Tokens.textSm)).lineLimit(1).layoutPriority(1)
                Image(systemName: "chevron.down").font(Tokens.font(9, .semibold))
                    .rotationEffect(.degrees(open ? 0 : 180)).accessibilityHidden(true)
                Spacer(minLength: 4)
                if !open && group.needs > 0 {
                    Circle().fill(Tokens.needs).frame(width: 6, height: 6)
                        .accessibilityLabel("\(group.needs) need\(group.needs == 1 ? "s" : "") you")
                }
                if group.count > 0 {
                    Text("\(group.count)").font(Tokens.font(Tokens.textSm)).monospacedDigit()
                        .accessibilityLabel("\(group.count) \(group.countLabel)")
                }
            }
            .foregroundStyle(hovering ? Tokens.text : Tokens.label)
            .padding(.horizontal, 10).frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Tokens.fade, value: hovering)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(open ? "Open" : "Folded")
        .contextMenu { if group.type != nil { Button("Open \(group.label)", action: onOpen) } }
    }
}

/// A task on Home: its agent's mark, its name, and at the end its state; on hover its ⋮ in the
/// same spot. Open while it's working, dimmed once it's done.
private struct TaskRow: View {
    let item: WorkList.Item<SidebarSections.JobRow>
    let model: IslandModel
    let state: ChatState
    @State private var hovering = false

    private var job: Job { item.job.job }
    private var local: Bool { item.job.local }
    private var step: WindowStep { .job(id: job.id, local: local) }
    private var picked: Bool { state.trail.shows(job: job.id, local: local) }
    private var done: Bool { item.status == .done }

    var body: some View {
        HStack(spacing: 8) {
            AgentMark(agent: job.agent, mono: true).font(Tokens.font(12, .semibold)).frame(width: 14)
                .foregroundStyle(done ? Tokens.doneTitle : Tokens.muted)
            Text(job.heading).font(Tokens.font(Tokens.textBase))
                .foregroundStyle(hovering || picked ? .white : done ? Tokens.doneTitle : Tokens.openTitle)
                .fadeOut()
            Spacer(minLength: 4)
            ZStack {
                WorkMarkView(mark: item.mark).opacity(hovering ? 0 : 1)
                if hovering { menu }
            }
            .frame(width: 22)
        }
        .padding(.leading, 10).padding(.trailing, 5).frame(height: 34)
        .background(picked ? Tokens.active : hovering ? Tokens.hover : .clear, in: RoundedRectangle(cornerRadius: Tokens.rowRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .onHover { hovering = $0 }
        .animation(Tokens.fade, value: hovering)
        .help(local ? "On this Mac" : "On \(model.feed.name)")
        .contextMenu { actions }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(job.heading), \(item.mark.rawValue)")
        .accessibilityAction { open() }
    }

    private func open() {
        state.trail.start(step)
    }

    private var menu: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(Tokens.font(12, .medium))
                .foregroundStyle(Tokens.text).frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More for \(job.heading)")
    }

    @ViewBuilder private var actions: some View {
        Button("View details") { open() }
        if ConversationModel.started(job.id, in: model.thread) {
            Button("Go to conversation") { state.trail.start(step, .talk) }
        }
        if job.isActive { Button("Stop") { model.stopChatJob(job.id, local: local) } }
    }
}

/// The far-left column: one icon per place (Home, the conversation with Oby), your account's
/// picture at the foot, which opens your account's menu (Settings is in it).
private struct IconStrip: View {
    let model: IslandModel
    let state: ChatState
    let work: [WorkList.Item<SidebarSections.JobRow>]
    let onOpenSettings: (SettingsTab) -> Void

    private var homeDot: Color? {
        if work.contains(where: { $0.status == .needs }) { return Tokens.needs }
        return work.contains(where: \.fresh) ? Tokens.unread : nil
    }

    var body: some View {
        VStack(spacing: 12) {
            RailButton(symbol: "house", label: "Home", on: state.trail.isHome, dot: homeDot) { state.trail.closeAll() }
            RailButton(symbol: "bubble.left.and.bubble.right", label: "Conversation with Oby", on: state.trail.top == .talk,
                       dot: model.unreadReply ? Tokens.unread : nil) { state.open() }
                .accessibilityLabel(SidebarSections.obyLabel(last: model.thread.last?.text, unread: model.unreadReply))
            Spacer(minLength: 0)
            account
        }
        .padding(.top, state.chrome.bar).padding(.bottom, 10)
        .frame(width: Tokens.rail)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) { Tokens.edge.frame(width: 1).padding(.top, state.chrome.bar) }
        .background { WindowDragArea() }
    }

    /// You: your name on this Mac, and who pays for the first account (the team), else this Mac.
    private var account: some View {
        let name = NSFullUserName()
        let payer = model.desk.accounts.accounts.map(\.account.payer).first { !$0.isEmpty }
            ?? model.feed.host.map { "Runner: \($0)" } ?? "This Mac"
        return Menu {
            Section("\(name) · \(payer)") {
                Button("Accounts…") { onOpenSettings(.accounts) }
                Button("Integrations…") { onOpenSettings(.runner) }
            }
            Divider()
            Button("Settings…") { onOpenSettings(.general) }
        } label: {
            Text(SidebarSections.initials(name)).font(Tokens.font(10, .semibold)).foregroundStyle(.white.opacity(0.92))
                .frame(width: 24, height: 24).background(Tokens.avatar(name), in: Circle())
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Account")
        .accessibilityLabel("\(name)’s account")
    }
}

/// An icon in the strip: muted at rest, lit hovered, filled and lit while its place shows; a dot
/// centred under it when something there is new (blue) or needs you (orange).
private struct RailButton: View {
    let symbol: String
    let label: String
    let on: Bool
    var dot: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "\(symbol).fill" : symbol).font(Tokens.font(15))
                .foregroundStyle(on ? Tokens.ink : hovering ? Tokens.text : Tokens.railIcon)
                .frame(width: 32, height: 32)
                .background(on ? Tokens.active : hovering ? Tokens.hover : .clear, in: RoundedRectangle(cornerRadius: Tokens.iconRadius, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let dot { Circle().fill(dot).frame(width: 5, height: 5).offset(y: 4).accessibilityHidden(true) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Tokens.fade, value: hovering)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A 32-point icon button (Sangam's `.icon-button`): muted, lit hovered, filled while on.
struct IconButton: View {
    let symbol: String
    var rotated = false
    var on = false
    var size: CGFloat = 32
    var action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { face }.buttonStyle(.plain)
        } else {
            face
        }
    }

    private var face: some View {
        Image(systemName: symbol).font(Tokens.font(14, .medium)).rotationEffect(.degrees(rotated ? 90 : 0))
            .foregroundStyle(on || hovering ? Tokens.text : Tokens.muted)
            .frame(width: size, height: size)
            .background(on ? Tokens.active : hovering ? Tokens.hover : .clear, in: RoundedRectangle(cornerRadius: Tokens.iconRadius, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Tokens.fade, value: hovering)
    }
}

/// A row in the side panel that starts something (New task): an icon and a label.
private struct PanelRow: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(Tokens.font(13, .regular)).frame(width: 16)
                Text(title).font(Tokens.font(Tokens.textBase)).lineLimit(1)
            }
        }
        .buttonStyle(PanelButtonStyle(color: Tokens.item, font: Tokens.font(Tokens.textBase), height: 34))
    }
}

/// A full-width side panel button: its colour at rest, ink on a faint fill hovered.
struct PanelButtonStyle: ButtonStyle {
    var color: Color
    var font: Font
    var height: CGFloat

    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, style: self) }

    private struct Styled: View {
        let configuration: Configuration
        let style: PanelButtonStyle
        @State private var hovering = false

        var body: some View {
            configuration.label.font(style.font)
                .foregroundStyle(hovering ? Tokens.ink : style.color)
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: style.height, maxHeight: style.height, alignment: .leading)
                .background(hovering || configuration.isPressed ? Tokens.hover : .clear, in: RoundedRectangle(cornerRadius: Tokens.rowRadius, style: .continuous))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(Tokens.fade, value: hovering)
        }
    }
}

/// A task's one mark at the end of its row (#496, Sangam's StatusDot): an 8-point dot, blue while
/// new, orange when it needs you, grey and pulsing slowly while working; nothing while queued (the
/// spot stays, so rows line up); a small grey check once done.
struct WorkMarkView: View {
    let mark: WorkMark
    var dot: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch mark {
            case .new: Circle().fill(Tokens.unread).frame(width: dot, height: dot)
            case .needs: Circle().fill(Tokens.needs).frame(width: dot, height: dot)
            case .working:
                if reduceMotion {
                    Circle().fill(Tokens.working).frame(width: dot, height: dot).opacity(0.8)
                } else {
                    PhaseAnimator([0.2, 1.0]) { level in
                        Circle().fill(Tokens.working).frame(width: dot, height: dot).opacity(level)
                    } animation: { _ in .easeInOut(duration: 0.8) }
                }
            case .queued: Color.clear
            case .done: Image(systemName: "checkmark").font(Tokens.font(9, .semibold)).foregroundStyle(Tokens.check)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityElement()
        .accessibilityLabel(mark.rawValue)
    }
}

/// Empty room in the window's chrome that drags the window, as a title bar does.
struct WindowDragArea: View {
    var body: some View {
        Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
    }
}
