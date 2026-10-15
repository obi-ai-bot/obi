import Foundation
import Testing
@testable import Oby

struct ResearchReportTests {
    @Test func reportViewRendersHeadingsAndLinks() throws {
        let parsed = ReportView.parsedMarkdown("# Answer\n\nA [source](https://github.com/acme/repo/blob/abc/README.md#L4) supports this.")
        let text = String(parsed.characters)
        #expect(text.contains("Answer") && text.contains("A source supports this."))
        let target = try #require(URL(string: "https://github.com/acme/repo/blob/abc/README.md#L4"))
        #expect(parsed.runs.contains { $0.link == target })
    }

    @Test func proposalCardConfirmsBeforeFiling() {
        let proposal = ResearchProposal(index: 0, repo: "acme/arch", title: "Add a migration guide", body: "## What", labels: [], filed: nil, filedAt: nil)
        #expect(ReportView.confirmationMessage(for: proposal) == "Create in acme/arch: Add a migration guide")
    }
}
