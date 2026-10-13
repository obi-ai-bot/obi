import SwiftUI

/// The messenger's shared palette, geometry and type. ReadingText still follows the user's reading settings.
nonisolated enum OBYStyle {
    static let window = Color(white: 0.09)
    static let sidebar = Color(white: 0.11)
    static let surface = Color(white: 0.14)
    static let assistantBubble = Color(white: 0.17)
    static let composer = Color.white.opacity(0.07)
    static let selection = Color.white.opacity(0.08)
    static let userBubble = Color(white: 0.92)
    static let userText = Color(white: 0.09)
    static let separator = Color.white.opacity(0.08)
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.65)
    static let tertiary = Color.white.opacity(0.45)
    static let accent = Color.accentColor
    static let bubble: CGFloat = 22
    static let expandedComposer: CGFloat = 18
    static let card: CGFloat = 14
    static let chip: CGFloat = 10
    static let threadWidth: CGFloat = 720
    static let replyWidth: CGFloat = 640
    static let title = Font.system(size: 17, weight: .bold)
    static let body = Font.system(size: 15)
    static let small = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }
}
