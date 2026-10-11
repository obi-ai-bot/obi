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
        (desk.active.map { ($0, true) } + feed.active.map { ($0, false) }).sorted { $0.0.created > $1.0.created }
    }

    var body: some View {
        let live = self.live
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(live.isEmpty ? "Nothing running" : "\(live.count) working").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 18).padding(.top, 46).padding(.bottom, 14)
            .accessibilityAddTraits(.isHeader)
            ScrollView {
                if live.isEmpty {
                    Text("Agents you dispatch show up here while they work.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                } else {
                    // Every second: the elapsed time moves on.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LazyVStack(spacing: 12) {
                            ForEach(live, id: \.job.id) { entry in
                                LiveCard(job: entry.job, account: Self.account(of: entry.job, local: entry.local, desk: desk, feed: feed),
                                         now: context.date, onOpen: { onOpen(entry.job.id, entry.local) })
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
            }
        }
        .background(Color(white: 0.09))
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

/// One working agent: tool · account and the status pill, the job's title, its step, the progress
/// bar where known, and "7m 14s · tetrix-front-end".
private struct LiveCard: View {
    let job: Job
    let account: String
    let now: Date
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentMark(agent: job.agent).font(.system(size: 14, weight: .semibold)).frame(width: 18)
                Text("\(job.agentName) · \(account)").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Spacer(minLength: 6)
                StatusBadge(job: job)
            }
            Text(job.heading).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            if !job.line.isEmpty {
                Text(job.line).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            }
            if let progress = LiveView.progress(job) {
                ProgressView(value: progress).progressViewStyle(.linear).tint(.white.opacity(0.7))
                    .accessibilityLabel("Progress").accessibilityValue("\(Int((progress * 100).rounded())) percent")
            }
            Text(footer).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the job")
    }

    /// "7m 14s · tetrix-front-end", or the repository alone before the agent started.
    private var footer: String {
        guard let started = job.started else { return job.repoName }
        return "\(Elapsed.text(Int(now.timeIntervalSince(started)))) · \(job.repoName)"
    }
}
