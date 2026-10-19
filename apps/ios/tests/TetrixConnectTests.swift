import Foundation
import Testing
@testable import Oby

/// What the iPhone shows of the Mac's Tetrix: its jobs' Tetrix report, kept across the phone's own
/// copies, and a job whose report it can't read still decodes.
struct TetrixConnectTests {
    @Test func jobCarriesItsTetrixReport() throws {
        let done = try #require(SampleTasks.jobs.first { $0.id == "sample-done" })
        let report = try #require(done.tetrix)
        #expect(report.saved == ["ses_8f2a"] && report.context == true)
        #expect(report.gaps?.lines == ["No results: deskree-inc/oby#412", "A file it didn't know: apps/ios/app/SettingsScreen.swift"])
        #expect(SampleTasks.jobs.first { $0.id == "sample-run" }?.tetrix == nil)

        let odd = #"{"id": "j", "request": "r", "agent": "claude", "account": "a", "repo": "o/r", "branch": "b", "kind": "fix", "task": "t", "status": "done", "step": "", "summary": "", "created": "2026-10-18T10:00:00Z", "tetrix": {"calls": "many", "gaps": 3}}"#
        #expect(try Runner.decoder.decode(Job.self, from: Data(odd.utf8)).tetrix == TetrixJobReport())
        // Not an object at all: the job, and so the list, still decodes.
        let text = odd.replacingOccurrences(of: #"{"calls": "many", "gaps": 3}"#, with: #""not an object""#)
        #expect(try Runner.decoder.decode([Job].self, from: Data("[\(text)]".utf8)).first?.tetrix == TetrixJobReport())
        #expect(try Runner.decoder.decode(Job.self, from: Runner.encoder.encode(done)).tetrix == report)
    }

    @Test func accountsSayHowMuchTheirJobsUsedIt() throws {
        let personal = try #require(SampleTasks.accounts.first)
        #expect(TetrixJobReport.accountLine(connected: personal.tetrix == true, jobs: personal.tetrixJobs ?? 0, used: personal.tetrixUsed ?? 0,
                                            there: "on your Mac") == "Tetrix: used in 9 of 12 jobs")
    }
}
