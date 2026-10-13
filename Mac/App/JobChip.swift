import SwiftUI

struct StopButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovering ? OBYStyle.primary : OBYStyle.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(hovering ? OBYStyle.primary : OBYStyle.secondary, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Stop")
        .accessibilityLabel("Stop job")
        .onHover { hovering = $0 }
    }
}

/// One compact job component in the transcript, Live and notch.
struct JobChip: View {
    let job: Job
    var account = ""
    let onOpen: () -> Void
    var onStop: (() -> Void)? = nil
    @State private var hovering = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: OBYStyle.Space.md) {
            Button(action: onOpen) {
                HStack(spacing: OBYStyle.Space.md) {
                    AgentMark(agent: job.agent).font(OBYStyle.body.weight(.semibold)).frame(width: 22)
                    VStack(alignment: .leading, spacing: OBYStyle.Space.xs) {
                        Text(job.heading).font(OBYStyle.body.weight(.semibold)).lineLimit(1)
                        Text([account, job.line].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(OBYStyle.small).foregroundStyle(OBYStyle.secondary).lineLimit(1)
                    }
                    Spacer(minLength: OBYStyle.Space.xs)
                    StatusPill(badge: job.badge)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hovering {
                if job.isActive, let onStop { StopButton(action: onStop) }
                else if let pr = job.pr, let url = URL(string: "https://github.com/\(job.repo)/pull/\(pr)") {
                    Button("Open PR") { openURL(url) }.buttonStyle(.plain)
                }
            }
        }
        .padding(OBYStyle.Space.md)
        .background(hovering ? OBYStyle.assistantBubble : OBYStyle.surface, in: RoundedRectangle(cornerRadius: OBYStyle.chip))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open job", action: onOpen)
            if job.isActive, let onStop { Button("Stop", action: onStop) }
        }
    }
}
