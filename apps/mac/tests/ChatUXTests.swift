import Darwin
import Foundation
import Testing
@testable import Oby

/// The conversation as immediate as the owner's terminal: a box keeps what's typed until it's sent
/// (`Drafts`), and words show in the thread the instant Send is pressed (`RunnerFeed.Echo`), kept,
/// marked, when they don't reach obid.
@MainActor
struct ChatUXTests {
    @Test func aBoxKeepsItsDraftUntilItsSent() throws {
        let defaults = try #require(UserDefaults(suiteName: "ChatUXTests-\(UUID().uuidString)"))
        Drafts.keep("half a thought", as: Drafts.conversation("a"), in: defaults)
        Drafts.keep("for Home", as: Drafts.home, in: defaults)
        #expect(Drafts.text(Drafts.conversation("a"), in: defaults) == "half a thought")
        #expect(Drafts.text(Drafts.conversation("b"), in: defaults).isEmpty)
        #expect(Drafts.text(Drafts.home, in: defaults) == "for Home")
        // Sent: the box empties, and so does its draft; the other boxes keep theirs.
        Drafts.keep("  \n", as: Drafts.conversation("a"), in: defaults)
        #expect(Drafts.text(Drafts.conversation("a"), in: defaults).isEmpty)
        #expect(Drafts.text(Drafts.home, in: defaults) == "for Home")
        #expect(Drafts.conversation(nil) != Drafts.conversation("new-id") && Drafts.task("j") != Drafts.conversation("j"))
        // A week untouched, a draft (a pasted secret too) is let go; the next save drops it for good.
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        Drafts.keep("pasted sk-test", as: Drafts.task("old"), in: defaults, now: then)
        #expect(Drafts.text(Drafts.task("old"), in: defaults, now: then + 86_400) == "pasted sk-test")
        #expect(Drafts.text(Drafts.task("old"), in: defaults, now: then + Drafts.kept + 1).isEmpty)
        Drafts.keep("new", as: Drafts.home, in: defaults, now: then + Drafts.kept + 1)
        #expect(!(defaults.dictionary(forKey: Drafts.key)?.keys.contains(Drafts.task("old")) ?? true))
    }

    /// obid's turn takes the echo's id (`Runner.planned`), so only it settles the echo: the same words
    /// in another conversation, or said again a moment later, are other messages; a failed echo
    /// gives way only to its own turn (they reached obid after all).
    @Test func onlyObidsTurnOfTheirIdSettlesWordsOnTheirWay() async throws {
        let feed = RunnerFeed()
        let model = IslandModel(desk: Desk(), feed: feed, availability: MacAvailability())
        feed.conversations.take([RunnerConversation(id: "a", title: "A")])
        feed.echo("yes")
        let echo = try #require(feed.echoes.first?.turn)
        // A "yes" a moment earlier in this conversation, and one in another: not these words.
        let earlier = Turn(date: echo.date - 5, who: .user, text: "yes", conversation: "a")
        feed.conversation.apply(earlier)
        feed.settleEchoes(earlier)
        feed.settleEchoes(Turn(date: echo.date + 1, who: .user, text: "yes", conversation: "b"))
        #expect(feed.echoes.count == 1 && model.thread.map(\.id) == [earlier.id, echo.id])
        // obid's turn of their id: one bubble, obid's.
        let listed = Turn(id: echo.id, date: echo.date + 1, who: .user, text: "yes", conversation: "a")
        feed.conversation.apply(listed)
        feed.settleEchoes(listed)
        #expect(feed.echoes.isEmpty && model.thread.map(\.id) == [earlier.id, echo.id])
    }

    /// A port that takes connections and never answers: a send that stays on its way.
    private func silentPort() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        try #require(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } } == 0)
        try #require(listen(fd, 8) == 0)
        try #require(withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } } == 0)
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    @Test func wordsShowAtOnceAndAreGoneWhenObidListsThemOrTheyreGivenUp() async throws {
        let feed = RunnerFeed()
        let model = IslandModel(desk: Desk(), feed: feed, availability: MacAvailability())
        feed.conversations.take([RunnerConversation(id: "a", title: "A")])
        let (fd, port) = try silentPort()
        defer { close(fd) }
        let runner = Runner(base: try #require(URL(string: "http://127.0.0.1:\(port)")))
        let sending = Task { try await feed.plan("ship it", answer: nil, on: runner) }
        for _ in 0..<100 where feed.echoes.isEmpty { await Task.yield() }
        // On its way: in the thread at once, not failed.
        #expect(model.thread.map(\.text) == ["ship it"])
        let echo = try #require(feed.echoes.first)
        #expect(echo.conversation == "a" && echo.problem == nil)
        // Given up (Stop, or other words in their place): they leave the thread.
        sending.cancel()
        _ = try? await sending.value
        #expect(feed.echoes.isEmpty && model.thread.isEmpty)
    }

    /// Send to bubble: the box's Send (`IslandModel.sendChat`) puts the words in the thread at once,
    /// even while the turn they replace lets go (before, the bubble waited for obid's `turn` event),
    /// and the request takes that echo up: one bubble.
    @Test func sendToBubbleTakesNoRoundTrip() async throws {
        let feed = RunnerFeed()
        let desk = Desk()
        let model = IslandModel(desk: desk, feed: feed, availability: MacAvailability())
        feed.conversations.take([RunnerConversation(id: "a", title: "A")])
        let (fd, port) = try silentPort()
        defer { close(fd) }
        let runner = Runner(base: try #require(URL(string: "http://127.0.0.1:\(port)")))
        desk.plansElsewhere = { true }
        desk.planElsewhere = { said, answer in try await feed.plan(said, answer: answer, on: runner) }
        let clock = ContinuousClock()
        let sent = clock.now
        model.sendChat("ship it")
        let took = clock.now - sent
        print("Send to bubble: \(took)")
        #expect(model.thread.map(\.text) == ["ship it"] && took < .milliseconds(50))
        for _ in 0..<1000 where !(feed.echoes.first?.sending ?? true) { await Task.yield() }
        #expect(feed.echoes.count == 1 && feed.echoes[0].sending && model.thread.count == 1)
        desk.cancel()
        for _ in 0..<1000 where !feed.echoes.isEmpty { await Task.yield() }
        #expect(model.thread.isEmpty)
    }

    @Test func wordsThatDontReachObidStayMarkedUntilTriedAgainOrEdited() async throws {
        let feed = RunnerFeed()
        let model = IslandModel(desk: Desk(), feed: feed, availability: MacAvailability())
        feed.conversations.take([RunnerConversation(id: "a", title: "A")])
        // Nothing listens on port 9.
        let nowhere = Runner(base: try #require(URL(string: "http://127.0.0.1:9")))
        await #expect(throws: (any Error).self) { try await feed.plan("ship it", answer: nil, on: nowhere) }
        let echo = try #require(feed.echoes.first)
        #expect(model.thread.map(\.text) == ["ship it"] && feed.echoProblem(echo.turn.id) != nil)
        // The same words in a turn of another id don't hide them: failed, they wait for their own.
        let other = Turn(date: echo.turn.date + 1, who: .user, text: "ship it", conversation: "a")
        feed.conversation.apply(other)
        feed.settleEchoes(other)
        #expect(feed.echoes.count == 1 && model.thread.map(\.id) == [echo.turn.id, other.id])
        // Try again sends the same echo, with its id (obid keeps the words once).
        feed.retryEcho(echo.turn.id)
        await #expect(throws: (any Error).self) { try await feed.plan("ship it", answer: nil, on: nowhere) }
        #expect(feed.echoes.map(\.turn.id) == [echo.turn.id] && feed.echoProblem(echo.turn.id) != nil)
        feed.dropEcho(echo.turn.id)
        feed.conversation.forget()
        #expect(model.thread.isEmpty)
        // An answer to Oby's question shows as its option, as obid lists it.
        _ = try? await feed.plan("deploy", answer: (question: "Where?", option: "Staging"), on: nowhere)
        #expect(model.thread.map(\.text) == ["Staging"])
    }
}
