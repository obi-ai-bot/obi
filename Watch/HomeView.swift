import SwiftUI

/// Oby, "1 needs you · 2 working", then the jobs that need you and the ones running.
struct HomeView: View {
    @Environment(Watch.self) private var watch
    /// The job screens open, so a notification can open its job.
    @State private var path: [String] = []
    @State private var talking = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
                ForEach(watch.shown) { job in
                    NavigationLink(value: job.id) { JobRow(job: job) }
                }
                if watch.shown.isEmpty {
                    Text(watch.loaded ? "Nothing needs you." : "Waiting for your iPhone…")
                        .font(.footnote).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Oby")
            .navigationDestination(for: String.self) { JobScreen(id: $0) }
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button { talking = true } label: { Label("Talk to Oby", systemImage: "mic.fill") }
                }
            }
            .sheet(isPresented: $talking) { TalkView() }
            .onChange(of: talking) {
                // Closed: the ask is dropped, unless it waits for the phone to come back in reach.
                if !talking, !isQueued { watch.cancel() }
            }
            .onChange(of: watch.opening, initial: true) {
                guard let id = watch.opening else { return }
                watch.opening = nil
                talking = false
                path = [id]
            }
        }
    }

    private var isQueued: Bool {
        if case .queued = watch.talk { return true }
        return false
    }

    /// Waving while something needs you, busy while agents work, calm otherwise.
    private var loop: ObyAnimation.Loop {
        if !watch.needing.isEmpty { return .needs }
        return watch.working.isEmpty ? .idle : .working
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            // Oby animated, rendered from Character/ (Watch/README.md). The frames leave room for
            // it to move, so the frame is a little larger than Oby itself.
            ObyAnimation(loop: loop)
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(watch.line).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                Text(watch.subline).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One job: its title, "Stage n of m", and how it is.
struct JobRow: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(job.heading).font(.headline).lineLimit(2)
            if let pipeline = job.pipeline {
                Text(pipeline.label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            let (text, color) = JobStatus.of(job)
            Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
        }
        .padding(.vertical, 2)
    }
}

/// The one word a job is in, and its colour, as the iPhone's status pill says it.
enum JobStatus {
    static func of(_ job: Job) -> (String, Color) {
        switch job.status {
        case .queued: ("Starting", .blue)
        case .running: ("Working", .blue)
        case .done where job.canPublish: ("Ready to publish", .orange)
        case .done where job.pullRequest?.state == "MERGED": ("Merged", .green)
        case .done where job.pullRequest?.state == "CLOSED": ("PR closed", .secondary)
        case .done where job.pullRequest?.reviewDecision == "CHANGES_REQUESTED": ("Changes requested", .orange)
        case .done where job.pullRequest?.reviewDecision == "APPROVED": ("Approved", .green)
        case .done where job.published != nil: ("In review", .blue)
        case .done: ("Done", .green)
        case .failed: ("Failed", .red)
        case .stopped: ("Stopped", .gray)
        case .interrupted: ("Interrupted", .gray)
        }
    }
}
