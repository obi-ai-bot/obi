import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Read-only research report with explicit, confirmed issue filing actions.
struct ReportView: View {
    let report: ResearchDocument
    var onFile: ((Int, Bool) async throws -> FileProposalResult)? = nil
    @Environment(\.openURL) private var openURL
    @State private var confirming: ResearchProposal?
    @State private var confirmingStart = false
    @State private var busy: Int?
    @State private var problem: String?
    @State private var filed: [Int: String] = [:]

    static func parsedMarkdown(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown,
                               options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full))) ?? AttributedString(markdown)
    }
    private var markdown: AttributedString { Self.parsedMarkdown(report.markdown) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    #if !os(watchOS)
                    Button(action: copy) { Label("Copy Markdown", systemImage: "doc.on.doc") }
                    #endif
                    Spacer()
                    Text(String(report.commit.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                #if os(watchOS)
                Text(markdown).frame(maxWidth: .infinity, alignment: .leading)
                #else
                Text(markdown).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                #endif
                if !report.proposals.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Proposed issues").font(.title3.weight(.semibold))
                        ForEach(report.proposals) { proposal in proposalCard(proposal) }
                    }
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            Button(confirmingStart ? "File and start" : "File this issue") { Task { await file(start: confirmingStart) } }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            if let proposal = confirming { Text(Self.confirmationMessage(for: proposal)) }
        }
    }

    private var confirmationTitle: String { confirming.map { "File ‘\($0.title)’?" } ?? "File proposed issue?" }
    static func confirmationMessage(for proposal: ResearchProposal) -> String { "Create in \(proposal.repo): \(proposal.title)" }

    @ViewBuilder private func proposalCard(_ proposal: ResearchProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(proposal.title).font(.headline)
            Text(proposal.repo).font(.caption).foregroundStyle(.secondary)
            if let url = filed[proposal.index] ?? proposal.filed, let link = URL(string: url) {
                Button("Filed issue · Open on GitHub") { openURL(link) }.font(.subheadline)
                } else if onFile != nil {
                HStack {
                    Button("File this issue") { confirm(proposal, start: false) }.disabled(busy != nil)
                    Button("File and start") { confirm(proposal, start: true) }.disabled(busy != nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func file(start: Bool) async {
        guard let proposal = confirming, let onFile else { return }
        confirming = nil
        busy = proposal.index
        defer { busy = nil }
        do { filed[proposal.index] = try await onFile(proposal.index, start).issue }
        catch { problem = error.localizedDescription }
    }

    private func confirm(_ proposal: ResearchProposal, start: Bool) {
        confirmingStart = start
        confirming = proposal
    }

    private func copy() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.markdown, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = report.markdown
        #endif
    }
}
