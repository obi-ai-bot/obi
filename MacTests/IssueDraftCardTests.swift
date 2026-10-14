import Foundation
import Testing
@testable import Oby

@Suite struct IssueDraftCardTests {
    private func draft(_ state: RunnerIssueDraft.State, issue: Int? = nil) -> RunnerIssueDraft {
        RunnerIssueDraft(id: "a1b2c3d4", version: 2,
                         fields: .init(repo: "deskree-inc/oby", title: "Retry uploads", what: "What", why: "Why", how: "How", acceptance: ["Test"], files: [], labels: []),
                         state: state, turn: "turn", created: .now, updated: .now, issue: issue,
                         url: nil, error: nil, outgoing: nil, previous: nil, preview: "## What")
    }

    @Test func createIssueIsFirstAndRecommended() {
        let options = IssueDraftCard.options(for: draft(.draft))
        #expect(options.first?.label == "Create issue")
        #expect(options.first?.recommended == true)
    }

    @Test func createdIssueShowsItsNumberWithoutOptions() {
        let issue = draft(.created, issue: 412)
        #expect(IssueDraftCard.title(for: issue).contains("#412"))
        #expect(IssueDraftCard.options(for: issue).isEmpty)
    }

    @Test func editingPreviewUpdatesBodyAndKeepsUnshownFields() {
        let fields = RunnerIssueDraft.Fields(repo: "deskree-inc/oby", title: "Retry uploads", what: "Retry the upload.",
                                            why: "Avoid data loss.", how: "Try three times.",
                                            acceptance: ["Offline retries are bounded"], files: ["Engine/Upload.swift"], labels: ["feature"])
        let preview = IssueDraft(id: "a1b2c3d4", fields: IssueDraft.Fields(repo: fields.repo, title: fields.title,
                                                                            what: fields.what, why: fields.why, how: fields.how,
                                                                            acceptance: fields.acceptance, files: fields.files, labels: fields.labels), turn: "turn").body()
        let edited = preview.replacingOccurrences(of: "Retry the upload.", with: "Retry each upload safely.")
            .replacingOccurrences(of: "Offline retries are bounded", with: "Offline retries stop after three attempts")
        let result = fields.editing(edited)
        #expect(result?.what == "Retry each upload safely.")
        #expect(result?.acceptance == ["Offline retries stop after three attempts"])
        #expect(result?.title == fields.title)
        #expect(result?.repo == fields.repo)
        #expect(result?.labels == fields.labels)
        #expect(result?.files == fields.files)
    }

    @Test func changedLineNamesOnlyFieldsThatChanged() {
        var value = draft(.draft)
        value.previous = value.fields
        value.fields.title = "Retry uploads safely"
        value.fields.acceptance = ["Offline retries stop after three attempts"]
        #expect(IssueDraftCard.changedLine(for: value) == "Changed: title, acceptance")
    }
}
