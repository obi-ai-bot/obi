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
}
