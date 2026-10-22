import SwiftUI

/// The side panel's Conversations (Sangam's Sidebar.tsx, ConvoMenu.tsx; #493): obid's conversations,
/// Pinned above Recent, newest first. A row opens that conversation's history in the window; its ⋮
/// (or a right-click) pins, renames or deletes it, and New conversation opens an empty one that its
/// first words start. Only while the runner on this Mac serves them (`RunnerFeed.conversationsOn`).
struct ConversationsPanel: View {
    let model: IslandModel
    let state: ChatState
    let search: String
    @State private var renaming: String?
    /// What obid found for the search, in titles and in what was said; nil until it answers.
    @State private var results: [RunnerConversation]?

    private var list: ConversationList { model.feed.conversations }
    private var grouped: (pinned: [RunnerConversation], recent: [RunnerConversation]) {
        // Titles here at once; obid's answer, which reads what was said too, when it comes.
        guard let results, !search.trimmingCharacters(in: .whitespaces).isEmpty else { return ConversationList.sections(list.items, matching: search) }
        return ConversationOrder.sections(results)
    }

    var body: some View {
        let found = grouped
        VStack(alignment: .leading, spacing: 0) {
            PanelRow(symbol: "plus", title: "New conversation") {
                list.startNew()
                state.open()
            }
            .padding(.bottom, 8)
            if let problem = list.problem {
                Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
            if !found.pinned.isEmpty { head("Pinned") }
            ForEach(found.pinned) { row($0) }
            // No headings while nothing's pinned.
            if !found.pinned.isEmpty && !found.recent.isEmpty { head("Recent").padding(.top, 8) }
            ForEach(found.recent) { row($0) }
            if found.pinned.isEmpty && found.recent.isEmpty {
                if search.isEmpty && list.items.isEmpty && model.feed.connection == .connecting && !model.feed.showingKept {
                    RowBones(rows: 4)
                } else {
                    Text(search.isEmpty ? "Nothing here yet. Ask Oby for something and it shows up here." : "No conversations match “\(search)”")
                        .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
        }
        .task(id: search) {
            results = nil
            // A pause while typing, as the iPhone's search waits.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = await list.search(search)
        }
    }

    private func head(_ title: String) -> some View {
        Text(title).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.label)
            .padding(.horizontal, 10).frame(height: 26, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ conversation: RunnerConversation) -> some View {
        ConversationRow(conversation: conversation, list: list, state: state, renaming: $renaming)
    }
}

/// A conversation on the list: its title and, at the end, when it last moved; on hover its ⋮ in
/// the same spot.
private struct ConversationRow: View {
    let conversation: RunnerConversation
    let list: ConversationList
    let state: ChatState
    @Binding var renaming: String?
    @State private var hovering = false

    private var picked: Bool { list.shown == conversation.id && state.trail.top == .talk }
    private var editing: Bool { renaming == conversation.id }
    /// When it last moved, "5m"; nothing when the runner didn't say.
    private var moved: String { conversation.latest == .distantPast ? "" : ConversationOrder.ago(conversation.latest) }

    var body: some View {
        HStack(spacing: 0) {
            if editing {
                RenameField(label: "Conversation name", title: conversation.title, limit: 100) { title in
                    renaming = nil
                    if let title { Task { await list.rename(conversation.id, to: title) } }
                }
                .padding(.leading, 10)
            } else {
                self.title
            }
            ZStack {
                Text(moved).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                    .opacity(hovering ? 0 : 1)
                    .accessibilityLabel(moved.isEmpty ? "" : "Last active \(moved)")
                if hovering && !editing { menu }
            }
            .frame(minWidth: 22).padding(.leading, 4).padding(.trailing, 8)
        }
        .frame(height: 34)
        .background(picked ? Tokens.active : hovering ? Tokens.hover : .clear, in: RoundedRectangle(cornerRadius: Tokens.rowRadius, style: .continuous))
        .onHover { hovering = $0 }
        .animation(Tokens.fade, value: hovering)
        .contextMenu { actions }
    }

    private var title: some View {
        Button {
            state.open()
            Task { await list.open(conversation.id) }
        } label: {
            HStack(spacing: 8) {
                if conversation.pinned {
                    Image(systemName: "pin.fill").font(Tokens.font(10)).foregroundStyle(Tokens.muted).accessibilityHidden(true)
                }
                Text(conversation.title).font(Tokens.font(Tokens.textBase))
                    .foregroundStyle(hovering || picked ? .white : Tokens.openTitle)
                    .fadeOut()
            }
            .padding(.leading, 10).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(conversation.pinned ? "\(conversation.title), pinned" : conversation.title)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var menu: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(Tokens.font(12, .medium))
                .foregroundStyle(Tokens.text).frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More for \(conversation.title)")
    }

    private var actions: some View {
        ConversationMenu(conversation: conversation, list: list, onRename: { renaming = conversation.id },
                         onDelete: { state.deletingConversation = conversation })
    }
}

/// A conversation's menu (Sangam's ConvoMenu.tsx), from its side panel row (⋮ or right-click) or
/// its page's title bar: pin it to the top (or unpin), rename; last, set apart, delete it, which
/// asks first (the window's dialog, `taskDialogs`): it can't be undone.
struct ConversationMenu: View {
    let conversation: RunnerConversation
    let list: ConversationList
    let onRename: () -> Void
    let onDelete: () -> Void

    nonisolated static let deleteLine = "Its messages go for good. The tasks it started stay, each on its own page."

    var body: some View {
        Button(conversation.pinned ? "Unpin" : "Pin") { Task { await list.pin(conversation.id, !conversation.pinned) } }
        Button("Rename", action: onRename)
        Divider()
        Button("Delete conversation", role: .destructive, action: onDelete)
    }
}
