import Foundation
import Testing
@testable import Oby

/// Settings › Memory (#378, first part): obid's memories and suggestions read as it sends them,
/// Remember and Not this sent to the suggestion's own path, and a runner with no memory (404)
/// isn't an error.
@MainActor
struct MemorySettingsTests {
    static let listed = #"""
    {"memories": [
      {"id": "m1a2b3c4d", "scope": "user", "repo": null, "kind": "preference", "source": "found", "title": "Tests with every fix",
       "text": "Write tests with every fix.", "from": "You said it in 2 conversations", "created": "2026-10-20T10:00:00Z",
       "updated": "2026-10-20T10:00:00Z", "used": 0},
      {"id": "m5e6f7a8b", "scope": "project", "repo": "obi-ai-bot/obi", "kind": "feedback", "source": "found", "title": "Small PRs",
       "text": "Keep pull requests small.", "from": "Reviewers asked for it on #12 and #40", "created": "2026-10-20T10:01:00Z",
       "updated": "2026-10-20T10:01:00Z", "used": 0}
    ],
    "suggestions": [
      {"id": "s0000000a", "scope": "project", "repo": "obi-ai-bot/obi", "kind": "feedback", "title": "Rebase first", "text": "Rebase on dev first.",
       "from": "You said it in 1 conversation; reviewers asked for it on #12",
       "sources": [{"quote": "rebase on dev first", "place": "A review on obi-ai-bot/obi#12", "link": "https://github.com/obi-ai-bot/obi/pull/12"},
                   {"quote": "please rebase on dev first", "place": "You, in “Release”", "link": null}]}
    ],
    "question": "Can I remember that?"}
    """#

    @Test func readsTheListAndAnswersASuggestion() async throws {
        let obid = RunnerStub { request in
            switch (request.method, request.path) {
            case ("GET", "/v1/memory"): (200, Self.listed)
            case ("POST", "/v1/memory/suggestions/s0000000a/remember"):
                (201, #"{"id": "m9b8c7d6e", "scope": "project", "repo": "obi-ai-bot/obi", "kind": "feedback", "source": "found", "title": "Rebase first", "text": "Rebase on dev first.", "from": "", "created": "2026-10-20T10:02:00Z", "updated": "2026-10-20T10:02:00Z", "used": 0}"#)
            case ("POST", "/v1/memory/suggestions/s0000000a/dismiss"): (204, "")
            default: (404, "")
            }
        }
        let list = try #require(try await obid.runner.memory())
        #expect(list.memories.map(\.title) == ["Tests with every fix", "Small PRs"])
        #expect(list.suggestions.first?.sources.first?.link == URL(string: "https://github.com/obi-ai-bot/obi/pull/12"))
        #expect(list.suggestions.first?.sources.last?.link == nil)
        let view = MemorySettingsView(runner: nil)
        #expect(view.groups(list.memories).map(\.title) == ["About you", "obi-ai-bot/obi"])

        let saved = try await obid.runner.remember("s0000000a")
        #expect(saved.repo == "obi-ai-bot/obi")
        try await obid.runner.dismissSuggestion("s0000000a")
        #expect(obid.requests.map(\.path).suffix(2) == ["/v1/memory/suggestions/s0000000a/remember", "/v1/memory/suggestions/s0000000a/dismiss"])

        let swift = RunnerStub { _ in (404, #"{"error": "Not found."}"#) }
        #expect(try await swift.runner.memory() == nil)
    }

    @Test func saysWhatAFindRead() {
        let found = RunnerMemoryFound(suggestions: [], read: .init(conversations: 1, pullRequests: 12), problems: [])
        #expect(MemorySettingsView.looked(found) == "Read 1 conversation and 12 pull requests: nothing came up more than once.")
    }
}
