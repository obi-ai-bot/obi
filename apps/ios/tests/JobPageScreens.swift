import SwiftUI
import Testing
@testable import Oby

/// Pictures of the iPhone's job page in each of the canvas's six states, light and dark, for a pull
/// request against the canvas's BP boards: off unless `OBY_SCREENS` names a folder
/// (`TEST_RUNNER_OBY_SCREENS=… xcodebuild test -only-testing:iOSTests/JobPageScreens`).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OBY_SCREENS"] != nil))
struct JobPageScreens {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OBY_SCREENS"] ?? NSTemporaryDirectory())

    @Test(arguments: JobPageFixture.allCases)
    func page(_ fixture: JobPageFixture) throws {
        for scheme in [ColorScheme.dark, .light] {
            let renderer = ImageRenderer(content: JobPagePreview(fixture: fixture, scrolls: false).frame(width: 402, height: 1500, alignment: .top)
                .environment(\.colorScheme, scheme))
            renderer.scale = 2
            let png = try #require(renderer.uiImage?.pngData())
            try png.write(to: folder.appending(path: "phone-\(fixture.rawValue)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
