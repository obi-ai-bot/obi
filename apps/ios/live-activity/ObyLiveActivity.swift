import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ObyWidgets: WidgetBundle {
    var body: some Widget { ObyLiveActivity() }
}

/// Oby on the Lock Screen and in the Dynamic Island while agents work.
struct ObyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ObyActivity.self) { context in
            LockScreen(state: context.state, stale: context.isStale)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Face(width: 46, happy: state.status == "done")
                        .frame(maxHeight: .infinity)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Pill(state: state)
                        if state.working > 0 { Clock(started: state.started) }
                    }
                    .frame(maxHeight: .infinity)
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.line).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                        if state.working > 1 {
                            Text("\(state.working) agents are working").font(.caption).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Face(width: 22, happy: state.status == "done")
            } compactTrailing: {
                if state.working > 1 {
                    Text("\(state.working)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(state.color)
                } else {
                    Clock(started: state.started).foregroundStyle(state.color).frame(maxWidth: 44)
                }
            } minimal: {
                Face(width: 20, happy: state.status == "done")
            }
            .keylineTint(state.color)
        }
    }
}

private struct LockScreen: View {
    let state: ObyActivity.ContentState
    let stale: Bool

    var body: some View {
        HStack(spacing: 14) {
            Face(width: 52, happy: state.status == "done")
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title).font(.headline).lineLimit(1)
                Text(state.line).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                if stale, state.working > 0 {
                    Text("Open Oby for the latest").font(.caption).foregroundStyle(.white.opacity(0.45))
                } else if state.working > 1 {
                    Text("\(state.working) agents are working").font(.caption).foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Pill(state: state)
                if state.working > 0 { Clock(started: state.started) }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

/// How long the job has been at it; the system ticks it, so it needs no updates.
private struct Clock: View {
    let started: Date

    var body: some View {
        Text(timerInterval: started...Date.distantFuture, countsDown: false)
            .font(.caption.weight(.semibold).monospacedDigit())
            .multilineTextAlignment(.trailing)
            // A timer text takes all the width it's offered; this leaves the title and step theirs.
            .frame(maxWidth: 64, alignment: .trailing)
    }
}

private struct Pill: View {
    let state: ObyActivity.ContentState

    var body: some View {
        Text(state.label).font(.caption.weight(.semibold)).foregroundStyle(state.color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(state.color.opacity(0.18), in: Capsule())
    }
}

/// Sangam's Oby, drawn: the soft block and two eyes, which close happily when a job is done.
/// The web character can't run in a widget.
private struct Face: View {
    let width: CGFloat
    var happy = false

    var body: some View {
        let height = width / 1.26
        let eye = CGSize(width: width * 0.145, height: height * 0.31)
        RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
            .fill(Color(red: 0.945, green: 0.945, blue: 0.933))
            .frame(width: width, height: height)
            .overlay {
                HStack(spacing: width * 0.275) {
                    ForEach(0..<2, id: \.self) { _ in
                        if happy {
                            Circle().trim(from: 0.5, to: 1)
                                .stroke(.black, style: StrokeStyle(lineWidth: eye.width * 0.6, lineCap: .round))
                                .frame(width: eye.width * 1.6, height: eye.width * 1.6)
                                .offset(y: eye.width * 0.4)
                                .frame(width: eye.width, height: eye.height)
                        } else {
                            Capsule().fill(.black)
                                .frame(width: eye.width, height: eye.height)
                                .overlay(alignment: .top) {
                                    Circle().fill(.white).frame(width: eye.width * 0.38)
                                        .offset(x: eye.width * 0.12, y: eye.height * 0.14)
                                }
                        }
                    }
                }
                .offset(y: -height * 0.037)
            }
            .accessibilityLabel("Oby")
    }
}

private extension ObyActivity.ContentState {
    var label: String {
        switch status {
        case "queued": "Starting"
        case "waiting": "Waiting"
        case "running": "Working"
        case "done": "Done"
        case "failed": "Failed"
        case "stopped": "Stopped"
        default: "Interrupted"
        }
    }

    var color: Color {
        switch status {
        case "queued", "running": .blue
        case "done": .green
        case "failed": .red
        default: .gray
        }
    }
}
