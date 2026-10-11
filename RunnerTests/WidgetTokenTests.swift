import Foundation
import Testing
@testable import ObyShared

/// The Watch complications' push token reaches the runner however WidgetKit issues it: a new or
/// rotated token is uploaded until the runner accepts it (Shared/WidgetToken.swift).
@MainActor
final class WidgetTokenTests {
    /// The app group's copy, and what reached the runner.
    var saved = WidgetToken()
    var sent: [Data] = []
    var waits: [Int] = []
    /// How many uploads fail before the runner takes one.
    var failing = 0

    let first = Data([0x01, 0x02, 0x03])
    let rotated = Data([0x04, 0x05, 0x06])

    struct Unreachable: Error {}

    func deliver(attempts: Int, onSend: (Data) -> Void = { _ in }) async -> Bool {
        await WidgetToken.deliver(attempts: attempts, current: { saved }, accept: { token in
            if saved.issued == token { saved.accept(token) }
        }, send: { token in
            sent.append(token)
            onSend(token)
            if failing > 0 {
                failing -= 1
                throw Unreachable()
            }
        }, wait: { waits.append($0) })
    }

    @Test func aNewTokenIsUploadedOnce() async {
        saved.issued = first
        #expect(await deliver(attempts: 3))
        #expect(sent == [first] && saved.accepted == first && saved.pending == nil)
        // Accepted already: the next run sends nothing.
        #expect(await deliver(attempts: 3))
        #expect(sent == [first])
    }

    @Test func aFailedUploadIsTriedAgainUntilTheRunnerAcceptsIt() async {
        saved.issued = first
        failing = 2
        #expect(await deliver(attempts: 3))
        #expect(sent == [first, first, first] && waits == [1, 2] && saved.accepted == first)
    }

    @Test func aTokenThatCantGoNowStaysPendingForTheNextRun() async {
        saved.issued = first
        failing = 5
        #expect(await deliver(attempts: 2) == false)
        #expect(saved.pending == first && saved.accepted == nil)
        // The app runs later, the runner is reachable: it goes then.
        failing = 0
        #expect(await deliver(attempts: 1))
        #expect(saved.accepted == first)
    }

    @Test func aRotatedTokenGoesTooEvenAfterTheFirstWasAccepted() async {
        saved.issued = first
        #expect(await deliver(attempts: 3))
        // WidgetKit rotates it after the app's push callback.
        saved.issued = rotated
        #expect(saved.pending == rotated)
        #expect(await deliver(attempts: 3))
        #expect(sent == [first, rotated] && saved.accepted == rotated)
    }

    @Test func aTokenRotatedDuringAnUploadIsSentNext() async {
        saved.issued = first
        #expect(await deliver(attempts: 3) { token in
            if token == self.first { self.saved.issued = self.rotated }
        })
        // The first was taken, but it isn't the latest: the rotated one followed.
        #expect(sent == [first, rotated] && saved.accepted == rotated && saved.pending == nil)
    }

    @Test func noTokenSendsNothing() async {
        #expect(await deliver(attempts: 3))
        #expect(sent.isEmpty)
    }
}
