import SwiftUI

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
                    StatusPill(job: job)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if hovering {
                if job.isActive, let onStop { Button("Stop", action: onStop).buttonStyle(.plain) }
                else if let pr = job.pr, let url = URL(string: "https://github.com/\(job.repo)/pull/\(pr)") {
                    Button("Open PR") { openURL(url) }.buttonStyle(.plain)
                }
            }
        }
        .padding(OBYStyle.Space.md)
        .background(OBYStyle.surface, in: RoundedRectangle(cornerRadius: OBYStyle.chip))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open job", action: onOpen)
            if job.isActive, let onStop { Button("Stop", action: onStop) }
        }
    }
}
