import SwiftUI

/// A task's menu (Sangam's TaskMenu.tsx), from its side panel row (⋮ or right-click), its card, or
/// its page's title bar: its page (not on the page itself), its conversation, Rename; then Stop
/// task while it's going, or Archive task once it's done (out of Home, into Archived); last, set
/// apart, Delete task, which asks first. Rename, Archive and Delete are obid's
/// (`IslandModel.managesJobs`): this Mac's own jobs have only the rest.
struct TaskMenu: View {
    let row: SidebarSections.JobRow
    let model: IslandModel
    let state: ChatState
    /// Left out on the task's own page.
    var onViewDetails: (() -> Void)?
    /// After its conversation is the one shown: open it.
    let onOpenChat: () -> Void
    let onRename: () -> Void

    private var job: Job { row.job }

    var body: some View {
        let manages = model.managesJobs(local: row.local)
        if let onViewDetails { Button("View details", action: onViewDetails) }
        if model.hasConversation(of: job.id, local: row.local) {
            Button("Open conversation") {
                model.showConversation(of: job.id, local: row.local)
                onOpenChat()
            }
        }
        if manages { Button("Rename", action: onRename) }
        if job.isActive {
            Button("Stop task") { model.stopChatJob(job.id, local: row.local) }
        } else if manages, !job.waitsForYou, model.feed.extras[job.id]?.archived == nil {
            Button("Archive task") { state.act { try await model.feed.archive(job.id) } }
        }
        if manages {
            Divider()
            Button("Delete task", role: .destructive) { state.deleting = row }
        }
    }

    /// Why obid would refuse to delete it now (its `409`), or nil: then Delete task's dialog says so
    /// instead of asking.
    nonisolated static func undeletable(_ job: Job) -> String? {
        if job.isActive { return "It's still running: stop it first." }
        if job.published != nil, !["MERGED", "CLOSED"].contains(job.pullRequestState ?? "OPEN") {
            return "Its pull request is open: merge or close it first, or archive the task."
        }
        return nil
    }

    /// What Delete task's dialog says goes (obid's `DELETE /v1/jobs/{id}`): never anything pushed,
    /// nor a branch obid didn't make or another task uses.
    nonisolated static func deleteLine(_ job: Job) -> String {
        let lost = max(0, (job.commits ?? 0) - (job.pushed ?? 0))
        var line = "Its worktree and its local oby/ branch go for good, unless another task uses the branch. What's on GitHub stays: its pushed branch and pull request."
        if lost == 1 { line += " 1 commit that isn't published is lost." }
        if lost > 1 { line += " \(lost) commits that aren't published are lost." }
        return line
    }
}

/// Renaming in place (Sangam's `sidebar-rename` and `crumb-rename`): the name in a field that takes
/// the keyboard as it shows; Return or clicking away keeps it, Esc leaves it as it was.
struct RenameField: View {
    let label: String
    let title: String
    var font = Tokens.font(Tokens.textBase)
    /// The longest name the runner takes (a job's 60 characters, a conversation's 100).
    var limit = 60
    /// The new name, or nil for Esc. Called once.
    let onDone: (String?) -> Void
    @State private var draft = ""
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $draft)
            .textFieldStyle(.plain).font(font).foregroundStyle(Tokens.ink)
            .focused($focused)
            // No box, as Sangam's: the name stays where it was, selected.
            .padding(.horizontal, 6).frame(height: 22).padding(.leading, -6)
            .onChange(of: draft) { _, typed in if typed.count > limit { draft = String(typed.prefix(limit)) } }
            .onSubmit { finish(draft) }
            .onExitCommand { finish(nil) }
            .onChange(of: focused) { _, now in if !now { finish(draft) } }
            .onAppear { draft = title; DispatchQueue.main.async { focused = true } }
    }

    private func finish(_ title: String?) {
        guard !done else { return }
        done = true
        onDone(title)
    }
}

extension ChatState {
    /// Runs Rename, Archive task or Delete task; why it didn't go through shows in the window's alert.
    func act(_ call: @escaping () async throws -> Void) {
        Task {
            do { try await call(); taskProblem = nil } catch { taskProblem = error.localizedDescription }
        }
    }

    /// Rename's field closed: a new name goes to obid; Esc, or an empty or unchanged one, nothing.
    func renamed(_ job: Job, to title: String?, feed: RunnerFeed) {
        renaming = nil
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != job.heading else { return }
        act { try await feed.rename(job.id, to: title) }
    }
}

extension View {
    /// The window's Delete task and Delete conversation dialogs (both ask first: neither can be
    /// undone) and the alert for a Rename, Archive or Delete that didn't go through.
    func taskDialogs(model: IslandModel, state: ChatState) -> some View {
        confirmationDialog(state.deleting.map { TaskMenu.undeletable($0.job) == nil ? "Delete “\($0.job.heading)”?" : "“\($0.job.heading)” can't be deleted yet" } ?? "",
                           isPresented: Binding(get: { state.deleting != nil }, set: { if !$0 { state.deleting = nil } }),
                           presenting: state.deleting) { row in
            if TaskMenu.undeletable(row.job) == nil {
                Button("Delete task", role: .destructive) { state.act { try await model.feed.delete(row.job.id) } }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { row in
            Text(TaskMenu.undeletable(row.job) ?? TaskMenu.deleteLine(row.job))
        }
        .confirmationDialog(state.deletingConversation.map { "Delete “\($0.title)”?" } ?? "",
                            isPresented: Binding(get: { state.deletingConversation != nil }, set: { if !$0 { state.deletingConversation = nil } }),
                            presenting: state.deletingConversation) { conversation in
            Button("Delete conversation", role: .destructive) { Task { await model.feed.conversations.delete(conversation.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(ConversationMenu.deleteLine)
        }
        .alert("That didn't go through", isPresented: Binding(get: { state.taskProblem != nil }, set: { if !$0 { state.taskProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.taskProblem ?? "")
        }
    }
}
