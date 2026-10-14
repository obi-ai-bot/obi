import SwiftUI

#if !os(watchOS)
/// A specialist memo in chat. It has no branch or publish controls because it never creates a job.
struct DelegationCard: View {
    let specialist: Specialist
    var onStop: () -> Void = {}
    @State private var expanded = false

    private var running: Bool { specialist.status == "running" || specialist.status == "queued" }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: glyph).frame(width: 20).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(specialist.goal).font(.subheadline.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(specialist.role.capitalized)
                        Text("·")
                        Text(specialist.status.capitalized)
                        Text("·")
                        Text(elapsed)
                    }.font(.caption).foregroundStyle(.secondary)
                    if !specialist.step.isEmpty && running { Text(specialist.step).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                if running { Button("Stop", action: onStop).buttonStyle(.bordered).controlSize(.small) }
            }
            if let result = specialist.result {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.summary).font(.callout).textSelection(.enabled)
                        ForEach(Array(result.findings.enumerated()), id: \.offset) { _, finding in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(finding.claim).font(.callout.weight(.medium))
                                ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, evidence in
                                    if let link = Self.httpsLink(evidence.link) {
                                        Link("Evidence · \(evidence.quote)", destination: link).font(.caption).lineLimit(3)
                                    } else {
                                        Text("Evidence · \(evidence.quote)").font(.caption).lineLimit(3)
                                    }
                                }
                            }
                        }
                        ForEach(result.openQuestions, id: \.self) { Text("Open question: \($0)").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.top, 7)
                } label: { Text("Findings").font(.caption.weight(.semibold)) }
            } else if let error = specialist.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(specialist.role) specialist, \(specialist.status): \(specialist.goal)")
    }

    private var glyph: String { specialist.role == "reviewer" ? "checkmark.shield" : specialist.role == "verifier" ? "checkmark.seal" : "magnifyingglass" }
    private static func httpsLink(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }
    private var elapsed: String {
        let seconds = Int((specialist.finished ?? .now).timeIntervalSince(specialist.started ?? specialist.created))
        return seconds < 60 ? "\(max(0, seconds))s" : "\(seconds / 60)m"
    }
}
#endif
