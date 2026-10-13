import Foundation

struct OfflineInboxAnswer: Codable, Equatable, Sendable {
    var id: String
    var answer: String?
    var done: Bool?
    var later: Date?
}

struct OfflineMessage: Codable, Equatable, Sendable {
    var id: String
    var said: String
    var question: String?
    var option: String?
    var voice: Bool
}

struct OfflineQueue: Sendable {
    enum FlushError: Error { case alreadySettled }

    var messages: [OfflineMessage] = []
    var answers: [OfflineInboxAnswer] = []

    mutating func queue(_ message: OfflineMessage) {
        messages.removeAll { $0.id == message.id }
        messages.append(message)
    }

    mutating func removeMessage(_ id: String) {
        messages.removeAll { $0.id == id }
    }

    mutating func queue(_ answer: OfflineInboxAnswer) {
        answers.removeAll { $0.id == answer.id }
        answers.append(answer)
    }

    mutating func flushAnswers(_ send: (OfflineInboxAnswer) async throws -> Void) async {
        let waiting = answers
        answers.removeAll()
        for (index, answer) in waiting.enumerated() {
            do {
                try await send(answer)
            } catch FlushError.alreadySettled {
                continue
            } catch {
                answers.append(contentsOf: waiting[index...])
                break
            }
        }
    }
}
