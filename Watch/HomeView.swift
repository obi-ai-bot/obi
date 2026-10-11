import SwiftUI

/// Home stays inside the navigation safe area (including the watch's clock). The mic has its
/// own row, so neither Oby's frames nor the needs-you dot can cover it.
struct HomeView: View {
    @Environment(Watch.self) private var watch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [Screen] = []

    enum Screen: Hashable {
        case jobs
        case job(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                // GeometryReader's proposal already excludes the navigation safe areas. The
                // frames have transparent margins: ~2/3 of their width is Oby's body.
                let width = geometry.size.width
                let height = geometry.size.height
                let mic = min(52, max(44, height * 0.25))
                let quiet = watch.talk == .none
                // Idle/needs frames have 58+ empty rows above Oby; trim 32% of the
                // square there. Working keeps its dots. Both give the body ~half the width.
                let trim: CGFloat = loop == .working ? 0 : 0.32
                let fraction: CGFloat = loop == .working ? (quiet ? 0.64 : 0.38) : (quiet ? 0.76 : 0.44)
                let space = max(0, min(height * (quiet ? 0.68 : 0.30), height - mic - 12 - (quiet ? 0 : 44)))
                let side = min(width * fraction, space / (1 - trim))
                VStack(spacing: 6) {
                    Button { watch.cancel(); path.append(.jobs) } label: {
                        ObyAnimation(loop: loop)
                            .frame(width: side, height: side)
                            .offset(y: -side * trim / 2)
                            .frame(width: side, height: side * (1 - trim))
                            .clipped()
                            .overlay(alignment: .topLeading) {
                                if !watch.needing.isEmpty {
                                    Circle().fill(.orange).frame(width: 10, height: 10)
                                        .position(x: side * 0.82, y: side * (0.44 - trim))
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Oby")
                    .accessibilityValue(watch.loaded ? watch.line : "")
                    .accessibilityHint("Shows the jobs")
                    if watch.talk != .none {
                        TalkView().frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                    } else {
                        Spacer(minLength: 0)
                    }
                    TalkButton(size: mic)
                }
                .frame(width: width, height: height)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: watch.talk == .none)
            }
            .padding(.vertical, 4)
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .jobs: JobListScreen()
                case .job(let id): JobScreen(id: id)
                }
            }
            .onChange(of: watch.opening, initial: true) {
                guard let id = watch.opening else { return }
                watch.opening = nil
                watch.cancel()
                path = [.job(id)]
            }
        }
    }

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
