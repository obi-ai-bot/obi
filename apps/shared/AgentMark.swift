import SwiftUI

/// A coding tool's mark, where an SF Symbol stood: the tool's own brand mark, tinted and sized like the
/// symbol. The marks are each company's files, unaltered (anthropic.com/press-kit, openai.com/brand,
/// cursor.com/brand), as template images in the apps' asset catalogs. Gemini keeps the symbol until it has one.
struct AgentMark: View {
    let agent: String
    /// In the text's colour rather than the brand's, as the window's lists draw a task's mark.
    var mono = false

    private static let assets = ["claude": "Claude", "codex": "OpenAI", "cursor": "Cursor"]
    /// OpenAI's file draws the blossom in the middle half of its canvas, where Claude's and Cursor's
    /// marks fill theirs; drawn this much larger, it matches them without touching the file.
    private static let scale = ["codex": 1.8]

    var body: some View {
        if let asset = Self.assets[agent] {
            // The hidden symbol sizes the box, so the mark follows the font as the symbol did.
            Image(systemName: "asterisk").hidden()
                .overlay {
                    Image(asset).resizable().renderingMode(mono ? .template : .original).scaledToFit().scaleEffect(Self.scale[agent] ?? 1)
                }
        } else {
            Image(systemName: "asterisk")
        }
    }
}
