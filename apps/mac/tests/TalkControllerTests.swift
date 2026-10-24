import AppKit
import Foundation
import Testing
@testable import Oby

/// The talk key's turn, driven through IslandController (workstream V): the keys go in through its
/// TalkKey, Oby's replies through `replied`, Stop all through `stopAll` as the menu calls it. Its desk
/// is a scratch one, its voice has no microphone, and nothing reaches a brain, Notification Center,
/// VoiceOver or GitHub.
@MainActor
@Suite(.serialized)
struct TalkControllerTests {
    /// What the controller did outside, and the words its voice will hear, in order.
    final class Outside {
        var words: [String] = []
        var asked: [String] = []
        var posted: [String] = []
        var announced: [String] = []
    }

    let out = Outside()
    let island: IslandController

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oby-talk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let out = out
        island = IslandController(desk: desk, voice: Voice(saying: { out.words.isEmpty ? "" : out.words.removeFirst() }))
        island.outside = .init(ask: { out.asked.append($0) }, post: { title, _ in out.posted.append(title) },
                               announce: { out.announced.append($0) }, guideGlobeKey: {}, knownRepos: { ["deskree-inc/oby"] })
        // The window shows what you say: the pill only comes for a reply.
        island.windowShowsTalk = { true }
        island.talkKey.on = { [weak island] in island?.talk($0) }
    }

    private func fn(down: Bool) {
        _ = island.talkKey.handle(.flagsChanged, code: 63, flags: down ? .maskSecondaryFn : [], repeating: false)
    }

    /// A short fn tap: a press, and nothing starts.
    private func tap() {
        fn(down: true)
        fn(down: false)
    }

    private func until(_ done: () -> Bool) async throws {
        for _ in 0..<150 where !done() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// fn + Space, `words`, and fn again to send: Oby thinks about them.
    private func askHandsFree(_ words: String) async throws {
        let before = out.asked.count
        out.words.append(words)
        fn(down: true)
        _ = island.talkKey.handle(.keyDown, code: 49, flags: .maskSecondaryFn, repeating: false)
        fn(down: false)
        #expect(island.model.voice.phase == .listening && island.model.voice.handsFree)
        tap()
        try await until { out.asked.count > before && island.model.voice.phase == .idle && !island.model.listening }
        #expect(out.asked.last == words && island.model.turn == .thinking)
    }

    /// Held fn, `words`, let go: Oby thinks about them.
    private func askHolding(_ words: String) async throws {
        out.words.append(words)
        fn(down: true)
        try await until { island.model.voice.phase == .listening }
        fn(down: false)
        try await until { island.model.voice.phase == .idle && !island.model.listening }
        #expect(out.asked.last == words && island.model.turn == .thinking)
    }

    /// Hands-free words: once the reply shows, Oby listens again, the reply above and VoiceOver quiet
    /// (the microphone is open). A press with nothing said ends it, with no "Oby didn't catch that".
    @Test func handsFreeWordsListenAgainOnceTheReplyShows() async throws {
        try await askHandsFree("fix the vault tests")
        island.replied("Which repository?", spoken: true)
        #expect(island.model.turn == .listening && island.model.voice.phase == .listening && island.talkKey.busy)
        #expect(island.model.reply == "Which repository?" && out.announced.isEmpty)
        tap()
        try await until { island.model.turn == nil }
        #expect(island.model.voice.phase == .idle && !island.talkKey.busy)
        #expect(out.posted.isEmpty && out.asked == ["fix the vault tests"])
    }

    /// Stop all from the menu while hands-free words wait: their reply only shows, and VoiceOver reads
    /// it; the next press hides it and cuts VoiceOver off.
    @Test func stopAllFromTheMenuEndsHandsFree() async throws {
        try await askHandsFree("fix the vault tests")
        island.stopAll()
        island.replied("On it.", spoken: true)
        #expect(island.model.turn == .replied && island.model.voice.phase == .idle && !island.talkKey.busy)
        #expect(out.announced == ["On it."])
        tap()
        #expect(island.model.turn == nil && island.model.reply == nil && out.announced == ["On it.", " "])
        try await until { !out.posted.isEmpty }
        #expect(out.posted == ["Nothing is running."])
    }

    /// Hands-free lasts until the next press: a short fn tap while Oby thinks ends it.
    @Test func aPressWhileOneThinksEndsHandsFree() async throws {
        try await askHandsFree("fix the vault tests")
        tap()
        island.replied("On it.", spoken: true)
        #expect(island.model.turn == .replied && island.model.voice.phase == .idle)
        tap()
    }

    /// Held-key words, then fn + Space with nothing said while they wait, and fn again: "Oby didn't
    /// catch that", and their reply never opens the microphone.
    @Test func anEmptyHandsFreeRoundDoesntListenForAnEarlierQuestion() async throws {
        try await askHolding("how are the vault tests")
        fn(down: true)
        _ = island.talkKey.handle(.keyDown, code: 49, flags: .maskSecondaryFn, repeating: false)
        fn(down: false)
        tap()
        try await until { !out.posted.isEmpty }
        #expect(out.posted == ["Oby didn't catch that"] && out.asked == ["how are the vault tests"])
        island.replied("They pass.", spoken: true)
        #expect(island.model.turn == .replied && island.model.voice.phase == .idle && out.announced == ["They pass."])
        tap()
    }

    /// The reply lands while fn is going down: that press is yours. The reply shows, VoiceOver stays
    /// quiet, your turn starts, and letting go sends it.
    @Test func aReplyDuringAPressLeavesItToYou() async throws {
        try await askHandsFree("fix the vault tests")
        out.words.append("the web one")
        fn(down: true)
        island.replied("Which repository?", spoken: true)
        #expect(island.model.turn == .replied && out.announced.isEmpty)
        try await until { island.model.voice.phase == .listening }
        #expect(island.model.turn == .listening && island.model.reply == "Which repository?")
        fn(down: false)
        try await until { out.asked.count == 2 }
        #expect(out.asked.last == "the web one" && island.model.turn == .thinking && !island.talkKey.busy)
        tap()
    }

    /// A blank reply ends the turn: no empty pill, nothing listens again.
    @Test func aBlankReplyEndsTheTurn() async throws {
        try await askHandsFree("fix the vault tests")
        island.replied(" \n", spoken: true)
        #expect(island.model.turn == nil && island.model.reply == nil && island.model.voice.phase == .idle)
        #expect(out.announced.isEmpty)
    }
}
