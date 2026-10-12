import SwiftUI

/// The window's right column, "Live": every agent working now, on this Mac and on the runner,
/// with its tool and account, its current step, how far along it is where that's known, and how
/// long it has run. Click one for its screen. Jobs waiting their turn aren't cards: "14 waiting"
/// under them opens the Waiting list, each saying what it waits for (#238).
struct LiveView: View {
    let model: IslandModel
    let onOpen: (_ job: String, _ local: Bool) -> Void
    @State private var showsWaiting = false

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }

    /// Queued and running jobs, newest first, with where each is.
    private var active: [(job: Job, local: Bool)] {
        (desk.active.map { ($0, true) } + feed.active.map { ($0, false) }).sorted { $0.0.created > $1.0.created }
    }

    /// The ones working (running, or getting ready to).
    private var live: [(job: Job, local: Bool)] { active.filter { $0.job.isWorking } }

    /// The ones queued behind something.
    private var waiting: [(job: Job, local: Bool)] { active.filter { $0.job.isWaiting } }

    var body: some View {
        let live = self.live
        let waiting = self.waiting
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(live.isEmpty ? "Nothing running" : "\(live.count) working").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 18).padding(.top, 46).padding(.bottom, 14)
            .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if live.isEmpty {
                        Text(waiting.isEmpty ? "Agents you dispatch show up here while they work." : "No agent is working right now.")
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
                    if let line = Summary.waitingLine(waiting.count) {
                        waitingList(waiting, line: line)
                    }
                }
            }
        }
        .background(Color(white: 0.09))
    }

    /// "14 waiting", which opens the Waiting list: each job's title and what it waits for.
    private func waitingList(_ waiting: [(job: Job, local: Bool)], line: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showsWaiting.toggle() } label: {
                HStack(spacing: 6) {
                    Text(line).font(.system(size: 13, weight: .medium))
                    Image(systemName: showsWaiting ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(0.6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(line)
            .accessibilityHint(showsWaiting ? "Hides the waiting jobs" : "Shows the waiting jobs")
            if showsWaiting {
                ForEach(waiting, id: \.job.id) { entry in
                    Button { onOpen(entry.job.id, entry.local) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.job.heading).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(entry.job.line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the job")
                }
            }
        }
        .padding(.horizontal, 18)
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
