import SwiftUI

/// The window's right column, "Live": every agent working now, on this Mac and on the runner,
/// with its tool and account, its current step, how far along it is where that's known, and how
/// long it has run. Click one for its screen.
struct LiveView: View {
    let model: IslandModel
    let onOpen: (_ job: String, _ local: Bool) -> Void

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }

    /// Running and queued jobs, newest first, with where each is.
    private var live: [(job: Job, local: Bool)] {
        (desk.jobs.filter { model.lists($0) }.map { ($0, true) } + feed.jobs.filter { model.lists($0) }.map { ($0, false) }).sorted { $0.0.created > $1.0.created }
    }

    var body: some View {
        let live = self.live
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(model.working == 0 ? "Nothing running" : "\(model.working) working").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 18).padding(.top, 46).padding(.bottom, 14)
            .accessibilityAddTraits(.isHeader)
            ScrollView {
                if live.isEmpty {
                    Text("Jobs appear here when Oby starts work.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                } else {
                    // Every second: the elapsed time moves on.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LazyVStack(spacing: 12) {
                            ForEach(live, id: \.job.id) { entry in
                                JobChip(job: entry.job, account: Self.account(of: entry.job, local: entry.local, desk: desk, feed: feed),
                                        onOpen: { onOpen(entry.job.id, entry.local) },
                                        onStop: { model.stopChatJob(entry.job.id, local: entry.local) })
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
            }
        }
        .background(OBYStyle.window)
    }

    /// The account's name as this Mac or the runner knows it, else its id.
    static func account(of job: Job, local: Bool, desk: Desk, feed: RunnerFeed) -> String {
        let states = local ? desk.accounts.accounts : feed.accounts
        return states.first { $0.account.id == job.account }?.account.name ?? job.account
    }

    /// How far along a job is, 0 to 1, from its pipeline's stage and, within Work, its round; nil
    /// when the pipeline can't say (no stages).
    nonisolated static func progress(_ job: Job) -> Double? {
        let pipeline = job.pipeline
        guard pipeline.total > 0 else { return nil }
        var round = 0.0
        if pipeline.stages.first(where: { $0.state == .current })?.id == .work, job.maxRounds > 1 {
            round = Double(job.currentRound - 1) / Double(job.maxRounds)
        }
        return min(1, max(0, (Double(pipeline.number - 1) + round) / Double(pipeline.total)))
    }
}
