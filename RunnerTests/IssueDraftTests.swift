import Foundation
import Hummingbird
import Testing
@testable import ObyEngine
@testable import oby_runner

@Suite struct IssueDraftTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "issue-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fields() -> IssueDraft.Fields {
        .init(repo: "deskree-inc/oby", title: "Retry uploads", what: "Retry the upload.", why: "Avoid losing work for @octocat.", how: "Try three times.", acceptance: ["Offline retries are bounded"], files: ["Engine/Upload.swift"], labels: [])
    }

    @Test func bodyIsStructuredAndMentionsCannotNotify() {
        let draft = IssueDraft(id: "a1b2c3d4", fields: fields(), turn: "turn")
        let body = draft.body()
        #expect(body.contains("## What"))
        #expect(body.contains("## Why"))
        #expect(body.contains("## How"))
        #expect(body.contains("### Acceptance tests"))
        #expect(body.contains("<!-- oby-draft: a1b2c3d4 -->"))
        #expect(body.contains("`@octocat`"))
    }

    @Test func mentionsInsideCodeSpansStayAlone() {
        #expect(IssueDraft.safeMentions("Ask `@octocat` first.") == "Ask `@octocat` first.")
        #expect(IssueDraft.safeMentions("Use `code @octocat here` as-is.") == "Use `code @octocat here` as-is.")
        #expect(IssueDraft.safeMentions("Ping @octocat and `@already`.") == "Ping `@octocat` and `@already`.")
        #expect(IssueDraft.safeMentions("email@example.com stays") == "email@example.com stays")
    }

    @Test func invalidFileClaimsAreRefusedLikeOtherRepositoryClaims() {
        var bad = fields()
        bad.files = ["../outside.swift"]
        #expect(IssueDraft(id: "a1b2c3d4", fields: bad, turn: "turn").problems(in: ["deskree-inc/oby"]).contains { $0.contains("repository-relative paths") })
    }

    @Test func storeRoundTripsIssueDrafts() throws {
        let store = JobStore(url: try folder().appending(path: "oby.sqlite"))
        let draft = IssueDraft(id: "a1b2c3d4", fields: fields(), turn: "turn")
        store.save(draft)
        #expect(store.issueDraft(draft.id) == draft)
        #expect(store.issueDrafts() == [draft])
    }

    @Test func storeKeepsOnlyTheNewestTwoHundredDrafts() throws {
        let store = JobStore(url: try folder().appending(path: "oby.sqlite"))
        for index in 0...200 {
            let date = Date(timeIntervalSince1970: TimeInterval(index))
            store.save(IssueDraft(id: String(format: "%08x", index), fields: fields(), turn: "turn", created: date, updated: date))
        }
        #expect(store.issueDrafts().count == 200)
        #expect(store.issueDraft("00000000") == nil)
        #expect(store.issueDraft("000000c8") != nil)
    }

    @Test @MainActor func apiListsPreviewsEditsAndDiscardsIssueDrafts() async throws {
        let root = try folder()
        let store = JobStore(url: root.appending(path: "oby.sqlite"))
        let draft = IssueDraft(id: "a1b2c3d4", fields: fields(), turn: "turn")
        var created = IssueDraft(id: "e5f6a7b8", fields: fields(), state: .created, turn: "turn")
        created.issue = 412
        store.save(draft)
        store.save(created)
        let desk = Desk(accounts: AccountStore(root: root), store: store)
        desk.repos = ["deskree-inc/oby"]
        let api = API(desk: desk, devices: Devices(file: root.appending(path: "devices.json")))

        let open = try api.issueDrafts(state: "open")
        #expect(open.status == .ok)
        let preview = try api.issueDraft(draft.id)
        #expect(preview.status == .ok)

        var revisedFields = fields()
        revisedFields.title = "Retry uploads safely"
        let revised = try await api.editIssueDraft(draft.id, IssueDraftEdit(version: 1, fields: revisedFields))
        #expect(revised.status == .ok)
        #expect(store.issueDraft(draft.id)?.version == 2)
        #expect(store.issueDraft(draft.id)?.previous?.title == "Retry uploads")

        let discarded = try api.discardIssueDraft(draft.id)
        #expect(discarded.status == .ok)
        #expect(store.issueDraft(draft.id)?.state == .discarded)
    }

    @Test @MainActor func createScansBeforeGitHubAndUsesAppActor() async throws {
        let store = JobStore(url: try folder().appending(path: "oby.sqlite"))
        let draft = IssueDraft(id: "a1b2c3d4", fields: fields(), turn: "turn")
        store.save(draft)
        var calls: [[String]] = []
        var actors: [GitHubActor] = []
        let creator = IssueCreator(store: store, gh: { args, actor in
            calls.append(args)
            actors.append(actor)
            if args.first == "issue", args.dropFirst().first == "list" { return "[]" }
            if args.first == "label" { return "[]" }
            return "https://github.com/deskree-inc/oby/issues/412"
        }, scan: { _ in [] })
        let result = await creator.create(draft.id, version: 1, repos: ["deskree-inc/oby"])
        #expect(result?.state == .created)
        #expect(result?.issue == 412)
        #expect(calls.contains { $0.starts(with: ["issue", "create", "-R", "deskree-inc/oby"]) })
        #expect(actors.allSatisfy { $0 == .app })
    }

    @Test @MainActor func failedScanDoesNotCreateIssue() async throws {
        let store = JobStore(url: try folder().appending(path: "oby.sqlite"))
        let draft = IssueDraft(id: "a1b2c3d4", fields: fields(), turn: "turn")
        store.save(draft)
        var calls: [[String]] = []
        let creator = IssueCreator(store: store, gh: { args, _ in calls.append(args); return "[]" }, scan: { _ in throw Shell.Failure(message: "scan unavailable") })
        _ = await creator.create(draft.id, version: 1, repos: ["deskree-inc/oby"])
        let result = await creator.create(draft.id, version: 1, repos: ["deskree-inc/oby"])
        #expect(result?.state == .failed)
        #expect(result?.error?.contains("scan unavailable") == true)
        #expect(!calls.contains { $0.starts(with: ["issue", "create"]) })
    }

    @Test func brainCannotCreateAndRevisionRequiresAnOpenDraft() throws {
        let create = Data(#"{"action":"create_issue","reply":"","dispatches":[],"question":null}"#.utf8)
        #expect(throws: (any Error).self) { try Plan.decode(create) }
        let revision = Plan(action: .reviseIssue, reply: "", dispatches: [], question: nil, item: "missing", issueDraft: fields())
        #expect(revision.problems(in: BrainContext(accounts: [:], repos: ["deskree-inc/oby"]), canary: "never").contains { $0.contains("isn't an open issue draft") })
    }

    @Test @MainActor func writingItUpAddsDraftAndCardTurn() async throws {
        final class Script: BrainAdapter, @unchecked Sendable {
            let name = "scripted"
            func complete(system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data {
                let json = try JSONSerialization.data(withJSONObject: ["action": "draft_issue", "reply": "Drafted an issue for deskree-inc/oby. Check it and press Create.", "dispatches": [], "question": NSNull(), "issue_draft": ["repo": "deskree-inc/oby", "title": "Retry uploads", "what": "Retry uploads.", "why": "Avoid data loss.", "how": "Try three times.", "acceptance": ["Offline retries stop"], "files": [], "labels": []], "item": NSNull()])
                return json
            }
        }
        let root = try folder()
        let desk = Desk(accounts: AccountStore(root: root), store: JobStore(url: root.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        desk.makeBrain = { _, _, _ in [Script()] }
        let (talk, _) = await desk.exchange("write what we decided as an issue")
        #expect(talk == .reply("Drafted an issue for deskree-inc/oby. Check it and press Create."))
        let draft = try #require(desk.issueDrafts.first)
        #expect(draft.version == 1)
        #expect(desk.turns.last?.issueDraft == draft.id)
        #expect(draft.body().contains("<!-- oby-draft: \(draft.id) -->"))
    }

    @Test @MainActor func revisionKeepsIdAndPreviousFields() async throws {
        let root = try folder()
        let store = JobStore(url: root.appending(path: "oby.sqlite"))
        let first = IssueDraft(id: "a1b2c3d4", fields: fields(), turn: "turn")
        store.save(first)
        final class Script: BrainAdapter, @unchecked Sendable {
            let name = "scripted"
            func complete(system: String, user: String, quoted: String?, schema: Data, timeout: TimeInterval) async throws -> Data {
                try JSONSerialization.data(withJSONObject: ["action": "revise_issue", "reply": "Updated the draft.", "dispatches": [], "question": NSNull(), "item": "a1b2c3d4", "issue_draft": ["repo": "deskree-inc/oby", "title": "Retry uploads safely", "what": "Retry uploads.", "why": "Avoid data loss.", "how": "Try three times.", "acceptance": ["No network stops after three attempts"], "files": ["Engine/Upload.swift"], "labels": []]])
            }
        }
        let desk = Desk(accounts: AccountStore(root: root), store: store)
        desk.repos = ["deskree-inc/oby"]
        desk.makeBrain = { _, _, _ in [Script()] }
        _ = await desk.exchange("add a no network test")
        let revised = try #require(store.issueDraft("a1b2c3d4"))
        #expect(revised.version == 2)
        #expect(revised.previous == first.fields)
        #expect(revised.fields.acceptance == ["No network stops after three attempts"])
    }

    @Test @MainActor func createRejectsStaleVersionBeforeGitHub() async throws {
        let root = try folder()
        let store = JobStore(url: root.appending(path: "oby.sqlite"))
        var draft = IssueDraft(id: "a1b2c3d4", fields: fields(), turn: "turn")
        draft.version = 2
        store.save(draft)
        let desk = Desk(accounts: AccountStore(root: root), store: store)
        desk.repos = ["deskree-inc/oby"]
        let api = API(desk: desk, devices: Devices(file: root.appending(path: "devices.json")))
        let response = try await api.createIssueDraft(draft.id, IssueDraftCreate(version: 1))
        #expect(response.status == .conflict)
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        let creator = IssueCreator(store: store, gh: { _, _ in calls.count += 1; return "unexpected" }, scan: { _ in [] })
        _ = await creator.create(draft.id, version: 1, repos: ["deskree-inc/oby"])
        #expect(calls.count == 0)
    }

    @Test @MainActor func failedCreateCanRetryAndAdoptsLostAnswer() async throws {
        final class State: @unchecked Sendable { var createCount = 0; var exists = false }
        let state = State()
        let store = JobStore(url: try folder().appending(path: "oby.sqlite"))
        let draft = IssueDraft(id: "a1b2c3d4", fields: fields(), turn: "turn")
        store.save(draft)
        let creator = IssueCreator(store: store, gh: { args, _ in
            if args.starts(with: ["issue", "list"]) {
                return state.exists ? #"[{"number":412,"url":"https://github.com/deskree-inc/oby/issues/412","body":"<!-- oby-draft: a1b2c3d4 -->"}]"# : "[]"
            }
            if args.starts(with: ["label", "list"]) { return "[]" }
            state.createCount += 1
            state.exists = true
            throw Shell.Failure(message: "lost response")
        }, scan: { _ in [] })
        _ = await creator.create(draft.id, version: 1, repos: ["deskree-inc/oby"])
        let result = await creator.create(draft.id, version: 1, repos: ["deskree-inc/oby"])
        #expect(result?.state == .created)
        #expect(result?.issue == 412)
        #expect(state.createCount == 1)
    }

    @Test @MainActor func failedCreateKeepsDraftAndSuccessfulRetryCreatesOnce() async throws {
        final class State: @unchecked Sendable { var creates = 0; var succeeded = 0 }
        let state = State()
        let store = JobStore(url: try folder().appending(path: "oby.sqlite"))
        let draft = IssueDraft(id: "a1b2c3d4", fields: fields(), turn: "turn")
        store.save(draft)
        let creator = IssueCreator(store: store, gh: { args, _ in
            if args.starts(with: ["issue", "list"]) { return "[]" }
            if args.starts(with: ["label", "list"]) { return "[]" }
            state.creates += 1
            if state.creates == 1 { throw Shell.Failure(message: "temporary GitHub failure") }
            state.succeeded += 1
            return "https://github.com/deskree-inc/oby/issues/412"
        }, scan: { _ in [] })
        let failed = await creator.create(draft.id, version: 1, repos: ["deskree-inc/oby"])
        #expect(failed?.state == .failed)
        #expect(failed?.fields == draft.fields)
        let created = await creator.create(draft.id, version: 1, repos: ["deskree-inc/oby"])
        #expect(created?.state == .created)
        #expect(created?.issue == 412)
        #expect(state.creates == 2)
        #expect(state.succeeded == 1)
    }

    @Test @MainActor func restartInCreatingReturnsToFailedWhenMarkerIsAbsent() async throws {
        let store = JobStore(url: try folder().appending(path: "oby.sqlite"))
        var draft = IssueDraft(id: "a1b2c3d4", fields: fields(), state: .creating, turn: "turn")
        store.save(draft)
        let creator = IssueCreator(store: store, gh: { _, _ in "[]" }, scan: { _ in [] })
        await creator.recover(repos: ["deskree-inc/oby"])
        draft = try #require(store.issueDraft(draft.id))
        #expect(draft.state == .failed)
        #expect(draft.error == "Oby restarted before GitHub answered.")
    }

    @Test @MainActor func restartInCreatingAdoptsAnIssueWithTheExactMarker() async throws {
        let store = JobStore(url: try folder().appending(path: "oby.sqlite"))
        var draft = IssueDraft(id: "a1b2c3d4", fields: fields(), state: .creating, turn: "turn")
        store.save(draft)
        let creator = IssueCreator(store: store, gh: { args, actor in
            #expect(actor == .app)
            #expect(args.contains("oby-draft: a1b2c3d4 in:body"))
            return #"[{"number":412,"url":"https://github.com/deskree-inc/oby/issues/412","body":"<!-- oby-draft: a1b2c3d4 -->"}]"#
        })
        await creator.recover(repos: ["deskree-inc/oby"])
        draft = try #require(store.issueDraft(draft.id))
        #expect(draft.state == .created)
        #expect(draft.issue == 412)
        #expect(draft.url == "https://github.com/deskree-inc/oby/issues/412")
    }

    @Test @MainActor func anUnreadableDuplicateSearchStopsBeforeLabelsAndCreate() async throws {
        let store = JobStore(url: try folder().appending(path: "oby.sqlite"))
        let draft = IssueDraft(id: "a1b2c3d4", fields: fields(), turn: "turn")
        store.save(draft)
        var calls: [[String]] = []
        let creator = IssueCreator(store: store, gh: { args, _ in calls.append(args); return "not json" }, scan: { _ in [] })
        let result = await creator.create(draft.id, version: 1, repos: ["deskree-inc/oby"])
        #expect(result?.state == .failed)
        #expect(result?.error?.contains("already created") == true)
        #expect(calls.count == 1)
        #expect(!calls.contains { $0.starts(with: ["issue", "create"]) })
    }

    @Test @MainActor func unknownLabelsAreDroppedAndReported() async throws {
        let store = JobStore(url: try folder().appending(path: "oby.sqlite"))
        var labeled = fields(); labeled.labels = ["existing", "missing"]
        let draft = IssueDraft(id: "a1b2c3d4", fields: labeled, turn: "turn")
        store.save(draft)
        var createArgs: [String] = []
        var reply: String?
        let creator = IssueCreator(store: store, gh: { args, _ in
            if args.starts(with: ["issue", "list"]) { return "[]" }
            if args.starts(with: ["label", "list"]) { return #"[{"name":"existing"}]"# }
            createArgs = args
            return "https://github.com/deskree-inc/oby/issues/412"
        }, scan: { _ in [] }, changed: { _, message in if let message { reply = message } })
        _ = await creator.create(draft.id, version: 1, repos: ["deskree-inc/oby"])
        #expect(createArgs.contains("existing"))
        #expect(!createArgs.contains("missing"))
        #expect(reply?.contains("missing") == true)
    }
}
