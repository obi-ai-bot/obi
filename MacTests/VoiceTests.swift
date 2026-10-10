import Foundation
import Testing
@testable import Oby

struct VoiceTests {
    @Test func contextHasEachRepositoryAsWrittenAndAsSaid() {
        let context = Voice.context(repos: ["deskree-inc/tetrix-front-end", "deskree-inc/oby"])
        #expect(context.contains("tetrix-front-end"))
        #expect(context.contains("tetrix front end"))
        #expect(context.contains("Claude Code"))
        // "oby" and "Oby" are one name to the transcriber.
        #expect(context.filter { $0.lowercased() == "oby" }.count == 1)
    }

    @Test func contextStaysShort() {
        let repos = (0..<300).map { "someone/repo-\($0)" }
        #expect(Voice.context(repos: repos).count == 100)
    }

    @Test func theFirstRepositoriesSurviveTheCut() {
        let repos = ["deskree-inc/tetrix-front-end"] + (0..<300).map { "someone/repo-\($0)" }
        #expect(Voice.context(repos: repos).contains("tetrix front end"))
    }
}
