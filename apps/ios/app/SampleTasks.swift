#if DEBUG
import Foundation

/// Debug builds only: launched with `-ObySampleTasks YES`, Home shows three made-up tasks (one
/// running, one that needs you, one done), so a simulator with no runner jobs can show Sangam's
/// cards and pages. Nothing is sent: a runner's list, when one arrives, replaces them.
/// ponytail: fixed JSON, enough for screenshots; a preview catalog would replace it if one comes.
enum SampleTasks {
    static var on: Bool { UserDefaults.standard.bool(forKey: "ObySampleTasks") }

    static var jobs: [Job] {
        let now = Date.now
        func at(_ minutes: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutes * 60)) }
        let stages = { (states: [String]) in
            zip(["Plan", "Work", "Check", "Review", "Merge"], states).enumerated().map { index, pair in
                #"{"id": "s\#(index)", "title": "\#(pair.0)", "state": "\#(pair.1)"}"#
            }.joined(separator: ", ")
        }
        let list = [
            #"{"id": "sample-run", "request": "Make the login screen's empty state say what to do next", "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/fix-12", "base": "dev", "kind": "fix", "issue": 12, "title": "Login screen empty state", "task": "Fix #12", "status": "running", "step": "Running swift test", "summary": "", "created": "\#(at(12))", "started": "\#(at(12))", "rounds": 4, "round": 2, "check": "swift test", "pipeline": {"stages": [\#(stages(["done", "current", "upcoming", "upcoming", "upcoming"]))], "number": 2, "total": 5}}"#,
            #"{"id": "sample-needs", "request": "Review oby PR #33", "agent": "codex", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/review-33", "base": "dev", "kind": "review", "pr": 33, "title": "Review oby #33", "task": "Review #33", "status": "running", "step": "Waiting for your OK", "summary": "", "created": "\#(at(40))", "started": "\#(at(40))", "permission": {"id": "p1", "tool": "Bash", "title": "Run swift test", "detail": "swift test --filter RunnerTests", "rule": "Bash(swift test:*)"}, "pipeline": {"stages": [\#(stages(["done", "current", "upcoming", "upcoming", "skipped"]))], "number": 2, "total": 5}}"#,
            #"{"id": "sample-done", "request": "Add the About row to Settings", "agent": "claude", "account": "default", "repo": "deskree-inc/oby", "branch": "oby/about", "base": "dev", "kind": "build", "title": "Settings About row", "task": "Add About", "status": "done", "step": "", "summary": "Settings has an About section with the app's version and the runner it reaches.", "created": "\#(at(36))", "started": "\#(at(36))", "finished": "\#(at(2))", "commits": 2, "published": "https://github.com/deskree-inc/oby/pull/412", "pipeline": {"stages": [\#(stages(["done", "done", "done", "done", "done"]))], "number": 5, "total": 5}}"#,
        ]
        return list.compactMap { try? Runner.decoder.decode(Job.self, from: Data($0.utf8)) }
    }
}
#endif
