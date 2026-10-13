import SwiftUI

/// A single pill for every app and every job surface.
struct StatusPill: View {
    let badge: JobBadge

    var body: some View {
        Text(badge.text).font(OBYStyle.caption.weight(.semibold)).foregroundStyle(badge.tone.color)
            .padding(.horizontal, OBYStyle.Space.md).padding(.vertical, OBYStyle.Space.xs)
            .background(badge.tone.color.opacity(0.18), in: Capsule())
    }
}
