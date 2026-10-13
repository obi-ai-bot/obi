import Foundation
import Testing
@testable import Oby

struct OfflineTests {
    @Test func messageAndInboxActionsRoundTripThroughCodableStorage() throws {
        let message = OfflineMessage(id: "m1", said: "build it", question: nil, option: nil, voice: false)
        let answer = OfflineInboxAnswer(id: "i1", answer: "Allow", done: nil, later: nil)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(OfflineMessage.self, from: encoder.encode(message)) == message)
        #expect(try decoder.decode(OfflineInboxAnswer.self, from: encoder.encode(answer)) == answer)
    }
}
