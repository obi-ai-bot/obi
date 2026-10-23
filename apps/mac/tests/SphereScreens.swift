import AppKit
import SwiftUI
import Testing
@testable import Oby

/// Creating an Obysphere (the strip's +) as pictures, against Sangam's CreateSphereModal: off unless
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
