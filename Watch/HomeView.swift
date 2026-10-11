import SwiftUI

/// Oby, edge to edge, and the microphone. Oby's pose is the status: waving while something needs
/// you (with the count on its corner), busy while agents work, calm otherwise. Tapping Oby opens
/// the jobs; holding the microphone talks to it.
struct HomeView: View {
    @Environment(Watch.self) private var watch
    /// The screens open, so a notification can open its job.
    @State private var path: [Screen] = []
    /// The talk's sheet is up: sending, thinking, the plan, a question or a reply.
    @State private var talking = false

    enum Screen: Hashable {
        case jobs
        case job(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                Button { path.append(.jobs) } label: {
                    // The whole screen, whatever its shape: Oby fills it and the overflow is cut.
                    Color.clear
                        .overlay {
                            ObyAnimation(loop: loop, contentMode: .fill)
                                .overlay { GeometryReader { frame in badge.position(x: frame.size.width * Self.corner.x, y: frame.size.height * Self.corner.y) } }
                        }
                        .clipped()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Oby")
                .accessibilityValue(watch.loaded ? watch.line : "")
                .accessibilityHint("Shows the jobs")
                .ignoresSafeArea()
                TalkButton(talking: $talking)
            }
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .jobs: JobListScreen()
                case .job(let id): JobScreen(id: id)
                }
            }
            .sheet(isPresented: $talking) { TalkView() }
            .onChange(of: watch.talk) {
                // The plan (or what stands for it) comes up by itself, and goes once it's dispatched.
                switch watch.talk {
                case .none: talking = false
                case .recording: break
                default: talking = true
                }
            }
            .onChange(of: talking) {
                // Closed: the ask is dropped, unless it waits for the phone to come back in reach.
                if !talking, !isQueued { watch.cancel() }
            }
            .onChange(of: watch.opening, initial: true) {
                guard let id = watch.opening else { return }
                watch.opening = nil
                // Dropped before the microphone leaves the screen, so a recording under way isn't
                // sent on the release that follows. A request waiting for the phone stays.
                if !isQueued { watch.cancel() }
                talking = false
                path = [.job(id)]
            }
        }
    }

    private var isQueued: Bool {
        if case .queued = watch.talk { return true }
        return false
    }

    /// Oby's top-right corner in the needs frames, as a fraction of the frame: Oby sits low in
    /// them (rows 68 to 155 of 160, the busy dots of `working` above), at columns 27 to 133.
    private static let corner = CGPoint(x: 0.82, y: 0.44)

    /// The count of what needs you, on Oby's corner. VoiceOver reads it in Oby's value.
    @ViewBuilder private var badge: some View {
        if !watch.needing.isEmpty {
            Text("\(watch.needing.count)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 20, minHeight: 20)
                .background(.orange, in: Capsule())
                .accessibilityHidden(true)
        }
    }

    /// Waving while something needs you, busy while agents work, calm otherwise (and before the
    /// iPhone has sent anything).
    private var loop: ObyAnimation.Loop {
        if !watch.needing.isEmpty { return .needs }
        return watch.working.isEmpty ? .idle : .working
    }
}

/// The jobs that need you, then the ones running.
struct JobListScreen: View {
    @Environment(Watch.self) private var watch

    var body: some View {
        List {
            ForEach(watch.shown) { job in
                NavigationLink(value: HomeView.Screen.job(job.id)) { JobRow(job: job) }
            }
            if watch.shown.isEmpty {
                Text(watch.loaded ? "Nothing needs you." : "Waiting for your iPhone…")
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Jobs")
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
