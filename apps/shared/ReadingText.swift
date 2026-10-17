import Foundation
import SwiftUI

/// How Oby sets long text on every app (#154): Apple's SF Pro with Claude's spacing. Claude's
/// desktop app sets prose at 16 px with lines 1.5 × the size apart, code at 13 px (0.8125 ×) in the
/// system monospace, and a column about 70 characters wide. Most of the comfort is that spacing, so
/// the Mac, the iPhone and the Watch take the same numbers from here.
nonisolated struct Reading: Sendable {
    /// Prose size in points; where it scales with Dynamic Type (`style`), its size at the default setting.
    var size: CGFloat
    /// The Dynamic Type style it scales with, or nil for a fixed size (the Mac).
    var style: Font.TextStyle?
    /// Added between lines, at the default text size.
    var lineSpacing: CGFloat
    /// Between paragraphs, at the default text size.
    var paragraphGap: CGFloat
    /// Code's size against prose's.
    var codeRatio: CGFloat
    /// The widest prose gets, in points.
    var column: CGFloat

    /// Claude's line height, as a multiple of the size.
    static let lineHeight: CGFloat = 1.5
    /// SF Pro's own line height, ascender to descender (1.19 × the size): what `lineSpacing` adds to.
    static let fontLineHeight: CGFloat = 1.19
    /// Claude's 13 px code under 16 px prose.
    static let codeRatio: CGFloat = 0.8125

    /// What to add to SF Pro's own line height so lines sit `lineHeight` × `size` apart.
    static func lineSpacing(for size: CGFloat) -> CGFloat { size * (lineHeight - fontLineHeight) }

    /// The Mac reads small: 15 pt, in a column of about 640 pt.
    static let mac = Reading(size: 15, style: nil, lineSpacing: lineSpacing(for: 15), paragraphGap: 10, codeRatio: codeRatio, column: 640)
    /// Dynamic Type's body (17 pt at the default setting), spaced as the Mac's.
    static let phone = Reading(size: 17, style: .body, lineSpacing: lineSpacing(for: 17), paragraphGap: 10, codeRatio: codeRatio, column: .infinity)
    /// The Watch keeps its footnote (about 14 pt, set by watchOS) with a little more air; code is as big as prose.
    static let watch = Reading(size: 14, style: .footnote, lineSpacing: 2.5, paragraphGap: 6, codeRatio: 1, column: .infinity)

    #if os(macOS)
    static let current = mac
    #elseif os(watchOS)
    static let current = watch
    #else
    static let current = phone
    #endif

    /// Prose's font: Dynamic Type's style, or the fixed size.
    var prose: Font { style.map { Font.system($0) } ?? .system(size: size) }

    /// SF Mono at `codeRatio` × prose, `scale` being Dynamic Type's against the default setting.
    func code(scale: CGFloat) -> Font {
        if let style, codeRatio == 1 { return .system(style, design: .monospaced) }
        return .system(size: size * codeRatio * (style == nil ? 1 : scale), design: .monospaced)
    }

    /// Prose as Markdown's inline syntax reads it (`code`, *emphasis*, links), with its code in `code`.
    /// Lists and headings stay as typed.
    static func markdown(_ text: String, code: Font) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var string = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in string.runs where run.inlinePresentationIntent?.contains(.code) == true {
            string[run.range].font = code
        }
        return string
    }

    /// The paragraphs of `text`: what blank lines separate.
    static func paragraphs(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) + [Substring()] {
            if line.allSatisfy(\.isWhitespace) {
                if !lines.isEmpty { paragraphs.append(lines.joined(separator: "\n")) }
                lines = []
            } else {
                lines.append(line)
            }
        }
        return paragraphs
    }
}

/// Long prose (a question, a report, what you asked): paragraphs a gap apart, inline code in SF
/// Mono, in the reading column. Titles and short labels keep their own fonts.
struct ReadingText: View {
    let text: String
    var secondary: Bool
    var weight: Font.Weight?
    /// How its paragraphs line up: leading, or centered where the screen centers its text.
    var alignment: HorizontalAlignment
    /// A colour of its own, where the surface isn't the usual one (the Mac window's light bubble).
    var color: Color?
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    init(_ text: String, secondary: Bool = false, weight: Font.Weight? = nil, alignment: HorizontalAlignment = .leading, color: Color? = nil) {
        self.text = text
        self.secondary = secondary
        self.weight = weight
        self.alignment = alignment
        self.color = color
    }

    var body: some View {
        let reading = Reading.current
        let code = reading.code(scale: scale)
        Column(width: reading.column) {
            VStack(alignment: alignment, spacing: reading.paragraphGap * (reading.style == nil ? 1 : scale)) {
                ForEach(Array(Reading.paragraphs(text).enumerated()), id: \.offset) { _, paragraph in
                    Text(Reading.markdown(paragraph, code: code)).fontWeight(weight).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .modifier(ReadingStyle(role: secondary ? .secondary : .prose, color: color))
    }
}

/// No wider than the reading column, and no wider than its text either: a bubble or a button
/// around it keeps hugging its words.
private struct Column: Layout {
    let width: CGFloat

    private func proposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        let wide = proposal.width.map { min($0, width) } ?? (width.isFinite ? width : nil)
        return ProposedViewSize(width: wide, height: proposal.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(self.proposal(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: self.proposal(ProposedViewSize(bounds.size)))
    }
}

extension View {
    /// Prose: the reading size and line spacing, in the primary colour.
    func readingText() -> some View { modifier(ReadingStyle(role: .prose)) }
    /// Paths, commands and identifiers: SF Mono at the code size.
    func readingCode() -> some View { modifier(ReadingStyle(role: .code)) }
    /// A supporting line under prose: the reading size and spacing, in the secondary colour.
    func readingSecondary() -> some View { modifier(ReadingStyle(role: .secondary)) }
}

private struct ReadingStyle: ViewModifier {
    enum Role { case prose, code, secondary }
    let role: Role
    var color: Color? = nil
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        let reading = Reading.current
        let scale = reading.style == nil ? 1 : scale
        content
            .font(role == .code ? reading.code(scale: scale) : reading.prose)
            .lineSpacing(reading.lineSpacing * scale)
            .foregroundStyle(color ?? (role == .secondary ? Self.secondary : Self.primary))
    }

    #if os(macOS)
    // The Mac's window is always dark.
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.6)
    #else
    static let primary = Color.primary
    static let secondary = Color.secondary
    #endif
}
