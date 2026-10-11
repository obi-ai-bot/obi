import SwiftUI
import Testing
import UIKit
@testable import Oby

/// Long text reads like Claude's on the iPhone too (#154): Dynamic Type's body, lines 1.5 × apart.
struct ReadingTests {
    @Test func theIPhoneReadsDynamicTypesBody() {
        #expect(Reading.current.style == .body)
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        #expect(body.pointSize == Reading.phone.size)
    }

    @Test func linesSitOneAndAHalfTimesTheSizeApart() {
        let reading = Reading.phone
        let font = UIFont.systemFont(ofSize: reading.size)
        #expect(abs((font.lineHeight + reading.lineSpacing) / reading.size - Reading.lineHeight) < 0.05)
        #expect(reading.paragraphGap == 10)
    }

    @Test func codeIsThirteenSixteenthsOfProse() {
        #expect(Reading.phone.codeRatio == 13.0 / 16)
        #expect(abs(Reading.phone.size * Reading.phone.codeRatio - 13.81) < 0.01)
    }
}
