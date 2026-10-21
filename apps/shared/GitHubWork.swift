import SwiftUI

// The model these cards show is in GitHubWorkModel.swift (Foundation only: obid's mac_app test compiles it).

#if os(iOS) || os(macOS)
/// A GitHub item waiting to start, as a card in Review PR or Issues (Sangam's TaskCard with its
/// "Start it?" decision): GitHub's mark, who and what, the repository, then the headline and the
/// one tap that starts Oby's job, Open on GitHub, and Later.
struct GitHubCard: View {
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
                AskCard(kind: item.label, title: item.headline, happened: item.note,
                        options: (item.action.map { [CardOption(label: $0, answer: $0, detail: item.actionDetail, recommended: true)] } ?? [])
                            + (item.page == nil ? [] : [CardOption(label: "Open on GitHub", answer: "open")]),
                        busy: busy,
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
    let start: (GitHubWork.Item) async throws -> Void
    let later: (GitHubWork.Item) -> Void

    var body: some View {
        if let connect { connect }
        let named = columns.contains { $0.name != nil }
        // Two projects' boards: each column says whose it is.
        let projects = Set(columns.compactMap(\.project)).count > 1
        ForEach(columns) { column in
            if named {
                Text(verbatim: column.name.map { name in projects ? column.project.map { "\(name) · \($0)" } ?? name : name } ?? "Not on a board").font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.muted)
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
        if columns.isEmpty && connect == nil {
            Text("Nothing to do").font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.vertical, 8).padding(.horizontal, 4)
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
#endif
