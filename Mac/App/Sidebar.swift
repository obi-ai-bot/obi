import AppKit
import SwiftUI

/// What the window shows in its middle column (Mac/App/ChatWindow.swift).
nonisolated enum ChatSelection: Hashable, Sendable {
    /// The conversation with Oby.
    case oby
    /// One job's screen: its id, and whether it's this Mac's own (else the runner's).
    case job(id: String, local: Bool)
    case channels
    case obys
}

/// The sidebar's sections, as the window lists them: what each row says, with no view in the
/// way, so the tests read them (MacTests/SidebarTests.swift).
nonisolated enum SidebarSections {
    /// A job in Agents: running, or needing you, with its dot.
    struct AgentRow: Identifiable, Equatable, Sendable {
        enum Dot: Sendable { case working, waiting, needsYou }
        var job: Job
        var local: Bool
        var dot: Dot
        var id: String { (local ? "mac/" : "runner/") + job.id }
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

    /// "2 active" beside Agents, or "None".
    static func activeLine(_ rows: [AgentRow]) -> String {
        rows.isEmpty ? "None" : "\(rows.count) active"
    }

    /// The jobs the sidebar lists under Agents: every one that's queued or running (a gray dot for
    /// one waiting its turn, #238), and every one that needs you, this Mac's and the runner's, most
    /// recently active first. Dismissed and finished jobs stay
    /// out: the window's job cards and the island's list have them.
    static func agents(local: [Job], runner: [Job]) -> [AgentRow] {
        let rows = local.map { ($0, true) } + runner.map { ($0, false) }
        return rows.compactMap { job, local in
            if job.isWaiting { return AgentRow(job: job, local: local, dot: .waiting) }
            if job.isActive { return AgentRow(job: job, local: local, dot: .working) }
            if job.needsYou { return AgentRow(job: job, local: local, dot: .needsYou) }
            return nil
        }
        .sorted {
            let left = activity($0.job), right = activity($1.job)
            return left == right ? $0.id < $1.id : left > right
        }
    }

    static func activity(_ job: Job) -> Date {
        [job.created, job.started, job.finished, job.pullRequest?.checkedAt].compactMap { $0 }.max() ?? job.created
    }

    /// "WP" for Wellington Prado: the first letters of the first two names.
    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return parts.isEmpty ? "?" : String(parts).uppercased()
    }
}

/// A messenger chat list: pinned Oby with a preview and unread dot, searchable agent
/// chats by activity, future channels and Obys, and account/settings links below.
struct SidebarView: View {
    let model: IslandModel
    @State private var search = ""
    @Binding var selection: ChatSelection
    let onOpenSettings: (SettingsTab) -> Void

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }
    private var agents: [SidebarSections.AgentRow] {
        SidebarSections.agents(local: desk.jobs, runner: feed.jobs).filter {
            search.isEmpty || $0.job.heading.localizedCaseInsensitiveContains(search)
                || $0.job.agentName.localizedCaseInsensitiveContains(search)
        }
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
                    if !agents.isEmpty { agentsSection }
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

    private var agentsSection: some View {
        section("Agents", trailing: SidebarSections.activeLine(agents)) {
            if agents.isEmpty {
                Text("No agent is working.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            ForEach(agents) { row in
                let picked = selection == .job(id: row.job.id, local: row.local)
                Button { selection = .job(id: row.job.id, local: row.local) } label: {
                    HStack(spacing: 10) {
                        AgentMark(agent: row.job.agent).font(.system(size: 14, weight: .semibold)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.job.heading).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            Text(row.job.line).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Circle().fill(row.dot.color).frame(width: 8, height: 8)
                            .accessibilityLabel(row.dot.label)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.white.opacity(picked ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(row.local ? "On this Mac" : "On \(feed.name)")
            }
        }
    }
    private func section(_ title: String, trailing: String?, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(OBYStyle.caption.weight(.medium)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                if let trailing { Text(trailing).font(OBYStyle.caption).foregroundStyle(.white.opacity(0.45)) }
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            content()
        }
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

extension SidebarSections.AgentRow.Dot {
    var color: Color {
        switch self {
        case .working: .blue
        case .waiting: .gray
        case .needsYou: .orange
        }
    }

    var label: String {
        switch self {
        case .working: "Working"
        case .waiting: "Waiting"
        case .needsYou: "Needs you"
        }
    }
}
