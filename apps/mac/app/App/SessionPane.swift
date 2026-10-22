import SwiftUI

/// A runner job's live session (Sangam's SessionView, #786; #785), over its page with Session in
/// the trail: read from obid page by page, then live from the feed's `transcript` events, and at
/// its foot the box to tell the agent something. Back (or Esc) returns to the task's page.
struct SessionPane: View {
    let model: IslandModel
    let id: String
    var onBack: (() -> Void)? = nil
    @State private var session: LiveSession?
    @State private var note = ""
    @State private var typing = false
    @State private var sending = false
    @State private var problem: String?

    private var feed: RunnerFeed { model.feed }
    private var job: Job? { feed.jobs.first { $0.id == id } }

    var body: some View {
        VStack(spacing: 0) {
            if let session, let job {
                SessionView(session: session, agent: job.agent, meta: meta(job), live: job.isActive)
                    .task(id: job.isActive) { await session.follow(live: job.isActive) }
                if let problem {
                    Text(problem).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.danger)
                        .frame(maxWidth: Tokens.column, alignment: .leading).padding(.horizontal, Tokens.gutter + 12).padding(.top, 8)
                }
                MessageBox(text: $note, focused: $typing, tray: model.tray, placeholder: "Tell \(job.agentName)…", label: "Tell Oby about \(job.heading)",
                           maximumHeight: 240, onSend: { tell(job) }, onScreenshot: {}, onStop: { false }, onEscape: onBack, attachments: false)
                    .keepsDraft($note, as: Drafts.task(job.id))
                    .disabled(sending)
                    .frame(maxWidth: Tokens.column).padding(.horizontal, Tokens.gutter).padding(.top, 8).padding(.bottom, 20)
            } else {
                CardBones(rows: 2).frame(maxWidth: Tokens.column).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, Tokens.gutter).padding(.top, 24)
            }
        }
        .onAppear {
            let session = self.session ?? LiveSession(job: id, load: { [feed, id] after in try await feed.about(id) { try await $0.transcript(id, after: after) } },
                                                      loadDetail: { [feed, id] n in try await feed.about(id) { try await $0.transcriptDetail(id, n) } })
            self.session = session
            feed.liveSession = session
        }
        .onDisappear { if feed.liveSession === session { feed.liveSession = nil } }
    }

    /// "Claude Code · Opus 5.5 · Personal".
    private func meta(_ job: Job) -> String {
        let account = feed.accounts.first { $0.account.id == job.account }?.account.name ?? job.account
        return [job.agentName, job.model.map(ModelChoice.name), account].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What you tell it goes the way the task's page sends it (`TaskActions.message`).
    private func tell(_ job: Job) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(text.count), !sending else { return }
        let message = TaskActions.of(job, local: false, model: model).message
        sending = true
        Task {
            defer { sending = false }
            do {
                try await message(text)
                note = ""
                problem = nil
            } catch { problem = error.localizedDescription }
        }
    }
}
