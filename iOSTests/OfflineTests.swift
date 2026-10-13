import Foundation
import Testing
@testable import Oby

@MainActor
struct OfflineTests {
    @Test func queueReplacesAnswersAndRemovesDiscardedMessages() {
        let message = OfflineMessage(id: "m1", said: "build it", question: nil, option: nil, voice: false)
        let suiteName = "com.deskree.oby.offline-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = OfflineQueue(defaults: defaults)
        queue.queue(message)
        queue.queue(message)
        queue.removeMessage("m1")
        queue.queue(OfflineInboxAnswer(id: "i1", answer: "Allow", done: nil, later: nil))
        queue.queue(OfflineInboxAnswer(id: "i1", answer: "Deny", done: nil, later: nil))
        #expect(queue.messages.isEmpty)
        #expect(queue.answers == [OfflineInboxAnswer(id: "i1", answer: "Deny", done: nil, later: nil)])
        let restored = OfflineQueue(defaults: defaults)
        #expect(restored.messages.isEmpty && restored.answers == queue.answers)
    }

    @Test func flushKeepsLaterAnswersAfterFailureAndDropsAlreadySettled() async {
        let suiteName = "com.deskree.oby.offline-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = OfflineQueue(defaults: defaults)
        queue.answers = [
            OfflineInboxAnswer(id: "settled", answer: "Allow", done: nil, later: nil),
            OfflineInboxAnswer(id: "fails", answer: "Deny", done: nil, later: nil),
            OfflineInboxAnswer(id: "later", answer: "Allow", done: nil, later: nil)
        ]
        await queue.flushAnswers { item in
            if item.id == "settled" { throw OfflineQueue.FlushError.alreadySettled }
            if item.id == "fails" { throw URLError(.notConnectedToInternet) }
        }
        #expect(queue.answers.map(\.id) == ["fails", "later"])
    }

    @Test func phoneDiscardAndRetryRemoveThePersistedOutboxEntry() {
        let suiteName = "com.deskree.oby.phone-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = OfflineQueue(defaults: defaults)
        let phone = Phone(offlineQueue: queue)

        phone.ask("discard this")
        let discarded = phone.echoes[0].id
        phone.discard(echo: discarded)
        #expect(OfflineQueue(defaults: defaults).messages.isEmpty)

        phone.ask("retry this")
        let retried = phone.echoes[0].id
        phone.retry(echo: retried)
        let restored = OfflineQueue(defaults: defaults)
        #expect(restored.messages.count == 1)
        #expect(restored.messages[0].id != retried)
    }

    @Test func phoneOfflineSettleRemovesInboxAndPersistsOneAnswer() async throws {
        let suiteName = "com.deskree.oby.phone-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let item = InboxItem(
            kind: "question", id: "i1", job: "j1", title: "Question", text: "Allow?", options: ["Allow"],
            created: .now, done: nil, later: nil, answer: nil, headline: nil, happened: nil, recommended: nil, why: nil)
        let phone = Phone(offlineQueue: OfflineQueue(defaults: defaults), inbox: [item])

        try await phone.settle("i1", answer: "Allow")

        #expect(phone.inbox.isEmpty)
        #expect(OfflineQueue(defaults: defaults).answers == [OfflineInboxAnswer(id: "i1", answer: "Allow", done: nil, later: nil)])
    }

    @Test func alreadySettled404IsMapped() {
        #expect(OfflineQueue.isAlreadySettled(RunnerError(message: "gone", status: 404)))
        #expect(!OfflineQueue.isAlreadySettled(RunnerError(message: "bad", status: 400)))
    }

    @Test func messageAndInboxActionsRoundTripThroughCodableStorage() throws {
        let message = OfflineMessage(id: "m1", said: "build it", question: nil, option: nil, voice: false)
        let answer = OfflineInboxAnswer(id: "i1", answer: "Allow", done: nil, later: nil)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(OfflineMessage.self, from: encoder.encode(message)) == message)
        #expect(try decoder.decode(OfflineInboxAnswer.self, from: encoder.encode(answer)) == answer)
    }
}
