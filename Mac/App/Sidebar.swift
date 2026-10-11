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
        enum Dot: Sendable { case working, needsYou }
        var job: Job
        var local: Bool
        var dot: Dot
        var id: String { (local ? "mac/" : "runner/") + job.id }
    }

    /// What Channels says until F11 brings them, and Obys until F12: honest empty states, no fake data.
    static let channelsEmpty = "Team channels come with F11."
    static let obysEmpty = "Other people's Obys come with F12."

    /// "2 working" under Oby's name, or "Quiet".
    static func obyLine(working: Int) -> String {
        working == 0 ? "Quiet" : "\(working) working"
    }

    /// "2 active" beside Agents, or "None".
    static func activeLine(_ rows: [AgentRow]) -> String {
        rows.isEmpty ? "None" : "\(rows.count) active"
    }

    /// The jobs the sidebar lists under Agents: every one that's queued or running, and every one
    /// that needs you, this Mac's and the runner's, newest first. Dismissed and finished jobs stay
    /// out: the window's job cards and the island's list have them.
    static func agents(local: [Job], runner: [Job]) -> [AgentRow] {
        let rows = local.map { ($0, true) } + runner.map { ($0, false) }
        return rows.compactMap { job, local in
            if job.isActive { return AgentRow(job: job, local: local, dot: .working) }
            if job.needsYou { return AgentRow(job: job, local: local, dot: .needsYou) }
            return nil
        }
        .sorted { $0.job.created > $1.job.created }
    }

    /// "WP" for Wellington Prado: the first letters of the first two names.
    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return parts.isEmpty ? "?" : String(parts).uppercased()
    }
}

/// The window's sidebar, as `docs/images/app-chat.webp` has it: Oby with how many are working,
/// Agents (running and needs-you jobs, live dots), Channels and Obys with their empty states, then
/// Accounts and keys, Integrations, Memory and Settings (the Settings tabs), and you at the bottom.
struct SidebarView: View {
    let model: IslandModel
    @Binding var selection: ChatSelection
    let onOpenSettings: (SettingsTab) -> Void

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }
    private var agents: [SidebarSections.AgentRow] { SidebarSections.agents(local: desk.jobs, runner: feed.jobs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    obyRow
                    agentsSection
                    section("Channels", trailing: nil) {
                        emptyRow(SidebarSections.channelsEmpty, selected: selection == .channels) { selection = .channels }
                    }
                    section("Obys", trailing: nil) {
                        emptyRow(SidebarSections.obysEmpty, selected: selection == .obys) { selection = .obys }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 46)
                .padding(.bottom, 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                link("Accounts and keys", symbol: "key") { onOpenSettings(.accounts) }
                link("Integrations", symbol: "link") { onOpenSettings(.runner) }
                link("Memory", symbol: "cylinder") { onOpenSettings(.vault) }
                link("Settings", symbol: "gearshape") { onOpenSettings(.general) }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            Divider().overlay(.white.opacity(0.08))
            you.padding(.horizontal, 14).padding(.vertical, 14)
        }
        .background(Color(white: 0.11))
    }

    private var obyRow: some View {
        Button { selection = .oby } label: {
            HStack(spacing: 12) {
                ObyFace(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Oby").font(.system(size: 15, weight: .semibold))
                    Text(SidebarSections.obyLine(working: model.working)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(.white.opacity(selection == .oby ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Oby, \(SidebarSections.obyLine(working: model.working))")
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
                        Text(row.job.heading).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 6)
                        Circle().fill(row.dot == .working ? Color.blue : Color.orange).frame(width: 8, height: 8)
                            .accessibilityLabel(row.dot == .working ? "Working" : "Needs you")
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
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(.white.opacity(0.45))
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)) }
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func emptyRow(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.4))
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
                .frame(width: 34, height: 34).background(.white.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(payer).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
