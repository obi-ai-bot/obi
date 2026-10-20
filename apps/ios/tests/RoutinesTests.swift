import Foundation
import SwiftUI
import Testing
@testable import Oby

/// Routines on the iPhone (#395): a routine's run is a job with `routine`, under Routines on Home,
/// and Settings › Routines lists obid's routines.
@MainActor
struct RoutinesTests {
    let job = #"{"id": "9f08fd10", "request": "Review the open PRs", "agent": "claude", "account": "default", "repo": "obi-ai-bot/obi", "branch": "oby/review-9f08fd10", "kind": "review", "task": "Review the open PRs", "status": "running", "step": "Working", "summary": "", "created": "2026-10-19T12:00:20Z", "routine": {"id": "a1b2c3d4", "name": "Review open PRs", "scheduled": "2026-10-19T12:00:00Z", "catchUp": false}}"#

    @Test func aRoutinesRunGoesUnderRoutines() throws {
        let job = try Runner.decoder.decode(Job.self, from: Data(job.utf8))
        #expect(job.routine?.line == "From routine: Review open PRs")
        let items = PhoneWork.items([job], since: .distantPast, seen: [])
        #expect(items.map(\.type) == [.routines])
        #expect(WorkList.kinds(items).map(\.label) == ["Review PR", "Issues", "Tasks", "Routines"])
    }

    @Test func routinesDecodeAsObidListsThem() throws {
        let listed = #"[{"id": "a1b2c3d4", "name": "Review open PRs", "repo": "obi-ai-bot/obi", "kind": "review", "task": "Review them.", "agent": "auto", "account": "auto", "mode": null, "check": null, "rounds": 1, "schedule": {"every": "weekdays", "at": "09:00"}, "zone": "America/Sao_Paulo", "when": "Weekdays at 9:00", "enabled": false, "created": "2026-10-19T12:00:00Z", "createdBy": "chat", "conversation": null, "nextRun": null, "failuresInARow": 0, "lastRun": {"scheduled": "2026-10-19T12:00:00Z", "at": "2026-10-19T12:00:20Z", "outcome": "skipped", "reason": "The previous run was still going.", "job": null, "catchUp": false, "ended": null}}]"#
        let routines = try Runner.decoder.decode([RunnerRoutine].self, from: Data(listed.utf8))
        #expect(routines.first?.about() == "Weekdays at 9:00 · obi · Paused · Last run skipped")
    }

    /// With TEST_RUNNER_OBY_SNAPSHOTS set to a folder, Settings › Routines as the iPhone draws it.
    @Test func drawsTheSection() throws {
        guard let folder = ProcessInfo.processInfo.environment["OBY_SNAPSHOTS"] else { return }
        let iso = ISO8601DateFormatter()
        func routine(_ name: String, _ when: String, enabled: Bool, next: String?, last: String?, ended: String?) -> RunnerRoutine {
            RunnerRoutine(id: name, name: name, repo: "obi-ai-bot/obi", kind: "review", task: "", when: when, zone: "America/Sao_Paulo",
                          enabled: enabled, nextRun: next.flatMap(iso.date), failuresInARow: 0,
                          lastRun: last.map { .init(scheduled: .now, at: .now, outcome: $0, reason: nil, job: nil, catchUp: false, ended: ended) })
        }
        let routines = [routine("Review open PRs", "Weekdays at 9:00", enabled: true, next: "2026-10-20T12:00:00Z", last: "started", ended: "done"),
                        routine("Dependency updates", "Mondays at 9:00", enabled: true, next: "2026-10-26T12:00:00Z", last: "skipped", ended: nil),
                        routine("Weekly repo health", "Fridays at 17:00", enabled: false, next: nil, last: "started", ended: "failed")]
        let view = RoutinesSection(runner: nil, routines: routines)
            .environment(\.settingsCards, true)
            .padding(16).frame(width: 390).fixedSize(horizontal: false, vertical: true).background(Tokens.bg)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let png = try #require(renderer.uiImage?.pngData())
        try png.write(to: URL(fileURLWithPath: folder).appending(path: "iphone-settings-routines.png"))
    }
}
