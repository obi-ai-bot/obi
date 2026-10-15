import Testing
@testable import Oby

/// The composer's dictation (#19, apps/ios/app/Composer.swift): words heard go after what the field holds.
@MainActor
struct ComposerTests {
    @Test func dictatedWordsJoinTheDraft() {
        #expect(Composer.draft("", "review PR 12") == "review PR 12")
        #expect(Composer.draft("Review", "PR 12") == "Review PR 12")
        #expect(Composer.draft("Review ", "PR 12") == "Review PR 12")
        #expect(Composer.draft("Review\n", "PR 12") == "Review\nPR 12")
    }
}
