import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Oby

/// The window in Sangam's design (#11, #270): its tokens are tokens.css's, its pages open over
/// Home as a trail, the side panel's edge rubber-bands, Home says what's going on, and the message
/// box grows with its text.
@MainActor
struct WindowTests {
    // MARK: Tokens

    /// The splash stays up until Oby has drawn, and never longer than its cap. A ready character still waits two seconds.
    @Test func theSplashStaysUntilObyIsDrawn() {
        #expect(!SplashGate.open(elapsed: 0, ready: true))
        #expect(!SplashGate.open(elapsed: SplashGate.least - 0.01, ready: true))
        #expect(SplashGate.open(elapsed: SplashGate.least, ready: true))
        #expect(!SplashGate.open(elapsed: SplashGate.most - 0.01, ready: false))
        #expect(SplashGate.open(elapsed: SplashGate.most, ready: false))
    }

    /// Every colour tokens.css names has its twin in Tokens.swift, the same value.
    @Test func tokensAreTokensCSS() throws {
        let css = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appending(path: "../../../design/app/src/renderer/src/tokens.css").standardizedFileURL, encoding: .utf8)
        let twins: [(String, Color)] = [
            ("bg", Tokens.bg), ("ink", Tokens.ink), ("text", Tokens.text), ("muted", Tokens.muted),
            ("label", Tokens.label), ("item", Tokens.item), ("line", Tokens.line), ("line-strong", Tokens.lineStrong),
            ("line-focus", Tokens.lineFocus), ("divider", Tokens.divider), ("hover", Tokens.hover), ("active", Tokens.active),
            ("chip", Tokens.chip), ("chip-hover", Tokens.chipHover), ("danger", Tokens.danger), ("unread", Tokens.unread),
            ("needs", Tokens.needs), ("full", Tokens.full), ("over", Tokens.over), ("surface", Tokens.surface),
            ("surface-edge", Tokens.surfaceEdge), ("field", Tokens.field), ("field-edge-on", Tokens.fieldEdgeOn),
        ]
        for (name, color) in twins {
            let value = try #require(Self.cssValue(name, in: css), "tokens.css has no --\(name)")
            let expected = try #require(Self.rgba(value), "can't read --\(name): \(value)")
            let actual = try #require(NSColor(color).usingColorSpace(.sRGB))
            let got = [actual.redComponent, actual.greenComponent, actual.blueComponent, actual.alphaComponent]
            #expect(zip(got, expected).allSatisfy { abs($0 - $1) < 0.002 }, "--\(name) is \(value), Tokens has \(got)")
        }
        #expect(Self.cssValue("sidebar", in: css) == "\(Int(Tokens.sidebar))px")
        #expect(Self.cssValue("rail", in: css) == "\(Int(Tokens.rail))px")
        #expect(Self.cssValue("view-min", in: css) == "\(Int(Tokens.viewMin))px")
        #expect(Self.cssValue("text-base", in: css) == "\(Int(Tokens.textBase))px")
        #expect(Self.cssValue("text-title", in: css) == "\(Int(Tokens.textTitle))px")
        #expect(Self.cssValue("composer-line", in: css) == "\(Int(Tokens.composerLine))px")
    }

    private static func cssValue(_ name: String, in css: String) -> String? {
        guard let start = css.range(of: "--\(name):") else { return nil }
        let rest = css[start.upperBound...]
        return rest.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
    }

    private static func rgba(_ value: String) -> [CGFloat]? {
        if value.hasPrefix("#"), let hex = UInt32(value.dropFirst(), radix: 16) {
            return [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, 1]
        }
        guard value.hasPrefix("rgba(") else { return nil }
        let parts = value.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { return nil }
        return [CGFloat(parts[0] / 255), CGFloat(parts[1] / 255), CGFloat(parts[2] / 255), CGFloat(parts[3])]
    }

    // MARK: The trail

    /// Each page opens over the one before; opening one already in the trail goes back to it; a
    /// fresh start replaces what was open; Esc goes back one, the chevron Home.
    @Test func pagesOpenOverEachOtherAsATrail() {
        var trail = WindowTrail()
        #expect(trail.isHome && trail.top == nil)
        trail.start(.group(.review))
        trail.push(.job(id: "a", local: false))
        trail.push(.talk)
        #expect(trail.steps == [.group(.review), .job(id: "a", local: false), .talk])
        // A task and its conversation go back and forth rather than piling up.
        trail.push(.job(id: "a", local: false))
        #expect(trail.steps == [.group(.review), .job(id: "a", local: false)])
        trail.back()
        #expect(trail.steps == [.group(.review)])
        trail.push(.job(id: "b", local: true))
        trail.back(to: 0)
        #expect(trail.steps == [.group(.review)])
        trail.start(.job(id: "c", local: true), .talk)
        #expect(trail.steps == [.job(id: "c", local: true), .talk])
        trail.closeAll()
        #expect(trail.isHome)
        trail.back()
        #expect(trail.isHome)
    }

    /// A job that left every list takes its page with it, and what was over it; the side panel
    /// lights the job whose page shows, or whose conversation was opened from it.
    @Test func aGoneJobsPageLeavesAndTheRightRowIsLit() {
        var trail = WindowTrail()
        trail.start(.group(.issues), .job(id: "gone", local: false), .talk)
        #expect(trail.shows(job: "gone", local: false))
        #expect(!trail.shows(job: "gone", local: true))
        trail.drop { $0 == .job(id: "gone", local: false) }
        #expect(trail.steps == [.group(.issues)])
        trail.drop { $0 == .group(.review) }
        #expect(trail.steps == [.group(.issues)])
        #expect(!trail.shows(job: "gone", local: false))
    }

    /// "Go to conversation" shows on a task's page only when a turn started it.
    @Test func onlyJobsTheConversationStartedGoBackToIt() {
        let turns = [Turn(id: "1", date: .now, who: .user, text: "fix it"),
                     Turn(id: "2", date: .now, who: .oby, text: "On it.", jobs: ["j1"])]
        #expect(ConversationModel.started("j1", in: turns))
        #expect(!ConversationModel.started("j2", in: turns))
    }

    // MARK: The side panel

    /// Dragged past its limits the panel gives less and less; let go, it settles within them.
    @Test func thePanelsEdgeRubberBands() {
        #expect(PanelWidth.dragging(300) == 300)
        let far = PanelWidth.dragging(Tokens.sidebarMax + 500)
        #expect(far > Tokens.sidebarMax && far < Tokens.sidebarMax + PanelWidth.stretch)
        #expect(PanelWidth.dragging(Tokens.sidebarMax + 40) - Tokens.sidebarMax < 40)
        let near = PanelWidth.dragging(0)
        #expect(near < Tokens.sidebarMin && near > Tokens.sidebarMin - PanelWidth.stretch)
        #expect(PanelWidth.settled(Tokens.sidebarMax + 500) == Tokens.sidebarMax)
        #expect(PanelWidth.settled(10) == Tokens.sidebarMin)
        #expect(PanelWidth.settled(300.4) == 300)
    }

    // MARK: Home

    /// What Home says over its chips, from the same tasks the side panel groups (#496).
    @Test func homeSaysWhatsRunningAndWhatNeedsYou() {
        #expect(HomeLine.attention(running: 5, needs: 4) == "5 running tasks · 4 need you")
        #expect(HomeLine.attention(running: 1, needs: 0) == "1 running task · nothing needs you")
        #expect(HomeLine.attention(running: 0, needs: 1) == "1 needs you")
        #expect(HomeLine.attention(running: 0, needs: 0) == "All quiet. Give me something to work on")
        #expect(HomeLine.placeholder(fullName: "Wellington Prado") == "What do you want me to work on, Wellington?")
        #expect(HomeLine.placeholder(fullName: "") == "What do you want me to work on?")

        let now = Date.now
        func job(_ id: String, _ status: Job.Status, question: Bool = false) -> Job {
            var job = Job(id: id, request: "r", agent: "claude", account: "a", repo: "deskree-inc/oby", branch: "b", base: "dev",
                          pr: nil, kind: .build, task: "t", created: now - 60)
            job.status = status
            if question { job.question = Plan.Question(text: "Which?", options: []) }
            return job
        }
        let work = SidebarSections.work(local: [job("r", .running), job("q", .queued), job("n", .running, question: true), job("d", .done)],
                                        runner: [], since: .distantFuture, seen: [])
        #expect(HomeLine.attention(running: work.count { $0.status == .running }, needs: work.count { $0.status == .needs })
            == "2 running tasks · 1 needs you")
    }

    // MARK: The message box

    /// One line sits on the row, 46 points tall, the text in its middle; past a line it stacks,
    /// growing a line at a time up to half the window, then scrolls; emptied after sending, it's
    /// one row again.
    @Test func theMessageBoxGrowsWithItsText() {
        #expect(BoxMetrics.rowHeight == 46)
        #expect(BoxMetrics.textInset * 2 + BoxMetrics.lineHeight == BoxMetrics.rowHeight)
        let width: CGFloat = 480, half: CGFloat = 335
        #expect(!BoxMetrics.stacked("fix the flaky test", width: width))
        #expect(BoxMetrics.height("fix the flaky test", width: width, maximum: half) == 46)
        #expect(BoxMetrics.stacked("one\ntwo", width: width))
        let two = BoxMetrics.height("one\ntwo", width: width, maximum: half)
        let three = BoxMetrics.height("one\ntwo\nthree", width: width, maximum: half)
        #expect(two > 46 && three - two == BoxMetrics.lineHeight)
        // Wrapping counts as lines too, not only Return.
        #expect(BoxMetrics.stacked(String(repeating: "long words ", count: 12), width: width))
        let tall = String(repeating: "line\n", count: 60)
        #expect(BoxMetrics.height(tall, width: width, maximum: half) <= half)
        #expect(BoxMetrics.height(tall, width: width, maximum: half) > half - BoxMetrics.lineHeight)
        #expect(BoxMetrics.height("", width: width, maximum: half) == 46)
    }
}
