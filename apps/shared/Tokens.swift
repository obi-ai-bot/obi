import SwiftUI

/// Sangam's design tokens (design/app/src/renderer/src/tokens.css, and the few app.css values
/// every screen shares), in Swift: the Mac window's colours, type, sizes and motion. Views use
/// these names, never literal colours. The design is dark only, so there's one set.
nonisolated enum Tokens {
    // MARK: Colour

    /// The window.
    static let bg = Color(hex: 0x0B0B0B)
    /// Titles, what's under the pointer, what's picked.
    static let ink = Color(hex: 0xECECEC)
    /// Text you read.
    static let text = Color(hex: 0xA3A3A8)
    /// Text you don't need to: times, counts, placeholders, icons at rest.
    static let muted = Color(hex: 0x6E6E74)
    /// Group labels in the side panel.
    static let label = Color.white.opacity(0.4)
    /// The items under them.
    static let item = Color.white.opacity(0.8)
    /// Outlines at rest.
    static let line = Color.white.opacity(0.10)
    /// Outlines hovered or pressed.
    static let lineStrong = Color.white.opacity(0.15)
    /// A focused text field's outline.
    static let lineFocus = Color.white.opacity(0.25)
    /// Lines between panels and between a card's parts.
    static let divider = Color.white.opacity(0.05)
    /// The side panel's edge and the icon strip's: a touch stronger, with no fill to set them apart.
    static let edge = Color.white.opacity(0.08)
    /// A row or icon under the pointer.
    static let hover = Color.white.opacity(0.06)
    /// The selected one.
    static let active = Color.white.opacity(0.10)
    /// Cards, tabs and the trail's buttons.
    static let chip = Color(hex: 0x161617)
    static let chipHover = Color(hex: 0x1F1F21)
    /// Home's chips: white 8%, 12% hovered.
    static let pill = Color.white.opacity(0.08)
    static let pillHover = Color.white.opacity(0.12)
    /// Your bubble in a conversation.
    static let bubble = Color.white.opacity(0.12)
    /// Destructive actions, and a failed stage.
    static let danger = Color(hex: 0xF07167)
    /// Something new: macOS's blue.
    static let unread = Color(hex: 0x0A84FF)
    /// Needs you: macOS's orange.
    static let needs = Color(hex: 0xFF9F0A)
    /// An account past 80% of its week: macOS's yellow.
    static let full = Color(hex: 0xFFD60A)
    /// Past 90%: macOS's red.
    static let over = Color(hex: 0xFF453A)
    /// A stage done: macOS's green.
    static let done = Color(hex: 0x30D158)
    /// Menus, popovers and tooltips, and the lines inside them.
    static let surface = Color(hex: 0x181817)
    static let surfaceEdge = Color.white.opacity(0.08)
    /// A text field's fill; its edge is `line`, `fieldEdgeOn` hovered or focused.
    static let field = Color.white.opacity(0.02)
    static let fieldEdgeOn = Color.white.opacity(0.2)
    /// The icon strip's icons at rest.
    static let railIcon = Color.white.opacity(0.5)
    /// A task's title in a list while open, and once done.
    static let openTitle = Color.white.opacity(0.9)
    static let doneTitle = Color.white.opacity(0.4)
    /// A working task's dot (pulsing), and a done one's check.
    static let working = Color.white.opacity(0.75)
    static let check = Color.white.opacity(0.4)
    /// What the message box recognises: links and references, another Oby, paths and `code`.
    static let link = Color(hex: 0x64A8FF)
    static let code = Color(hex: 0xFF8A70)
    /// A person's picture until there are real photos: initials on a colour picked from their
    /// name (djb2, so similar names land on different colours).
    static let avatars: [UInt32] = [0x3A5A8C, 0x7A4A8C, 0x2F7A6A, 0x8C5A3A, 0x8C3A52, 0x5A6A2F, 0x3A7A8C, 0x6A4A3A]
    static func avatar(_ name: String) -> Color {
        let hash = name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) ^ $1.value }
        return Color(hex: avatars[Int(hash % UInt32(avatars.count))])
    }

    // MARK: Type

    /// 12: counts, times, labels.
    static let textSm: CGFloat = 12
    /// 13: the trail, a card's meta line.
    static let textMd: CGFloat = 13
    /// 14: what you read: chips, task names.
    static let textBase: CGFloat = 14
    /// 15: what you type.
    static let textLg: CGFloat = 15
    /// 24: a section's title in the side panel.
    static let textTitle: CGFloat = 24
    /// The message box's line.
    static let composerLine: CGFloat = 22

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }

    // MARK: Size

    /// The side panel's width, the icon strip included: what it opens at, and how far a drag goes.
    static let sidebar: CGFloat = 290
    static let sidebarMin: CGFloat = 252
    static let sidebarMax: CGFloat = 472
    /// The icon strip: 32-point icons, 8 each side.
    static let rail: CGFloat = 48
    /// The view never gets narrower.
    static let viewMin: CGFloat = 420
    /// The title bar, and where its content starts clear of the traffic lights, until the
    /// window says where macOS put them.
    static let bar: CGFloat = 48
    static let afterLights: CGFloat = 84
    /// Room at a view's edges.
    static let gutter: CGFloat = 20
    /// A conversation's and a group's column.
    static let column: CGFloat = 540
    /// Home's message box, its gutters included.
    static let homeBox: CGFloat = 520
    /// Corners: a card, a decision, a bubble, a row, an icon button.
    static let cardRadius: CGFloat = 22
    static let askRadius: CGFloat = 18
    static let bubbleRadius: CGFloat = 18
    static let rowRadius: CGFloat = 6
    static let iconRadius: CGFloat = 8

    // MARK: Motion

    /// Hover, focus and press ease in softly instead of snapping.
    static let fade = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.28)
    /// Opening, closing, folding: quick off the mark, a long soft landing.
    static let warm = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)
    /// Leaving: slow off the mark, then gone.
    static let easeIn = Animation.timingCurve(0.55, 0, 0.75, 0.3, duration: 0.2)
    /// Like warm with a little overshoot before it rests: the side panel opening and settling.
    static let settle = Animation.spring(duration: 0.52, bounce: 0.18)
    /// Things arriving: past the mark by a few points, then settling.
    static let spring = Animation.spring(duration: 0.62, bounce: 0.3)
}

extension Color {
    /// A colour from its hex value, as tokens.css writes it.
    nonisolated init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// Text too long for its row fades out over its last 24 points instead of ending in dots
    /// (`--fade-out`); short text never reaches the fade.
    func fadeOut() -> some View {
        // Sized by a copy that can shrink, so a long name never widens its row; drawn whole over it.
        lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { lineLimit(1).fixedSize(horizontal: true, vertical: false) }
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
                }
            }
    }
}
