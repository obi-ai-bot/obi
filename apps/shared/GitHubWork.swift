import SwiftUI

// The model these cards show is in GitHubWorkModel.swift (Foundation only: obid's mac_app test compiles it).

#if os(iOS) || os(macOS)
/// A GitHub item waiting to start, as a card in Review PR or Issues (Sangam's TaskCard with its
/// "Start it?" decision): GitHub's mark, who and what, the repository, then the headline and the
/// one tap that starts Oby's job, Open on GitHub, and Later.
struct GitHubCard: View {
    /// Its start button (filled, first) and Open on GitHub; Later is the card's own.
    static func options(_ item: GitHubWork.Item) -> [CardOption] {
        (item.action.map { [CardOption(label: $0, answer: $0, recommended: true)] } ?? [])
            + (item.page == nil ? [] : [CardOption(label: "Open on GitHub", answer: "open")])
    }
    /// No line under the choices saying what each does: Sangam's GitHub card has none.
    static let explains = false

    let item: GitHubWork.Item
    let start: () async throws -> Void
    let later: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image("GitHub").resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(Tokens.muted)
                    .accessibilityLabel("GitHub")
                (Text(verbatim: item.who.map { $0 + "  " } ?? "").foregroundStyle(Tokens.muted)
                    + Text(verbatim: item.heading).foregroundStyle(Tokens.ink))
                    .font(Tokens.font(Tokens.textLg, .semibold)).lineLimit(2)
                Spacer(minLength: 8)
                if let updated = item.updated {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(TaskFacts.duration(context.date.timeIntervalSince(updated))).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
                    }
                }
            }
            HStack(spacing: 8) {
                Text(verbatim: item.repoName).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted).lineLimit(1)
                // Its board column, "Todo" or "In progress", when it's on a project board.
                if let column = item.column {
                    Text(verbatim: column).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.text).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(Tokens.pill, in: Capsule())
                }
            }
            .padding(.leading, 26).padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                AskCard(kind: item.label, title: item.headline, happened: item.note, options: Self.options(item),
                        busy: busy, explains: Self.explains,
                        onChoose: { option in
                            if option.answer == "open" { item.page.map { openURL($0) }; return }
                            busy = true
                            Task {
                                defer { busy = false }
                                do { try await start(); problem = nil } catch { problem = error.localizedDescription }
                            }
                        },
                        onLater: later)
                if let problem { Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger).padding(.top, 8) }
            }
            .padding(.top, 14)
            .overlay(alignment: .top) { Tokens.divider.frame(height: 1) }
            .padding(.top, 16)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(item.who.map { $0 + ", " } ?? "")\(item.heading), \(item.column.map { $0 + ", " } ?? "")\(item.label)"))
    }
}

/// A kind's To do tab (Review PR and Issues): Connect GitHub while gh is signed out, then the
/// items no job works on yet by board column, each column's name over its cards once any item is
/// on a board, then what obid cut and why its last read of GitHub failed.
struct GitHubToDo: View {
    let kind: WorkType
    let work: GitHubWork?
    let columns: [GitHubWork.Column]
    let connect: ConnectGitHubCard?
    /// GitHub hasn't answered yet: cards are placeholders, not "Nothing to do".
    var loading = false
    /// Other cards the page shows in To do (the Mac's alert offers under Issues): not "Nothing to do" then.
    var others = 0
    let start: (GitHubWork.Item) async throws -> Void
    let later: (GitHubWork.Item) -> Void

    var body: some View {
        if let connect { connect }
        let named = columns.contains { $0.name != nil }
        // Two projects' boards: each column says whose it is.
        let projects = Set(columns.compactMap(\.project)).count > 1
        ForEach(columns) { column in
            if named {
                Text(verbatim: column.name.map { name in projects ? column.project.map { "\(name) · \($0)" } ?? name : name } ?? GitHubWork.offBoard).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.muted)
                    .padding(.horizontal, 4).padding(.top, 8).accessibilityAddTraits(.isHeader)
            }
            ForEach(column.items) { item in
                GitHubCard(item: item, start: { try await start(item) }, later: { later(item) })
            }
        }
        ForEach(work?.cut(kind) ?? [], id: \.self) { line in
            Text(line).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.horizontal, 4)
        }
        if let problem = work?.error {
            Text(verbatim: GitHubWork.plain(problem)).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).padding(.horizontal, 4)
        }
        if columns.isEmpty && connect == nil && others == 0 {
            if loading {
                CardBones()
            } else {
                Text("Nothing to do").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.vertical, 8).padding(.horizontal, 4)
            }
        }
    }
}

/// Connect GitHub, at the top of Review PR and Issues while obid's gh is signed out: why, then the
/// one way in (`connect`; nil where it can't be done, as on the iPhone). Not in Sangam's design.
struct ConnectGitHubCard: View {
    let line: String
    let connect: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("GitHub").resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(Tokens.muted)
                Text("Connect GitHub").font(Tokens.font(Tokens.textLg, .semibold)).foregroundStyle(Tokens.ink)
            }
            Text(line).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            if let connect {
                Button("Connect GitHub", action: connect).buttonStyle(.set).padding(.top, 14)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Projects, milestones and repositories on a To do list, each one menu. Everything starts on.
/// Choosing one keeps it; another adds it; clearing the last one shows every one again.
struct WorkFilters: View {
    let columns: [GitHubWork.Column]
    @Binding var projects: String
    @Binding var repos: String
    @Binding var milestones: String

    var body: some View {
        let projectNames = GitHubWork.projectNames(columns)
        let repoNames = GitHubWork.repoNames(columns)
        let mileNames = GitHubWork.milestoneNames(columns)
        if projectNames.count > 1 || repoNames.count > 1 || mileNames.count > 1 {
            HStack(spacing: 8) {
                if projectNames.count > 1 { menu("Projects", names: projectNames, raw: $projects) }
                if mileNames.count > 1 { menu("Milestones", names: mileNames, raw: $milestones) }
                if repoNames.count > 1 { RepoMenu(names: repoNames, raw: $repos) }
            }
        }
    }

    private func menu(_ title: String, names: [String], raw: Binding<String>) -> some View {
        let picked = GitHubWork.projectSet(raw.wrappedValue)
        let on = GitHubWork.shown(picked, among: names)
        let all = picked.isEmpty || on == Set(names)
        return Menu {
            Button {
                raw.wrappedValue = ""
            } label: {
                if all { Image(systemName: "checkmark") }
                Text("All")
            }
            Divider()
            ForEach(names, id: \.self) { name in
                Button {
                    var next = picked
                    GitHubWork.toggle(name, picked: &next, among: names)
                    raw.wrappedValue = GitHubWork.projectRaw(next)
                } label: {
                    if !all && on.contains(name) { Image(systemName: "checkmark") }
                    Text(verbatim: name)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: GitHubWork.filterLabel(title, raw: raw.wrappedValue, among: names))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(Tokens.font(Tokens.textSm))
            .foregroundStyle(all ? Tokens.muted : Tokens.ink)
            .padding(.horizontal, 10).frame(height: 26)
            .background(all ? Color.clear : Tokens.pill, in: Capsule())
            .overlay { Capsule().strokeBorder(all ? Tokens.line : Color.clear) }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// Repositories, as one dropdown: a search field and a checkbox for each match, and it stays open
/// so several can be chosen. Everything starts on.
private struct RepoMenu: View {
    let names: [String]
    @Binding var raw: String
    @State private var open = false
    @State private var query = ""
    @FocusState private var search: Bool

    var body: some View {
        let picked = GitHubWork.projectSet(raw)
        let on = GitHubWork.shown(picked, among: names)
        let all = picked.isEmpty || on == Set(names)
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(verbatim: GitHubWork.filterLabel("Repositories", raw: raw, among: names))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(Tokens.font(Tokens.textSm))
            .foregroundStyle(all ? Tokens.muted : Tokens.ink)
            .padding(.horizontal, 10).frame(height: 26)
            .background(all ? Color.clear : Tokens.pill, in: Capsule())
            .overlay { Capsule().strokeBorder(all ? Tokens.line : Color.clear) }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Repositories")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            panel(picked: picked, on: on, all: all)
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: open) { _, shown in if !shown { query = "" } }
    }

    private func panel(picked: Set<String>, on: Set<String>, all: Bool) -> some View {
        let shown = GitHubWork.matching(names, query)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                TextField("Filter repositories", text: $query)
                    .textFieldStyle(.plain)
                    .font(Tokens.font(Tokens.textSm))
                    .focused($search)
                    .accessibilityLabel("Filter repositories")
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(Tokens.field, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tokens.line) }
            .padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        row("All repositories", chosen: all) { raw = "" }
                    }
                    if shown.isEmpty {
                        Text("No repositories").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                            .padding(.horizontal, 8).frame(height: 28, alignment: .leading)
                    }
                    ForEach(shown, id: \.self) { name in
                        row(name, chosen: !all && on.contains(name)) {
                            var next = picked
                            GitHubWork.toggle(name, picked: &next, among: names)
                            raw = GitHubWork.projectRaw(next)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .frame(width: 280)
        .padding(.bottom, 6)
        .onAppear { search = true }
    }

    private func row(_ name: String, chosen: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(systemName: chosen ? "checkmark.square.fill" : "square")
                    .font(Tokens.font(Tokens.textSm))
                    .foregroundStyle(chosen ? Tokens.ink : Tokens.muted)
                    .frame(width: 14)
                Text(verbatim: name).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
#endif
