import AppKit
import SwiftUI
import Testing
@testable import Oby

/// Long text reads like Claude's (#154): SF Pro with Claude's spacing, the same numbers on every app.
struct ReadingTests {
    /// SF Pro at `size`, with `reading`'s line spacing: how far apart its lines sit, against the size.
    private func lineHeight(_ reading: Reading, size: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size)
        return (font.ascender - font.descender + font.leading + reading.lineSpacing) / size
    }

    @Test func theMacSetsProseAt15PointsWithLinesOneAndAHalfApart() {
        let reading = Reading.mac
        #expect(reading.size == 15)
        #expect(reading.style == nil)
        #expect(abs(lineHeight(reading, size: reading.size) - Reading.lineHeight) < 0.05)
        #expect(reading.paragraphGap == 10)
        #expect(reading.column == 640)
    }

    @Test func sfProsOwnLineHeightIsWhatTheSpacingAddsTo() {
        let font = NSFont.systemFont(ofSize: 15)
        #expect(abs((font.ascender - font.descender + font.leading) / 15 - Reading.fontLineHeight) < 0.02)
    }

    @Test func codeIsSFMonoAtThirteenSixteenthsOfProse() {
        #expect(Reading.codeRatio == 13.0 / 16)
        #expect(Reading.mac.codeRatio == Reading.codeRatio)
        #expect(Reading.phone.codeRatio == Reading.codeRatio)
        #expect(abs(Reading.mac.size * Reading.mac.codeRatio - 12.19) < 0.01)
    }

    @Test func theIPhoneSpacesLinesAsTheMacDoesAndTheWatchKeepsItsSizes() {
        #expect(Reading.phone.size == 17)
        #expect(Reading.phone.style == .body)
        #expect(abs(Reading.phone.lineSpacing / Reading.phone.size - Reading.mac.lineSpacing / Reading.mac.size) < 0.001)
        #expect(Reading.phone.paragraphGap == Reading.mac.paragraphGap)
        #expect(Reading.watch.style == .footnote)
        #expect((2...3).contains(Reading.watch.lineSpacing))
        #expect(Reading.watch.codeRatio == 1)
    }

    @Test func inlineCodeRendersInTheCodeFace() {
        let code = Font.system(size: 12, design: .monospaced)
        let string = Reading.markdown("Run `swift test` before **you** push.", code: code)
        #expect(String(string.characters) == "Run swift test before you push.")
        let coded = string.runs.filter { $0[AttributeScopes.SwiftUIAttributes.FontAttribute.self] == code }
        #expect(coded.map { String(string[$0.range].characters) } == ["swift test"])
    }

    @Test func listsStayAsTyped() {
        let string = Reading.markdown("- [x] One\n- [ ] Two", code: .body)
        #expect(String(string.characters) == "- [x] One\n- [ ] Two")
    }

    @Test func blankLinesSeparateParagraphs() {
        #expect(Reading.paragraphs("One\nstill one\n\n  \nTwo\n") == ["One\nstill one", "Two"])
        #expect(Reading.paragraphs("") == [])
    }
}
