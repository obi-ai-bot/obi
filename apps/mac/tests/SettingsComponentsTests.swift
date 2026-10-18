import SwiftUI
import Testing
@testable import Oby

/// Sangam's Settings building blocks (apps/shared/SettingsComponents.swift, from design/app's
/// app.css `.set-*`): each one's colours in each state, and its size as drawn.
@MainActor
struct SettingsComponentsTests {
    /// What `view` measures, drawn on its own.
    func size(_ view: some View, width: CGFloat? = nil) -> CGSize {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 1
        return renderer.nsImage?.size ?? .zero
    }

    // MARK: Switch

    @Test func switchIsWhiteFourteenPercentOffAndInkOn() {
        #expect(SetSwitch.track(on: false) == Color.white.opacity(0.14))
        #expect(SetSwitch.knob(on: false) == Tokens.text)
        #expect(SetSwitch.knobX(on: false) == 2)
        #expect(SetSwitch.track(on: true) == Tokens.ink)
        #expect(SetSwitch.knob(on: true) == Tokens.bg)
        // 2 in from the left, then across by 14: the knob ends 2 in from the right.
        #expect(SetSwitch.knobX(on: true) == 16)
    }

    @Test func switchIsThirtyTwoByEighteen() {
        let off = size(Toggle("Open at login", isOn: .constant(false)).toggleStyle(.set))
        let on = size(Toggle("Open at login", isOn: .constant(true)).toggleStyle(.set))
        #expect(off == CGSize(width: 32, height: 18))
        #expect(on == off)
    }

    /// A Toggle with the switch's style draws a Button, not a shape with a tap: Full Keyboard Access
    /// focuses it and Space toggles it.
    @Test func switchIsAButton() {
        #expect(String(reflecting: SetSwitch.Knob.Body.self).contains("Button"))
    }

    // MARK: Meter

    @Test func meterTurnsYellowPastEightyAndRedPastNinety() {
        #expect(SetMeter.fill(used: 0) == Tokens.text)
        #expect(SetMeter.fill(used: 80) == Tokens.text)
        #expect(SetMeter.fill(used: 81) == Tokens.full)
        #expect(SetMeter.fill(used: 90) == Tokens.full)
        #expect(SetMeter.fill(used: 91) == Tokens.over)
        #expect(SetMeter.fill(used: 140) == Tokens.over)
    }

    @Test func meterFillsItsShareAndNoMore() {
        #expect(SetMeter.fraction(used: 36) == 0.36)
        #expect(SetMeter.fraction(used: -4) == 0)
        #expect(SetMeter.fraction(used: 130) == 1)
    }

    @Test func meterIsFourTallAndAtMostTwoHundredEightyWide() {
        #expect(size(SetMeter(used: 50), width: 400) == CGSize(width: 400, height: 4))
        #expect(size(SetMeter(used: 50).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 1000), width: 1000).height == 4)
        #expect(SetMeter.maxWidth == 280)
    }

    // MARK: Buttons

    @Test func buttonIsInkAndDangerForWhatTakesSomethingAway() {
        #expect(SetButtonStyle.text(destructive: false) == Tokens.ink)
        #expect(SetButtonStyle.text(destructive: true) == Tokens.danger)
        #expect(SetButtonStyle.fill(hovered: false) == Tokens.chipHover)
        #expect(SetButtonStyle.fill(hovered: true) == Color(hex: 0x29292C))
        #expect(SetButtonStyle.edge(hovered: false) == Tokens.line)
        #expect(SetButtonStyle.edge(hovered: true) == Tokens.lineStrong)
        #expect(SetButtonStyle.opacity(enabled: true) == 1)
        #expect(SetButtonStyle.opacity(enabled: false) == 0.3)
    }

    @Test func buttonIsThirtyTwoTall() {
        #expect(size(Button("Remove", role: .destructive) {}.buttonStyle(.set)).height == 32)
        #expect(size(Button("Add Account") {}.buttonStyle(.set)).height == 32)
    }

    // MARK: Pop-up, segmented, field

    @Test func fieldsEdgeLightsUpHoveredOrFocused() {
        #expect(SetField.edge(hot: false) == Tokens.line)
        #expect(SetField.edge(hot: true) == Tokens.fieldEdgeOn)
    }

    @Test func popUpAndFieldAreThirtyTwoTall() {
        let select = SetSelect("Speech language", selection: .constant("system"), options: [("system", "Mac language"), ("en-US", "English")])
        #expect(size(select).height == 32)
        #expect(size(SetField("Name", text: .constant(""), prompt: "Personal")) == CGSize(width: SetField.width, height: 32))
        #expect(SetField.width == 220)
    }

    @Test func popUpShowsTheChosenOptionsName() {
        let options = [("system", "Mac language"), ("en-US", "English")]
        #expect(SetSelect.name(of: "en-US", in: options) == "English")
        // A value the options don't hold (a model the plan dropped) shows as itself.
        #expect(SetSelect.name(of: "gpt-old", in: options) == "gpt-old")
        // No value yet (a runner that hasn't said its default mode): a dash, never "nil".
        #expect(SetSelect<String?>.name(of: nil, in: [("ask", "Ask")]) == "—")
    }

    @Test func segmentedLightsTheOneThatsOn() {
        #expect(SetSegmented<Bool>.fill(on: true) == Color.white.opacity(0.12))
        #expect(SetSegmented<Bool>.fill(on: false) == .clear)
        #expect(SetSegmented<Bool>.text(on: true) == Tokens.ink)
        #expect(SetSegmented<Bool>.text(on: false) == Tokens.text)
        // 26 a segment, 2 around them and the line: 32, like the other controls.
        #expect(size(SetSegmented("Runner", selection: .constant(true), options: [(true, "This Mac"), (false, "Remote")])).height == 32)
    }

    // MARK: Card and row

    @Test func rowIsAtLeastFiftySixTall() {
        #expect(size(SetRow("Open at login"), width: 500).height == 56)
        // A line on it makes it taller, never shorter.
        let about = SetRow("Run merge checks on this Mac", about: String(repeating: "When Oby's review approves a pull request, this Mac runs its tests. ", count: 4)) {
            Toggle("Run merge checks on this Mac", isOn: .constant(true)).toggleStyle(.set)
        }
        #expect(size(about, width: 500).height > 56)
    }

    @Test func cardPutsADividerBetweenRowsOnly() {
        let one = size(SetGroup { SetRow("Open at login") }, width: 500).height
        let two = size(SetGroup { SetRow("Open at login"); SetRow("Status") }, width: 500).height
        // One row: the row and the card's edge. Two: one more row and one divider between them.
        #expect(one == 56 + 2 + SetGroup<EmptyView>.gap)
        #expect(two == one + 56 + 1)
    }

    @Test func groupHasItsHeadAndFootOnlyWhenGiven() {
        let bare = size(SetGroup { SetRow("Status") }, width: 500).height
        let titled = size(SetGroup("Runner") { SetRow("Status") }, width: 500).height
        let footed = size(SetGroup(footer: "Oby follows it on 127.0.0.1.") { SetRow("Status") }, width: 500).height
        #expect(titled > bare)
        #expect(footed > bare)
    }

    @Test func connectedHasItsGreenDot() {
        #expect(SetValue.dot == Color(hex: 0x30D158))
    }
}
