import AppKit
import SwiftUI
import Testing
@testable import Oby

/// Settings › Sharing as a picture, against Sangam's design (#808): off unless `OBY_SCREENS` names a
/// folder (`TEST_RUNNER_OBY_SCREENS=… xcodebuild test -only-testing:MacTests/SharingScreens`).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OBY_SCREENS"] != nil))
struct SharingScreens {
    @Test func settingsSharing() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OBY_SCREENS"] ?? NSTemporaryDirectory())
        var settings = RunnerSharingMac.Settings.off
        settings.on = true
        let mac = RunnerSharingMac(settings: settings, ready: true, jobs: [
            .init(correlationId: "c-1", fromOwner: "sangam", title: "Fix the login retry", repo: "deskree-inc/tetrix-ee", agent: "claude",
                  started: .now.addingTimeInterval(-12 * 60), state: "running"),
        ])
        for (name, value) in [("sharing-off", RunnerSharingMac(settings: .off, ready: true, jobs: [])), ("sharing-on", mac)] {
            let page = SharingSettingsView(feed: RunnerFeed(), mac: value)
                .frame(width: 560).padding(24).background(OBYStyle.window).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: page)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try data.write(to: folder.appending(path: "\(name).png"))
        }
    }
}
