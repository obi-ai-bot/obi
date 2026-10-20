import Foundation
import SwiftUI
import Testing
@testable import Oby

/// Settings › Routines (#395): what each routine's row says under its name, from obid's list.
@MainActor
struct RoutinesTests {
    static let now = ISO8601DateFormatter().date(from: "2026-10-19T15:00:00Z")!

    static func routine(_ name: String, enabled: Bool = true, next: String? = "2026-10-20T12:00:00Z",
                        last: RunnerRoutine.Run? = nil) -> RunnerRoutine {
        RunnerRoutine(id: name.lowercased().filter(\.isLetter).prefix(8).description, name: name, repo: "obi-ai-bot/obi",
                      kind: "review", task: "Review the open pull requests.", when: "Weekdays at 9:00",
                      zone: "America/Sao_Paulo", enabled: enabled,
                      nextRun: next.flatMap { ISO8601DateFormatter().date(from: $0) }, failuresInARow: 0, lastRun: last)
    }

    static func run(_ outcome: String, ended: String? = nil) -> RunnerRoutine.Run {
        RunnerRoutine.Run(scheduled: now, at: now, outcome: outcome, reason: nil, job: "9f08fd10", catchUp: false, ended: ended)
    }

    @Test func aRowSaysWhenWhereNextAndHowTheLastRunWent() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let tomorrow = Self.routine("Review open PRs", last: Self.run("started", ended: "done"))
        #expect(tomorrow.about(now: Self.now).hasPrefix("Weekdays at 9:00 · obi · Next tomorrow at "))
        #expect(tomorrow.about(now: Self.now).hasSuffix(" · Last run done"))
        #expect(Self.routine("Paused one", enabled: false).about(now: Self.now) == "Weekdays at 9:00 · obi · Paused")
        #expect(Self.routine("Busy", last: Self.run("started")).about(now: Self.now).hasSuffix("Running now"))
        #expect(Self.routine("Skipped", last: Self.run("skipped")).about(now: Self.now).hasSuffix("Last run skipped"))
        #expect(RunnerRoutine.day(Self.now.addingTimeInterval(3 * 86_400), now: Self.now, calendar: calendar).hasPrefix("Thursday at "))
        #expect(RoutineMark(id: "a1b2c3d4", name: "Review open PRs").line == "From routine: Review open PRs")
    }

    /// Home's Routines page: each routine waiting for its next run, soonest first, says when it
    /// starts (Sangam's "Starts Monday at 9"); a paused one isn't waiting.
    @Test func upcomingRunsSayWhenTheyStart() {
        let later = Self.routine("Dependency updates", next: "2026-10-26T12:00:00Z")
        let sooner = Self.routine("Review open PRs")
        let paused = Self.routine("Weekly repo health", enabled: false, next: nil)
        #expect(RunnerRoutine.upcoming([later, paused, sooner]).map(\.name) == ["Review open PRs", "Dependency updates"])
        #expect(sooner.starts(now: Self.now)?.hasPrefix("Starts tomorrow at ") == true)
        #expect(paused.starts(now: Self.now) == nil)
    }

    @Test func aRoutinesRunGoesUnderRoutinesOnHome() throws {
        let json = #"[{"id":"a1","routine":{"id":"r1","name":"Review open PRs","scheduled":"2026-10-19T12:00:00Z","catchUp":false}},{"id":"a2"}]"#
        let extras = RunnerJobExtras.of(Data(json.utf8))
        #expect(extras["a1"]?.routine?.name == "Review open PRs")
        #expect(extras["a2"]?.routine == nil)
    }

    /// With TEST_RUNNER_OBY_SNAPSHOTS set to a folder, the section as Settings draws it, as a PNG.
    @Test func drawsTheSection() throws {
        guard let folder = ProcessInfo.processInfo.environment["OBY_SNAPSHOTS"] else { return }
        let routines = [Self.routine("Review open PRs", last: Self.run("started", ended: "done")),
                        Self.routine("Dependency updates", next: "2026-10-26T12:00:00Z", last: Self.run("skipped")),
                        Self.routine("Weekly repo health", enabled: false, last: Self.run("started", ended: "failed"))]
        let view = RoutinesSection(runner: nil, routines: routines)
            .environment(\.settingsCards, true)
            .padding(24).frame(width: 680).fixedSize(horizontal: false, vertical: true).background(Tokens.bg)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: folder).appending(path: "mac-settings-routines.png"))
    }
}
