import Foundation

struct OfflineInboxAnswer: Codable, Equatable, Sendable {
    var id: String
    var answer: String?
    var done: Bool?
    var later: Date?
    var queuedAt: Date = .now

    private enum CodingKeys: String, CodingKey { case id, answer, done, later, queuedAt }

    init(id: String, answer: String?, done: Bool?, later: Date?, queuedAt: Date = .now) {
        self.id = id
        self.answer = answer
        self.done = done
        self.later = later
        self.queuedAt = queuedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        answer = try values.decodeIfPresent(String.self, forKey: .answer)
        done = try values.decodeIfPresent(Bool.self, forKey: .done)
        later = try values.decodeIfPresent(Date.self, forKey: .later)
        queuedAt = try values.decodeIfPresent(Date.self, forKey: .queuedAt) ?? .now
    }
}

struct OfflineMessage: Codable, Equatable, Sendable {
    var id: String
    var said: String
    var question: String?
    var option: String?
    var voice: Bool
    var queuedAt: Date = .now

    private enum CodingKeys: String, CodingKey { case id, said, question, option, voice, queuedAt }

    init(id: String, said: String, question: String?, option: String?, voice: Bool, queuedAt: Date = .now) {
        self.id = id
        self.said = said
        self.question = question
        self.option = option
        self.voice = voice
        self.queuedAt = queuedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        said = try values.decode(String.self, forKey: .said)
        question = try values.decodeIfPresent(String.self, forKey: .question)
        option = try values.decodeIfPresent(String.self, forKey: .option)
        voice = try values.decode(Bool.self, forKey: .voice)
        queuedAt = try values.decodeIfPresent(Date.self, forKey: .queuedAt) ?? .now
    }
}

final class OfflineQueue: @unchecked Sendable {
    enum FlushError: Error { case alreadySettled }
    static let maxEntries = 50
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

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
        if prune() { persist() }
    }

    func save() {
        prune()
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(messages), forKey: "phone.outbox")
        defaults.set(try? JSONEncoder().encode(answers), forKey: "phone.inboxOutbox")
    }

    @discardableResult
    private func prune(now: Date = .now) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.maxAge)
        let oldMessages = messages
        let oldAnswers = answers
        messages = Array(messages.filter { $0.queuedAt >= cutoff }.suffix(Self.maxEntries))
        answers = Array(answers.filter { $0.queuedAt >= cutoff }.suffix(Self.maxEntries))
        return messages != oldMessages || answers != oldAnswers
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

    /// Sends messages in their persisted order. A message leaves the queue only after `send`
    /// returns, which means the runner accepted it. A failure leaves that message and everything
    /// after it for the next connection.
    func flushMessages(_ send: (OfflineMessage) async throws -> Void) async {
        prune()
        while let message = messages.first {
            do {
                try await send(message)
                messages.removeFirst()
                save()
            } catch {
                save()
                return
            }
        }
    }

    func flushAnswers(_ send: (OfflineInboxAnswer) async throws -> Void) async {
        prune()
        while let answer = answers.first {
            do {
                try await send(answer)
                answers.removeFirst()
            } catch FlushError.alreadySettled {
                answers.removeFirst()
            } catch {
                save()
                return
            }
            save()
        }
    }
}
