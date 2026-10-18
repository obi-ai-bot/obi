import Foundation

struct OfflineInboxAnswer: Codable, Equatable, Sendable {
    var id: String
    var answer: String?
    var done: Bool?
    var later: Date?
    var target: String?
    var queuedAt: Date = .now

    private enum CodingKeys: String, CodingKey { case id, answer, done, later, target, queuedAt }

    init(id: String, answer: String?, done: Bool?, later: Date?, target: String? = nil, queuedAt: Date = .now) {
        self.id = id
        self.answer = answer
        self.done = done
        self.later = later
        self.target = target
        self.queuedAt = queuedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        answer = try values.decodeIfPresent(String.self, forKey: .answer)
        done = try values.decodeIfPresent(Bool.self, forKey: .done)
        later = try values.decodeIfPresent(Date.self, forKey: .later)
        target = try values.decodeIfPresent(String.self, forKey: .target)
        queuedAt = try values.decodeIfPresent(Date.self, forKey: .queuedAt) ?? .now
    }
}

struct OfflineMessage: Codable, Equatable, Sendable {
    var id: String
    var said: String
    var question: String?
    var option: String?
    var voice: Bool
    var target: String?
    var queuedAt: Date = .now
    /// The conversation the words were for (obid, #493), or whether they start one; nil on words
    /// queued before conversations, which join the latest.
    var conversation: String?
    var new: Bool?

    private enum CodingKeys: String, CodingKey { case id, said, question, option, voice, target, queuedAt, conversation, new }

    init(id: String, said: String, question: String?, option: String?, voice: Bool, target: String? = nil, queuedAt: Date = .now,
         conversation: String? = nil, new: Bool? = nil) {
        self.conversation = conversation
        self.new = new
        self.id = id
        self.said = said
        self.question = question
        self.option = option
        self.voice = voice
        self.target = target
        self.queuedAt = queuedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        said = try values.decode(String.self, forKey: .said)
        question = try values.decodeIfPresent(String.self, forKey: .question)
        option = try values.decodeIfPresent(String.self, forKey: .option)
        voice = try values.decode(Bool.self, forKey: .voice)
        target = try values.decodeIfPresent(String.self, forKey: .target)
        queuedAt = try values.decodeIfPresent(Date.self, forKey: .queuedAt) ?? .now
        conversation = try? values.decodeIfPresent(String.self, forKey: .conversation)
        new = try? values.decodeIfPresent(Bool.self, forKey: .new)
    }
}

@Observable
final class OfflineQueue: @unchecked Sendable {
    enum FlushError: Error { case alreadySettled }
    static let maxEntries = 50
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// The runner no longer has it waiting: 404 (gone), or obid's 409 "That item is done already."
    /// (settled meanwhile). Either way the answer leaves the queue, and the next ones still go.
    static func isAlreadySettled(_ error: Error) -> Bool {
        [404, 409].contains((error as? RunnerError)?.status)
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

    /// Older queue entries have no destination. Bind them once, on load, to the currently
    /// configured runner so later runner changes cannot redirect or discard them.
    func bindUnscopedEntries(to target: String) {
        var changed = false
        for index in messages.indices where messages[index].target == nil {
            messages[index].target = target
            changed = true
        }
        for index in answers.indices where answers[index].target == nil {
            answers[index].target = target
            changed = true
        }
        if changed { save() }
    }

    func queue(_ answer: OfflineInboxAnswer) {
        answers.removeAll { $0.id == answer.id }
        answers.append(answer)
        save()
    }

    /// Sends messages in their persisted order. A message leaves the queue only after `send`
    /// returns, which means the runner accepted it. A failure leaves that target's remaining
    /// messages for the next connection.
    func flushMessages(for target: String? = nil, _ send: (OfflineMessage) async throws -> Void) async {
        prune()
        while let index = messages.firstIndex(where: { $0.target == target }) {
            let message = messages[index]
            do {
                try await send(message)
                if let sentIndex = messages.firstIndex(of: message) { messages.remove(at: sentIndex) }
                save()
            } catch {
                save()
                return
            }
        }
    }

    func flushAnswers(for target: String? = nil, _ send: (OfflineInboxAnswer) async throws -> Void) async {
        prune()
        while let index = answers.firstIndex(where: { $0.target == target }) {
            let answer = answers[index]
            do {
                try await send(answer)
                if let sentIndex = answers.firstIndex(of: answer) { answers.remove(at: sentIndex) }
            } catch FlushError.alreadySettled {
                if let settledIndex = answers.firstIndex(of: answer) { answers.remove(at: settledIndex) }
            } catch {
                save()
                return
            }
            save()
        }
    }
}
