import SwiftUI

/// Sangam's design tokens (design/app/src/renderer/src/tokens.css, and the few app.css values
/// every screen shares), in Swift: the Mac window's colours, type, sizes and motion. Views use
/// these names, never literal colours. Sangam's design is dark only; the iPhone follows the system
/// with the light set the iPhone design adds (docs/ios-design.md), and the Mac and the Watch stay dark.
nonisolated enum Tokens {
    // MARK: Colour

    /// The window.
    static let bg = Color(dark: Color(hex: 0x0B0B0B), light: Color(hex: 0xF4F4F2))
    /// Titles, what's under the pointer, what's picked.
    static let ink = Color(dark: Color(hex: 0xECECEC), light: Color(hex: 0x161617))
    /// Text you read.
    static let text = Color(dark: Color(hex: 0xA3A3A8), light: Color(hex: 0x4A4A4F))
    /// Text you don't need to: times, counts, placeholders, icons at rest.
    static let muted = Color(dark: Color(hex: 0x6E6E74), light: Color(hex: 0x6A6A70))
    /// Group labels in the side panel.
    static let label = Color(dark: Color.white.opacity(0.4), light: Color.black.opacity(0.5))
    /// The items under them.
    static let item = Color(dark: Color.white.opacity(0.8), light: Color.black.opacity(0.82))
    /// Outlines at rest.
    static let line = Color(dark: Color.white.opacity(0.10), light: Color.black.opacity(0.10))
    /// Outlines hovered or pressed.
    static let lineStrong = Color(dark: Color.white.opacity(0.15), light: Color.black.opacity(0.16))
    /// A focused text field's outline.
    static let lineFocus = Color(dark: Color.white.opacity(0.25), light: Color.black.opacity(0.28))
    /// Lines between panels and between a card's parts.
    static let divider = Color(dark: Color.white.opacity(0.05), light: Color.black.opacity(0.06))
    /// The side panel's edge and the icon strip's: a touch stronger, with no fill to set them apart.
    static let edge = Color(dark: Color.white.opacity(0.08), light: Color.black.opacity(0.08))
    /// A row or icon under the pointer.
    static let hover = Color(dark: Color.white.opacity(0.06), light: Color.black.opacity(0.05))
    /// The selected one.
    static let active = Color(dark: Color.white.opacity(0.10), light: Color.black.opacity(0.08))
    /// Cards, tabs and the trail's buttons.
    static let chip = Color(dark: Color(hex: 0x161617), light: Color(hex: 0xFFFFFF))
    static let chipHover = Color(dark: Color(hex: 0x1F1F21), light: Color(hex: 0xEBEBE9))
    /// Home's chips: white 8%, 12% hovered.
    static let pill = Color(dark: Color.white.opacity(0.08), light: Color.black.opacity(0.06))
    static let pillHover = Color(dark: Color.white.opacity(0.12), light: Color.black.opacity(0.10))
    /// Your bubble in a conversation.
    static let bubble = Color(dark: Color.white.opacity(0.12), light: Color.black.opacity(0.07))
    /// Destructive actions, and a failed stage.
    static let danger = Color(dark: Color(hex: 0xF07167), light: Color(hex: 0xD23F34))
    /// Something new: macOS's blue.
    static let unread = Color(dark: Color(hex: 0x0A84FF), light: Color(hex: 0x007AFF))
    /// Needs you: macOS's orange.
    static let needs = Color(dark: Color(hex: 0xFF9F0A), light: Color(hex: 0xFF9500))
    /// An account past 80% of its week: macOS's yellow.
    static let full = Color(dark: Color(hex: 0xFFD60A), light: Color(hex: 0xC99A00))
    /// Past 90%: macOS's red.
    static let over = Color(dark: Color(hex: 0xFF453A), light: Color(hex: 0xFF3B30))
    /// A stage done: macOS's green.
    static let done = Color(dark: Color(hex: 0x30D158), light: Color(hex: 0x28A745))
    /// Menus, popovers and tooltips, and the lines inside them.
    static let surface = Color(dark: Color(hex: 0x181817), light: Color(hex: 0xFFFFFF))
    static let surfaceEdge = Color(dark: Color.white.opacity(0.08), light: Color.black.opacity(0.08))
    /// A text field's fill; its edge is `line`, `fieldEdgeOn` hovered or focused.
    static let field = Color(dark: Color.white.opacity(0.02), light: Color.black.opacity(0.02))
    static let fieldEdgeOn = Color(dark: Color.white.opacity(0.2), light: Color.black.opacity(0.22))
    /// The icon strip's icons at rest.
    static let railIcon = Color(dark: Color.white.opacity(0.5), light: Color.black.opacity(0.5))
    /// A task's title in a list while open, and once done.
    static let openTitle = Color(dark: Color.white.opacity(0.9), light: Color.black.opacity(0.88))
    static let doneTitle = Color(dark: Color.white.opacity(0.4), light: Color.black.opacity(0.4))
    /// A working task's dot (pulsing), and a done one's check.
    static let working = Color(dark: Color.white.opacity(0.75), light: Color.black.opacity(0.6))
    static let check = Color(dark: Color.white.opacity(0.4), light: Color.black.opacity(0.38))
    /// A decision's kind as text: a darker orange on a light ground.
    static let needsInk = Color(dark: Color(hex: 0xFF9F0A), light: Color(hex: 0xB35900))
    /// Text on an `ink` fill (the recommended option, Send).
    static let onInk = Color(dark: Color(hex: 0x111111), light: Color(hex: 0xF4F4F2))
    /// The mono block in a decision (the command, the diff).
    static let codeBg = Color(dark: Color.black.opacity(0.3), light: Color.black.opacity(0.05))
    /// A task or artifact card under Oby's words.
    static let cardFill = Color(dark: Color.white.opacity(0.06), light: Color(hex: 0xFFFFFF))
    /// A switch that's off.
    static let track = Color(dark: Color.white.opacity(0.14), light: Color.black.opacity(0.12))
    /// A usage bar's track.
    static let meter = Color(dark: Color.white.opacity(0.08), light: Color.black.opacity(0.07))
    /// A hairline round Oby's flat white face on a light ground; none on dark.
    static let obyEdge = Color(dark: .clear, light: Color.black.opacity(0.16))
    /// The stage bar's done and current segments, and an upcoming stage's ring.
    static let stageDone = Color(dark: Color.white.opacity(0.55), light: Color.black.opacity(0.45))
    /// What the message box recognises: links and references, another Oby, paths and `code`.
    static let link = Color(dark: Color(hex: 0x64A8FF), light: Color(hex: 0x0A63CC))
    static let code = Color(dark: Color(hex: 0xFF8A70), light: Color(hex: 0xB8432A))
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
    /// A token's two values. Only the iPhone shows the light one, when the system is light; the Mac's
    /// window and the Watch are dark.
    nonisolated init(dark: Color, light: Color) {
        #if os(iOS)
        self.init(UIColor { $0.userInterfaceStyle == .light ? UIColor(light) : UIColor(dark) })
        #else
        self = dark
        #endif
    }

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
