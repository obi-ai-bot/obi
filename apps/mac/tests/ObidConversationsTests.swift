import AppKit
import Foundation
import Testing
@testable import Oby

/// The window's conversations (#493) against a real obid: off unless `OBID_URL` and `OBID_HOME`
/// name a running obid and its home (`TEST_RUNNER_OBID_URL=http://127.0.0.1:7843
/// TEST_RUNNER_OBID_HOME=… xcodebuild test -only-testing:MacTests/ObidConversationsTests`), on a
/// scratch home and port, never the Mac's own runner. The app's ConversationList and Runner do every
/// call; what obid keeps is then read with a plain request, as the web app (apps/web) reads it, so
/// the two apps are shown the same list. With `OBY_SCREENS` set too, the window is pictured on it
/// (WindowScreens).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OBID_URL"] != nil))
struct ObidConversationsTests {
    let environment = ProcessInfo.processInfo.environment

    struct Listed: Decodable, Equatable { var id: String; var title: String; var pinned: Bool }

    /// obid's token from its home, as RunnerFeed reads it (never the keychain here).
    var token: String {
        get throws {
            let home = try #require(environment["OBID_HOME"])
            return try #require(LocalRunner.obidToken(in: URL(filePath: home)))
        }
    }

    var url: URL {
        get throws {
            let address = try #require(environment["OBID_URL"])
            return try #require(URL(string: address))
        }
    }

    /// `GET /v1/conversations` as the web app sends it (apps/web/src/api.ts), not through the Mac's client.
    func listed() async throws -> [Listed] {
        var request = URLRequest(url: try url.appending(path: "v1/conversations"))
        request.setValue("Bearer \(try token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return try JSONDecoder().decode([Listed].self, from: data)
    }

    func mac(_ list: ConversationList) -> [Listed] { list.items.map { Listed(id: $0.id, title: $0.title, pinned: $0.pinned) } }

    /// Words to Oby, as RunnerFeed.plan sends them: where ConversationList says, then joined.
    func say(_ words: String, list: ConversationList, runner: Runner) async throws -> String? {
        let planned = try await runner.planned(words, in: list.target())
        await list.joined(planned.conversation)
        return planned.conversation
    }

    @Test func homeTheConversationPageAndTheTalkKeyLandWhereTheyShould() async throws {
        let runner = Runner(base: try url, token: try token)
        let feed = RunnerFeed()
        let list = feed.conversations
        list.runner = { runner }
        feed.conversation.page = { before, limit in
            guard let id = list.shown else { return [] }
            return try await runner.conversation(id: id, before: before, limit: limit)
        }
        let before = try await listed()
        try await list.load(from: runner, planning: true)
        #expect(list.served && Set(mac(list).map(\.id)) == Set(before.map(\.id)))

        // Home's box: a conversation of its own, which the window then shows.
        list.startNew()
        let a = try #require(try await say("first question from Home", list: list, runner: runner))
        #expect(list.shown == a && !before.contains { $0.id == a })
        // Words on the conversation page carry on in it.
        #expect(try await say("and a follow-up", list: list, runner: runner) == a)
        // The app hears the follow-up as a `turn` event; with no event stream here, the thread reads it.
        await feed.conversation.reload()
        #expect(feed.conversation.runnerTurns.filter { $0.who == .user }.map(\.text) == ["first question from Home", "and a follow-up"])

        // Home again: another one.
        list.startNew()
        let b = try #require(try await say("second question from Home", list: list, runner: runner))
        #expect(b != a && list.shown == b)

        // The window goes back to the first; the talk key, said away from that page, goes to the
        // latest (#507: no `conversation`), and the window stays on the first.
        await list.open(a)
        list.nextToLatest = true
        #expect(try await say("spoken with the window closed", list: list, runner: runner) == b)
        #expect(list.shown == a)

        // Rename and pin the first, delete the second: obid keeps what the Mac did, and the list the
        // web app reads is the Mac's. (The app's list hears new conversations as `conversation`
        // events; here it reads them again, as on a reconnect.)
        try await list.load(from: runner, planning: true)
        #expect(Set(mac(list).map(\.id)) == Set(try await listed().map(\.id)) && list.shown == a)
        // obid may keep earlier runs' conversations: this run's title is its own.
        let renamed = "Renamed on the Mac \(UUID().uuidString.prefix(8))"
        await list.rename(a, to: renamed)
        await list.pin(a, true)
        await list.delete(b)
        #expect(list.problem == nil)
        try await list.load(from: runner, planning: true)
        let web = try await listed()
        #expect(web.first { $0.id == a } == Listed(id: a, title: renamed, pinned: true))
        #expect(!web.contains { $0.id == b })
        #expect(Set(mac(list).map(\.id)) == Set(web.map(\.id)))
        #expect(ConversationList.sections(list.items, matching: renamed.lowercased()).pinned.map(\.id) == [a])
        #expect(!ConversationList.sections(list.items, matching: "second question").recent.contains { $0.id == b })

        if let folder = environment["OBY_SCREENS"] { try await picture(feed: feed, folder: URL(fileURLWithPath: folder)) }
    }

    /// The window on obid's list, the side panel on Conversations and the conversation open.
    private func picture(feed: RunnerFeed, folder: URL) async throws {
        let model = IslandModel(desk: Desk(), feed: feed, availability: MacAvailability())
        let state = ChatState()
        state.trail.start(.talk)
        state.section = .conversations
        let defaults = UserDefaults.standard
        let open = defaults.object(forKey: "ObySidebarOpen")
        defer { if let open { defaults.set(open, forKey: "ObySidebarOpen") } else { defaults.removeObject(forKey: "ObySidebarOpen") } }
        defaults.set(true, forKey: "ObySidebarOpen")
        let window = ChatWindow.make(ChatView(model: model, state: state, character: ObyCharacter(query: "embed&size=1.23")))
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
        defer { window.close() }
        ChatWindow.measureLights(window, into: state)
        try await Task.sleep(for: .milliseconds(1500))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "mac-conversations-obid.png")
        let list = folder.appending(path: "windows.txt")
        let line = Data("mac-conversations-obid \(window.windowNumber)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: list) { handle.seekToEndOfFile(); handle.write(line); try handle.close() }
        else { try line.write(to: list) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(200)) }
        #expect(FileManager.default.fileExists(atPath: file.path), "screencapture made no picture")
    }
}
