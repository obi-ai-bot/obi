import SwiftUI

#if !os(watchOS)
/// A job's Tetrix section (not in Sangam's design: his task page has no Tetrix part): what the agent
/// asked it, the session it saved, and where the graph fell short. Plain text throughout.
struct TetrixReportView: View {
    let report: TetrixJobReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            line(report.callsLine)
            if report.context == true { line("Tetrix's context was ready before it started") }
            line(report.saved.isEmpty ? "No session saved" : "Session saved: " + report.saved.joined(separator: ", "))
            if let gaps = report.gaps, !gaps.isEmpty {
                Text("Where the graph fell short").font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.label)
                    .padding(.top, 10).accessibilityAddTraits(.isHeader)
                ForEach(Array(gaps.lines.enumerated()), id: \.offset) { _, gap in
                    Text(verbatim: "• " + gap).font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let sent = gaps.sentLine { line(sent).padding(.top, 2) }
            }
        }
    }

    private func line(_ text: String) -> some View {
        Text(verbatim: text).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}

#endif
