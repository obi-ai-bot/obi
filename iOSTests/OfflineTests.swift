import Foundation
import Testing
@testable import Oby

struct OfflineTests {
    @Test func queueReplacesAnswersAndRemovesDiscardedMessages() {
        let message = OfflineMessage(id: "m1", said: "build it", question: nil, option: nil, voice: false)
        let suiteName = "com.deskree.oby.offline-(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var queue = OfflineQueue(defaults: defaults)
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
        let suiteName = "com.deskree.oby.offline-(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var queue = OfflineQueue(defaults: defaults)
        queue.answers = [
            OfflineInboxAnswer(id: "settled", answer: "Allow", done: nil, later: nil),
            OfflineInboxAnswer(id: "fails", answer: "Deny", done: nil, later: nil),
            OfflineInboxAnswer(id: "later", answer: "Allow", done: nil, later: nil)
        ]
        await queue.flushAnswers { item in
            if item.id == "settled" { throw OfflineQueue.FlushError.alreadySettled }
            if item.id == "fails" { throw URLError(.notConnected) }
        }
        #expect(queue.answers.map(\.id) == ["fails", "later"])
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
