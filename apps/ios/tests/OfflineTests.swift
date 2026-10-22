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
        #expect(queue.answers.count == 1 && queue.answers[0].id == "i1" && queue.answers[0].answer == "Deny")
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

    @Test func queuesFlushOnlyToTheirOriginalRunner() async {
        let suiteName = "com.deskree.oby.destinations-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = OfflineQueue(defaults: defaults)
        queue.queue(OfflineMessage(id: "message-a", said: "a", question: nil, option: nil, voice: false, target: "runner:a"))
        queue.queue(OfflineMessage(id: "message-b", said: "b", question: nil, option: nil, voice: false, target: "runner:b"))
        queue.queue(OfflineInboxAnswer(id: "answer-a", answer: "Allow", done: nil, later: nil, target: "runner:a"))
        queue.queue(OfflineInboxAnswer(id: "answer-b", answer: "Deny", done: nil, later: nil, target: "runner:b"))

        var messages: [String] = []
        var answers: [String] = []
        await queue.flushMessages(for: "runner:b") { messages.append($0.id) }
        await queue.flushAnswers(for: "runner:b") { answers.append($0.id) }

        #expect(messages == ["message-b"])
        #expect(answers == ["answer-b"])
        #expect(queue.messages.map(\.id) == ["message-a"])
        #expect(queue.answers.map(\.id) == ["answer-a"])
    }

    @Test func legacyQueueEntriesBindToTheirCurrentRunner() {
        let suiteName = "com.deskree.oby.legacy-destination-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = OfflineQueue(defaults: defaults)
        queue.queue(OfflineMessage(id: "legacy-message", said: "hello", question: nil, option: nil, voice: false))
        queue.queue(OfflineInboxAnswer(id: "legacy-answer", answer: "Allow", done: nil, later: nil))

        queue.bindUnscopedEntries(to: "runner:old")
        let restored = OfflineQueue(defaults: defaults)
        #expect(restored.messages.first?.target == "runner:old")
        #expect(restored.answers.first?.target == "runner:old")
    }

    @Test func phoneDiscardAndRetryRemoveThePersistedOutboxEntry() {
        let suiteName = "com.deskree.oby.phone-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = OfflineQueue(defaults: defaults)
        let phone = Phone(offlineQueue: queue)

        phone.ask("discard this")
        let discarded = phone.echoes[0].id
        // Offline, words wait on the iPhone, marked.
        #expect(phone.waitsToSend(echo: discarded))
        phone.discard(echo: discarded)
        #expect(OfflineQueue(defaults: defaults).messages.isEmpty)

        phone.ask("retry this")
        let retried = phone.echoes[0].id
        phone.retry(echo: retried)
        let restored = OfflineQueue(defaults: defaults)
        #expect(restored.messages.count == 1)
        // The same words go again with their id: obid keeps them once if the first did reach it.
        #expect(restored.messages[0].id == retried)
    }

    /// docs/oby-ux.md row 18: an answer given offline keeps its decision on screen, marked "Sends
    /// when your Mac is back", and goes with its item's id; it no longer counts as needing you.
    @Test func phoneOfflineSettleKeepsTheDecisionMarkedAndPersistsOneAnswer() async throws {
        let suiteName = "com.deskree.oby.phone-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let item = InboxItem(
            kind: "question", id: "i1", job: "j1", title: "Question", text: "Allow?", options: ["Allow"],
            created: .now, done: nil, later: nil, answer: nil, headline: nil, happened: nil, recommended: nil, why: nil)
        let phone = Phone(offlineQueue: OfflineQueue(defaults: defaults), inbox: [item])

        try await phone.settle("i1", answer: "Allow")

        #expect(phone.inbox.map(\.id) == ["i1"])
        #expect(phone.waitsToSend(answer: "i1"))
        #expect(phone.answering.isEmpty)
        let answer = OfflineQueue(defaults: defaults).answers
        #expect(answer.count == 1 && answer[0].id == "i1" && answer[0].answer == "Allow")
    }

    /// #776: a Confirm offline isn't queued (its signature would be stale) and says so; the card
    /// stays. Cancel on the same item still queues.
    @Test func aConfirmOfflineIsNotQueued() async throws {
        let suiteName = "com.deskree.oby.confirm-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let item = InboxItem(
            kind: "confirm", id: "c1", job: "j1", title: "Delete Vault tests", text: "", options: ["Confirm", "Cancel"],
            created: .now, done: nil, later: nil, answer: nil, headline: nil, happened: nil, recommended: nil, why: nil)
        let phone = Phone(offlineQueue: OfflineQueue(defaults: defaults), inbox: [item])

        let error = await #expect(throws: RunnerError.self) { try await phone.settle("c1", answer: "Confirm") }
        #expect(error?.message == Phone.confirmNeedsTheMac)
        #expect(!phone.waitsToSend(answer: "c1") && OfflineQueue(defaults: defaults).answers.isEmpty)
        #expect(phone.inbox.map(\.id) == ["c1"])

        try await phone.settle("c1", answer: "Cancel")
        #expect(phone.waitsToSend(answer: "c1"))
    }

    @Test func messagesFlushInOrderAndKeepUnacceptedTail() async {
        let queue = OfflineQueue(defaults: UserDefaults(suiteName: "com.deskree.oby.flush-\(UUID().uuidString)")!)
        queue.messages = [
            OfflineMessage(id: "one", said: "one", question: nil, option: nil, voice: false),
            OfflineMessage(id: "two", said: "two", question: nil, option: nil, voice: false),
            OfflineMessage(id: "three", said: "three", question: nil, option: nil, voice: false)
        ]
        var sent: [String] = []
        await queue.flushMessages { message in
            sent.append(message.id)
            if message.id == "two" { throw URLError(.notConnectedToInternet) }
        }
        #expect(sent == ["one", "two"])
        #expect(queue.messages.map(\.id) == ["two", "three"])
    }

    @Test func queuesExpireOldEntriesAndKeepTheirNewestBoundedTail() {
        let suiteName = "com.deskree.oby.limits-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = OfflineQueue(defaults: defaults)
        let old = Date.now.addingTimeInterval(-OfflineQueue.maxAge - 1)
        queue.messages = [OfflineMessage(id: "old", said: "old", question: nil, option: nil, voice: false, queuedAt: old)]
            + (0..<OfflineQueue.maxEntries + 1).map { index in
                OfflineMessage(id: "m\(index)", said: "m\(index)", question: nil, option: nil, voice: false)
            }
        queue.save()
        #expect(queue.messages.count == OfflineQueue.maxEntries)
        #expect(queue.messages.first?.id == "m1")
        #expect(!queue.messages.contains(where: { $0.id == "old" }))
    }

    @Test func alreadySettled404IsMapped() {
        #expect(OfflineQueue.isAlreadySettled(RunnerError(message: "gone", status: 404)))
        #expect(!OfflineQueue.isAlreadySettled(RunnerError(message: "bad", status: 400)))
    }

    /// obid answers 409 "That item is done already." for a decision settled meanwhile (sphere/link.rs):
    /// the stale answer leaves the queue, and the ones after it still go.
    @Test func anAnswerObidCallsDoneAlreadyLeavesTheQueue() async {
        #expect(OfflineQueue.isAlreadySettled(RunnerError(message: "That item is done already.", status: 409)))
        let suiteName = "com.deskree.oby.offline-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = OfflineQueue(defaults: defaults)
        queue.answers = [OfflineInboxAnswer(id: "stale", answer: "Allow", done: nil, later: nil),
                         OfflineInboxAnswer(id: "next", answer: "Allow", done: nil, later: nil)]
        var sent: [String] = []
        await queue.flushAnswers { item in
            do {
                if item.id == "stale" { throw RunnerError(message: "That item is done already.", status: 409) }
                sent.append(item.id)
            } catch {
                // As Phone.flushQueuedInbox maps it.
                if OfflineQueue.isAlreadySettled(error) { throw OfflineQueue.FlushError.alreadySettled }
                throw error
            }
        }
        #expect(sent == ["next"])
        #expect(queue.answers.isEmpty)
    }

    @Test func messageAndInboxActionsRoundTripThroughCodableStorage() throws {
        let message = OfflineMessage(id: "m1", said: "build it", question: nil, option: nil, voice: false)
        let answer = OfflineInboxAnswer(id: "i1", answer: "Allow", done: nil, later: nil)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(OfflineMessage.self, from: encoder.encode(message)) == message)
        #expect(try decoder.decode(OfflineInboxAnswer.self, from: encoder.encode(answer)) == answer)
    }

    // MARK: The one line (docs/oby-ux.md row 17, onboarding.md "Errors and recovery")

    @Test func theReachLineSaysWhyInTheSameWords() {
        let seen = Date(timeIntervalSince1970: 1_791_582_173)
        // Live, or still connecting: nothing to say.
        #expect(ReachNotice.of(.live, online: true, status: nil, paired: true, lastSeen: seen) == nil)
        #expect(ReachNotice.of(.connecting, online: true, status: nil, paired: true, lastSeen: seen) == nil)
        // No network on the iPhone comes first: the Mac may be fine.
        #expect(ReachNotice.of(.offline("x"), online: false, status: nil, paired: true, lastSeen: seen) == .noInternet(lastSeen: seen))
        // The gateway refused this iPhone's token: removed (revoked, or unused 30 days).
        #expect(ReachNotice.of(.offline("x"), online: true, status: 401, paired: true, lastSeen: seen) == .removed)
        // A runner without pairing answers 401 for another reason: it's just unreachable.
        #expect(ReachNotice.of(.offline("x"), online: true, status: 401, paired: false, lastSeen: seen) == .unreachable(lastSeen: seen))
        #expect(ReachNotice.of(.offline("x"), online: true, status: nil, paired: true, lastSeen: nil) == .unreachable(lastSeen: nil))

        #expect(ReachNotice.unreachable(lastSeen: nil).title == "Can't reach your Mac")
        #expect(ReachNotice.unreachable(lastSeen: nil).detail == "Check it's on and online.")
        #expect(ReachNotice.unreachable(lastSeen: seen).detail.hasPrefix("Last seen "))
        #expect(ReachNotice.unreachable(lastSeen: seen).detail.hasSuffix(". Check it's on and online."))
        #expect(ReachNotice.noInternet(lastSeen: seen).title == "No internet on this iPhone")
        #expect(ReachNotice.noInternet(lastSeen: seen).detail.hasPrefix("Showing what Oby knew at "))
        #expect(ReachNotice.asleep(since: nil).title == "Your Mac is asleep")
        #expect(ReachNotice.asleep(since: nil).detail == "Oby picks up when it wakes; what you send waits here until then.")
        #expect(ReachNotice.removed.title == "This iPhone was removed from your Mac")
        #expect(ReachNotice.removed.detail == "Scan the code in Oby on your Mac to connect again.")
        #expect(ReachNotice.waiting == "Sends when your Mac is back")
    }
}
