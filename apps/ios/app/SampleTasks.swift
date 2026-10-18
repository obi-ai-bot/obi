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

    /// With `-ObySampleTalk <seconds>` too: the Oby thread opens with a question of yours, and that
    /// many seconds after launch Oby's answer comes, a word at a time, for a screenshot of it coming in.
    @MainActor static func talk(_ phone: Phone) {
        let delay = UserDefaults.standard.double(forKey: "ObySampleTalk")
        guard delay > 0 else { return }
        let model = phone.conversation
        phone.tab = .chat
        phone.chatPath = [.conversation(nil)]
        model.apply(Turn(id: "sample-ask", who: .user, text: "Where's the login screen task at?"))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            model.apply(Turn(id: "sample-answer", who: .oby, text: """
                Claude is on it in deskree-inc/oby: the empty state now says what to do next, and it's running \
                `swift test` before the review. Two of five stages are done, and nothing needs you yet. I'll tell \
                you when it opens the pull request, or sooner if it gets stuck on a check.
                """, jobs: ["sample-run"]))
        }
    }
}
#endif
