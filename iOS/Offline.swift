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

final class OfflineQueue: @unchecked Sendable {
    enum FlushError: Error { case alreadySettled }

    static func isAlreadySettled(_ error: Error) -> Bool {
        (error as? RunnerError)?.status == 404
    }

    var messages: [OfflineMessage] = []
    var answers: [OfflineInboxAnswer] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        messages = (try? JSONDecoder().decode([OfflineMessage].self, from: defaults.data(forKey: "phone.outbox") ?? Data())) ?? []
        answers = (try? JSONDecoder().decode([OfflineInboxAnswer].self, from: defaults.data(forKey: "phone.inboxOutbox") ?? Data())) ?? []
    }

    func save() {
        defaults.set(try? JSONEncoder().encode(messages), forKey: "phone.outbox")
        defaults.set(try? JSONEncoder().encode(answers), forKey: "phone.inboxOutbox")
    }

    func queue(_ message: OfflineMessage) {
        messages.removeAll { $0.id == message.id }
        messages.append(message)
        save()
    }

    func removeMessage(_ id: String) {
        messages.removeAll { $0.id == id }
        save()
    }

    func queue(_ answer: OfflineInboxAnswer) {
        answers.removeAll { $0.id == answer.id }
        answers.append(answer)
        save()
    }

    func flushAnswers(_ send: (OfflineInboxAnswer) async throws -> Void) async {
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
        save()
    }
}
