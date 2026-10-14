import AppKit
import CoreGraphics
import CoreText
import SwiftUI

/// Where everything sits inside the island in one state, worked out from the screen alone so tests
/// can check it. On a screen with a notch, no words ever sit beside or under the camera: the wings
/// hold Oby and the agent count, and text starts below the cutout (#150).
nonisolated struct IslandLayout {
    var size: CGSize
    var radius: CGFloat
    /// Oby, from the island's top-left corner.
    var character: CGRect
    /// The camera's cutout, from the island's top-left corner; nil on a screen without one.
    var notch: CGRect?
    /// The agents working, trailing in the right wing; nil when the state doesn't show it.
    var count: CGRect?
    /// "Oby" and the hover line.
    var line: CGRect?
    /// The hover line has a row of its own under the camera, centered, instead of following Oby's name.
    var lineBelow = false
    /// The hover line's lines: 1, or 2 when it doesn't fit in one (#191). Past the second, it's cut.
    var lines = 1
    /// The open or listening island's content, as padding from the island's edges.
    var insets: EdgeInsets?

    var content: CGRect? {
        insets.map {
            CGRect(x: $0.leading, y: $0.top, width: max(0, size.width - $0.leading - $0.trailing),
                   height: max(0, size.height - $0.top - $0.bottom))
        }
    }

    /// Every frame words are laid out in.
    var texts: [CGRect] { [count, line, content].compactMap { $0 } }

    /// How far each wing reaches past the notch when the island is closed.
    static let wing: CGFloat = 52
    /// The hover line's row under the camera.
    static let row: CGFloat = 20
    /// What a second line of the hover line adds to its row and to the island.
    static let lineHeight: CGFloat = 15
    /// The most lines the hover line wraps to.
    static let maxLines = 2
    /// The open island has no padding under its content: lists and Settings scroll to the island's
    /// bottom edge, and each keeps its own room under its last row (#322).
    static let openBottom: CGFloat = 0

    /// The space between "Oby" and the hover line, under the camera or beside Oby.
    static func gap(below: Bool) -> CGFloat { below ? 8 : 12 }

    /// - Parameters:
    ///   - screenWidth: the width of the screen the island is centered on.
    ///   - notch: the camera's cutout from the screen's top-left corner, or nil.
    ///   - barHeight: the menu bar's height, for the pill on a screen without a notch.
    ///   - line: what peeking shows next to Oby's name, measured for the lines it wraps to.
    ///   - openHeight: the open island's height, measured from its content.
    static func of(_ state: IslandState, screenWidth: CGFloat, notch: CGRect?, barHeight: CGFloat,
                   line: String, openHeight: CGFloat) -> IslandLayout {
        let top = notch?.height ?? barHeight
        let base = notch.map { $0.width + 2 * wing } ?? 180
        let size: CGSize
        switch state {
        case .compact: size = CGSize(width: base, height: top)
        // With a notch, the line drops to a row of its own under the camera.
        case .peek: size = CGSize(width: base + (line == Summary.quiet ? 140 : 320), height: top + (notch == nil ? 6 : 10 + row))
        case .open, .listening: size = CGSize(width: 600, height: openHeight)
        }
        let cutout = notch.map { $0.offsetBy(dx: -(screenWidth - size.width) / 2, dy: 0) }
        var layout: IslandLayout
        switch state {
        case .compact, .peek:
            layout = IslandLayout(size: size, radius: state == .compact ? 12 : 18,
                                  character: CGRect(x: 8, y: -3, width: top + 6, height: top + 6), notch: cutout)
        case .open, .listening:
            // Oby's body sits low in its frame (room to jump), so the frame starts under the notch.
            layout = IslandLayout(size: size, radius: 32, character: CGRect(x: 14, y: top - 14, width: 136, height: 136), notch: cutout)
        }
        // The right wing, past the camera, or past Oby on a screen without one.
        let wingStart = (cutout?.maxX ?? layout.character.maxX) + 4
        let rightWing = CGRect(x: wingStart, y: 0, width: max(0, size.width - 16 - wingStart), height: top)
        switch state {
        case .compact:
            layout.count = rightWing
        case .peek where cutout != nil:
            layout.count = rightWing
            layout.line = CGRect(x: layout.radius, y: top + 4, width: size.width - 2 * layout.radius, height: row)
            layout.lineBelow = true
        case .peek:
            let start = layout.character.maxX + 4
            layout.line = CGRect(x: start, y: 0, width: size.width - start - 14, height: size.height)
        case .open:
            layout.insets = EdgeInsets(top: top + 10, leading: 22, bottom: openBottom, trailing: 22)
        case .listening:
            layout.insets = EdgeInsets(top: top + 6, leading: layout.character.maxX + 12, bottom: 24, trailing: 28)
        }
        // A line too long for its row takes a second one, and the island grows by it.
        if let row = layout.line {
            let room = row.width - Self.width(of: "Oby", weight: .semibold) - gap(below: layout.lineBelow)
            layout.lines = min(maxLines, Self.lines(of: line, width: room))
            let extra = CGFloat(layout.lines - 1) * lineHeight
            layout.size.height += extra
            layout.line?.size.height += extra
        }
        return layout
    }

    /// The width of `text` in the hover row's 12-point system font, as Island.swift draws it.
    static func width(of text: String, weight: NSFont.Weight) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: weight)]).size().width)
    }

    /// How many lines the hover line wraps to at `width`, in the font Island.swift draws it in.
    static func lines(of text: String, width: CGFloat) -> Int {
        guard !text.isEmpty, width > 0 else { return 1 }
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        let setter = CTFramesetterCreateWithAttributedString(string)
        // A point narrower than the row, so a line SwiftUI wraps is never counted as fitting.
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: max(1, width - 1), height: 10_000), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        return max(1, CFArrayGetCount(CTFrameGetLines(frame)))
    }
}
