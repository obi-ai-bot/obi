import SwiftUI

extension TurnStep.State {
    /// What VoiceOver says for the step's mark.
    var spoken: String {
        switch self {
        case .running: "Working"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}

/// The steps of Oby's turn, a compact list under the user's message, like Claude Code's tool calls
/// (#304): a spinner while a step runs, a check when it's done, a cross when it failed. The
/// iPhone's and the Mac's chats show it at the footnote size; the Watch's, shorter and smaller.
struct StepList: View {
    let steps: [TurnStep]
    /// The Watch: one line a step, in the caption size.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    mark(step.state)
                    Text(step.text)
                        .font(compact ? .caption2 : .footnote)
                        .foregroundStyle(step.state == .failed ? Color.red : Color.secondary)
                        .lineLimit(compact ? 1 : 2)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(step.text), \(step.state.spoken)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func mark(_ state: TurnStep.State) -> some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .done:
            Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.green).frame(width: 12)
        case .failed:
            Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.red).frame(width: 12)
        }
    }
}
