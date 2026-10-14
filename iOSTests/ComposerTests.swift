import Foundation
import Testing
@testable import Oby

/// The composer's dictation (#19, iOS/Composer.swift): words heard go after what the field holds.
@MainActor
struct ComposerTests {
    @Test func dictatedWordsJoinTheDraft() {
        #expect(Composer.draft("", "review PR 12") == "review PR 12")
        #expect(Composer.draft("Review", "PR 12") == "Review PR 12")
        #expect(Composer.draft("Review ", "PR 12") == "Review PR 12")
        #expect(Composer.draft("Review\n", "PR 12") == "Review\nPR 12")
    }

    @Test func photoPickerAddsChipsUpToTen() {
        #expect(Composer.maxAttachmentCount == 10)
        #expect(Composer.maxAttachmentBytes == 25 * 1024 * 1024)
        #expect(Composer.maxMessageBytes == 50 * 1024 * 1024)
    }

    @Test func sendWaitsForUploads() async throws {
        let draft = PhoneAttachmentDraft(name: "photo.jpg", data: Data([1, 2, 3]), uploadedID: nil)
        var started = false
        var sent = false
        var uploaded: CheckedContinuation<String, Error>?
        let sending = Task { @MainActor in
            let ids = try await Composer.uploadAttachmentIDs([draft], upload: { _ in
                started = true
                return try await withCheckedThrowingContinuation { uploaded = $0 }
            })
            sent = true
            return ids
        }
        while !started { await Task.yield() }
        #expect(!sent)
        uploaded?.resume(returning: "0123456789abcdef")
        #expect(try await sending.value == ["0123456789abcdef"])
        #expect(sent)
    }

    @Test func uploadKeysDraftsByStableIDNotIndex() async throws {
        let first = PhoneAttachmentDraft(name: "a.jpg", data: Data([1]), uploadedID: nil)
        let second = PhoneAttachmentDraft(name: "b.jpg", data: Data([2]), uploadedID: nil)
        var drafts = [first, second]
        var gate: CheckedContinuation<String, Error>?
        let uploading = Task { @MainActor in
            try await Composer.uploadAttachmentIDs(drafts, upload: { item in
                if item.id == first.id {
                    return try await withCheckedThrowingContinuation { gate = $0 }
                }
                return "bbbbbbbbbbbbbbbb"
            }, uploaded: { draftID, id in
                if let index = drafts.firstIndex(where: { $0.id == draftID }) {
                    drafts[index].uploadedID = id
                }
            })
        }
        while gate == nil { await Task.yield() }
        // Remove the first draft while its upload is in flight: the second chip must still get
        // its own id, not the first upload's (an index write would assign to the wrong draft).
        drafts.removeAll { $0.id == first.id }
        gate?.resume(returning: "aaaaaaaaaaaaaaaa")
        let ids = try await uploading.value
        #expect(ids == ["aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"])
        #expect(drafts.count == 1 && drafts[0].id == second.id && drafts[0].uploadedID == "bbbbbbbbbbbbbbbb")
    }
}
