import AppKit
import SwiftUI

/// What the window shows in its middle column (apps/mac/app/App/ChatWindow.swift).
nonisolated enum ChatSelection: Hashable, Sendable {
    /// The conversation with Oby.
    case oby
    /// One job's screen: its id, and whether it's this Mac's own (else the runner's).
    case job(id: String, local: Bool)
    case channels
    case obys
    /// A kind of work's page (#496): its Running and Completed tabs.
    case group(WorkType)
}

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

    /// What Channels says until F11 brings them, and Obys until F12: honest empty states, no fake data.
    static let channelsEmpty = "Team channels come with F11."
    static let obysEmpty = "Other people's Obys come with F12."

    /// What Oby's pinned row says under its name: the last message, or a hello.
    static func obyPreview(_ last: String?) -> String {
        last ?? "Say hello to Oby"
    }

    /// What VoiceOver reads for Oby's pinned row: what it shows, and an unread reply.
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

/// A messenger chat list: pinned Oby with a preview and unread dot, the work grouped by kind or by
/// status (#496, Home's ⋮ picks), and account/settings links below.
struct SidebarView: View {
    let model: IslandModel
    @State private var search = ""
    @Binding var selection: ChatSelection
    /// When the window's state began and the rows opened since, for the blue "new" mark.
    let since: Date
    let seen: Set<String>
    let onOpenSettings: (SettingsTab) -> Void
    @AppStorage(GroupBy.key) private var groupBy = GroupBy.type
    /// Groups folded away; while searching, every group with a match opens.
    @State private var folded: Set<String> = []
    /// Groups showing all their done tasks (Show more), not just the latest few.
    @State private var more: Set<String> = []

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }
    private var groups: [WorkList.Group<SidebarSections.JobRow>] {
        let items = model.work(since: since, seen: seen).filter {
            search.isEmpty || $0.job.job.heading.localizedCaseInsensitiveContains(search)
                || $0.job.job.agentName.localizedCaseInsensitiveContains(search)
        }
        return WorkList.groups(items, by: groupBy)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search chats", text: $search)
                .textFieldStyle(.plain).font(OBYStyle.small)
                .padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 14).padding(.top, 46).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if search.isEmpty || "Oby".localizedCaseInsensitiveContains(search) || (model.thread.last?.text.localizedCaseInsensitiveContains(search) ?? false) { obyRow }
                    ForEach(groups) { group($0) }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                link("Accounts", symbol: "key") { onOpenSettings(.accounts) }
                link("Integrations", symbol: "link") { onOpenSettings(.runner) }
                link("Settings", symbol: "gearshape") { onOpenSettings(.general) }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            Divider().overlay(.white.opacity(0.08))
            you.padding(.horizontal, 14).padding(.vertical, 14)
        }
        .background(OBYStyle.sidebar)
    }

    private var preview: String {
        let waiting = IslandInbox.entries(desk: desk, feed: feed, now: .now).count + feed.chatPermissions.count { $0.waits(at: .now) }
        if waiting > 0 { return "Waiting on your yes" }
        if model.working > 0 { return "\(model.working) working" }
        return SidebarSections.obyPreview(model.thread.last?.text)
    }

    private var obyRow: some View {
        Button { selection = .oby } label: {
            HStack(spacing: 12) {
                ObyFace(size: 40).background(OBYStyle.surface, in: Circle()).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Oby").font(OBYStyle.body.weight(.bold))
                    Text(preview).lineLimit(1).font(OBYStyle.caption).foregroundStyle(OBYStyle.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    if let last = model.thread.last {
                        Text(Date.now.timeIntervalSince(last.date) < 60 ? "now" : ConversationModel.clock(last.date)).font(OBYStyle.caption).foregroundStyle(OBYStyle.tertiary)
                    }
                    let waiting = IslandInbox.entries(desk: desk, feed: feed, now: .now).count + feed.chatPermissions.count { $0.waits(at: .now) }
                    if waiting > 0 {
                        Text("\(waiting)").font(OBYStyle.caption.weight(.semibold))
                            .padding(.horizontal, OBYStyle.Space.sm).padding(.vertical, OBYStyle.Space.xs)
                            .background(OBYStyle.accent, in: Capsule()).accessibilityLabel("\(waiting) waiting for you")
                    } else if model.unreadReply {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7).accessibilityLabel("Unread reply")
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(selection == .oby ? OBYStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SidebarSections.obyLabel(last: model.thread.last?.text, unread: model.unreadReply))
    }

    /// One group: its header folds it (an orange dot when something in it needs you, its count when
    /// anything's open), then its rows, then Show more past the latest done ones.
    private func group(_ group: WorkList.Group<SidebarSections.JobRow>) -> some View {
        let open = !folded.contains(group.id) || !search.isEmpty
        let shown = WorkList.shown(group, more: more.contains(group.id))
        return VStack(alignment: .leading, spacing: 2) {
            Button { folded.formSymmetricDifference([group.id]) } label: {
                HStack(spacing: 6) {
                    Text(group.label).font(OBYStyle.caption.weight(.medium)).foregroundStyle(.white.opacity(0.45))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
                        .rotationEffect(.degrees(open ? 0 : -90)).accessibilityHidden(true)
                    Spacer()
                    if group.needs > 0 {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                            .accessibilityLabel("\(group.needs) need\(group.needs == 1 ? "s" : "") you")
                    }
                    if group.count > 0 {
                        Text("\(group.count)").font(OBYStyle.caption).foregroundStyle(.white.opacity(0.45))
                            .accessibilityLabel("\(group.count) \(group.countLabel)")
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(open ? "Open" : "Folded")
            .contextMenu {
                if let kind = group.type { Button("Open \(group.label)") { selection = .group(kind) } }
            }
            if open {
                ForEach(shown.rows) { row($0) }
                if shown.hidden > 0 {
                    Button(more.contains(group.id) ? "Show less" : "Show \(shown.hidden) more") { more.formSymmetricDifference([group.id]) }
                        .buttonStyle(.plain).font(OBYStyle.caption).foregroundStyle(OBYStyle.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                }
            }
        }
    }

    private func row(_ item: WorkList.Item<SidebarSections.JobRow>) -> some View {
        let job = item.job.job, local = item.job.local
        let picked = selection == .job(id: job.id, local: local)
        return Button { selection = .job(id: job.id, local: local) } label: {
            HStack(spacing: 10) {
                AgentMark(agent: job.agent).font(.system(size: 14, weight: .semibold)).frame(width: 18)
                Text(job.heading).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    .foregroundStyle(item.status == .done ? OBYStyle.secondary : OBYStyle.primary)
                Spacer(minLength: 6)
                WorkMarkView(mark: item.mark)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(picked ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(local ? "On this Mac" : "On \(feed.name)")
    }

    private func emptyRow(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(OBYStyle.small).foregroundStyle(OBYStyle.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.white.opacity(selected ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func link(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .medium))
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// You: your name on this Mac, and who pays for the first account (the team), else this Mac.
    private var you: some View {
        let name = NSFullUserName()
        let payer = desk.accounts.accounts.map(\.account.payer).first { !$0.isEmpty } ?? feed.host.map { "Runner: \($0)" } ?? "This Mac"
        return HStack(spacing: 12) {
            Text(SidebarSections.initials(name)).font(.system(size: 12, weight: .semibold))
                .frame(width: 40, height: 40).background(.white.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(payer).font(OBYStyle.caption).foregroundStyle(OBYStyle.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A task's one mark at the end of its row (#496): blue while new, orange when it needs you, gray
/// while working, nothing while queued (the spot stays, so rows line up), a small check when done.
struct WorkMarkView: View {
    let mark: WorkMark

    var body: some View {
        Group {
            switch mark {
            case .new: Circle().fill(.blue).frame(width: 8, height: 8)
            case .needs: Circle().fill(.orange).frame(width: 8, height: 8)
            case .working: Circle().fill(.gray).frame(width: 8, height: 8)
            case .queued: Color.clear
            case .done: Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(OBYStyle.tertiary)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityElement()
        .accessibilityLabel(mark.rawValue)
    }
}
