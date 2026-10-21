import AppKit
import SwiftUI
import Testing
@testable import Oby

/// Settings › Sharing as a picture, against Sangam's design (#808, #809): off unless `OBY_SCREENS` names a
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
        // Share your usage and Kept for you (#809): Deskree's API account shared with Sangam, 9% of 30% used.
        let grants = RunnerGrants(
            grants: [.init(id: "g-0123456789ab", label: "Deskree API", account: "deskree", who: "sangam", share: 30, extra: 0, budgetCents: 40000,
                           resetsDay: 1, resets: .now.addingTimeInterval(9 * 86400), limitCents: 12000, usedCents: ["sangam": 3600])],
            accounts: [.init(id: "deskree", agent: "claude", name: "Deskree API", plan: "api", why: nil),
                       .init(id: "personal", agent: "claude", name: "Personal", plan: "personal",
                             why: "A personal plan is for you alone: its terms don’t let anyone else’s work run on it.")],
            key: true)
        for (name, value) in [("sharing-off", RunnerSharingMac(settings: .off, ready: true, jobs: [])), ("sharing-on", mac)] {
            let page = SharingSettingsView(feed: RunnerFeed(), mac: value, grants: value.settings.on ? grants : nil)
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
