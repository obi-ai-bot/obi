import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Oby

/// Pictures of the job page in each of the canvas's six states (JobPageFixture), for a pull request
/// against Sangam's design: off unless `OBY_SCREENS` names a folder
/// (`TEST_RUNNER_OBY_SCREENS=… xcodebuild test -only-testing:MacTests/JobPageScreens`). With
/// `OBY_LIVE` too, it also draws the pages of the real jobs on this Mac's obid, read as the app
/// reads them (its token stays in this process).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OBY_SCREENS"] != nil))
struct JobPageScreens {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OBY_SCREENS"] ?? NSTemporaryDirectory())

    @Test(arguments: JobPageFixture.allCases)
    func page(_ fixture: JobPageFixture) async throws {
        try await save(TaskPagePreview(fixture: fixture), as: "mac-\(fixture.rawValue)")
    }

    /// Sangam's sample session (#786), live.
    @Test func session() async throws {
        let session = LiveSession(job: "sample", load: { _ in TranscriptPage(entries: SessionFixture.entries()) }, loadDetail: { _ in SessionFixture.detail })
        await session.catchUp()
        try await save(SessionView(session: session, agent: "cursor", meta: "Cursor · Sonnet 5.5 · Deskree", live: true).background(Tokens.bg),
                       as: "mac-session")
    }

    /// One running, one done and one failed job from obid, if it has them.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OBY_LIVE"] != nil))
    func live() async throws {
        let token = try #require(LocalRunner.token())
        let runner = Runner(base: URL(string: "http://127.0.0.1:7777")!, token: token)
        let (jobs, extras) = try await runner.jobsWithExtras()
        var picked: [Job] = []
        for status in [Job.Status.running, .done, .failed] {
            if let job = jobs.first(where: { $0.status == status }) { picked.append(job) }
        }
        for job in picked {
            let actions = TaskActions(place: "This Mac", account: nil, extras: extras[job.id], accounts: [], stop: {}, message: { _ in },
                                      dismiss: {}, permission: { _, _ in }, mode: { _ in })
            try await save(TaskPage(job: job, actions: actions, tray: Tray()).frame(width: 700, height: 1480).background(Tokens.bg),
                           as: "live-\(job.status.rawValue)")
        }
    }

    private func save(_ page: some View, as name: String) async throws {
        let size = NSSize(width: 700, height: 1480)
        let view = NSHostingView(rootView: page.environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(600))
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: folder.appending(path: "\(name).png"))
        window.orderOut(nil)
    }
}
