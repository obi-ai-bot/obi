import AppKit
import SwiftUI
import Testing
@testable import Oby

/// Creating an Obysphere (the strip's +) as pictures, against Sangam's CreateSphereModal, and Settings ›
/// Obysphere's Host your own and the Join screen an oby://join link opens: off unless
/// `OBY_SCREENS` names a folder (`TEST_RUNNER_OBY_SCREENS=… xcodebuild test -only-testing:MacTests/SphereScreens`).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OBY_SCREENS"] != nil))
struct SphereScreens {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OBY_SCREENS"] ?? NSTemporaryDirectory())

    @Test func createSheet() async throws {
        try await save(CreateSphereSheet(feed: RunnerFeed(), email: "doti@gmail.com", done: { _ in }, close: {}), as: "sphere-create-empty")
        try await save(CreateSphereSheet(feed: RunnerFeed(), name: "Deskree Platform", emails: ["ernesto@deskree.com", "sangam@deskree.com"],
                                         email: "doti@deskree.com", done: { _ in }, close: {}), as: "sphere-create-filled")
        try await save(CreateSphereSheet(feed: RunnerFeed(), name: "Deskree Platform", emails: ["ernesto@deskree.com", "not-an-email"],
                                         email: "doti@deskree.com", done: { _ in }, close: {}), as: "sphere-create-wrong-email")
    }

    /// The Join screen an oby://join link opened, with the trust question for a server Oby doesn't
    /// know (in the link's own words: nothing is asked of it yet); then Host your own once Deploy
    /// copied the token, and once an address is checked.
    @Test func anOpenedJoinLinkAndHostYourOwn() async throws {
        let obid = RunnerStub { request in
            request.path == "/v1/obid/sphere" ? (200, #"{"state": "none", "owner": "wellington"}"#) : (404, "{}")
        }
        let feed = RunnerFeed()
        feed.stageAlerts(following: obid.runner)
        OpenedInvite.shared.invite = InviteLink(opened: URL(string: "oby://join/obi-sphere.acme.workers.dev#sphere=acme&name=Acme&by=sangam&id=inv-1&secret=s")!)
        try await save(settings(SphereSettingsView(feed: feed)), as: "sphere-join-opened")
        let host = HostOwn.shared
        host.made = ("made", 0)
        defer { (host.made, host.address) = (nil, "") }
        try await save(settings(SphereSettingsView(feed: feed)), as: "sphere-host-your-own")
        // Checked, waiting for the owner to say it's theirs.
        host.address = "obi-sphere.acme.workers.dev"
        host.checked = URL(string: "https://obi-sphere.acme.workers.dev")
        try await save(settings(SphereSettingsView(feed: feed)), as: "sphere-host-your-own-confirm")
    }

    private func settings(_ page: some View) -> some View {
        page.environment(\.settingsCards, true).padding(24).frame(width: Tokens.column + 48).background(Tokens.bg)
    }

    private func save(_ page: some View, as name: String) async throws {
        let view = NSHostingView(rootView: page.environment(\.colorScheme, .dark))
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(2000))
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: folder.appending(path: "\(name).png"))
        window.orderOut(nil)
    }
}
