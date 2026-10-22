import SwiftUI

/// A loading placeholder: one soft bar that breathes until the list arrives. Still when motion is reduced.
struct Bone: View {
    var width: CGFloat?
    var height: CGFloat = 12
    var radius: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var lit = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Tokens.pill)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .opacity(reduce || lit ? 1 : 0.4)
            .onAppear {
                guard !reduce else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lit = true }
            }
            .accessibilityHidden(true)
    }
}

/// Rows of a side list, while it hasn't arrived.
struct RowBones: View {
    var rows = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<rows, id: \.self) { row in
                Bone(width: row.isMultiple(of: 2) ? 168 : 120, height: 14)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

/// Cards of a work list, while GitHub or the runner hasn't answered.
struct CardBones: View {
    var rows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<rows, id: \.self) { row in
                VStack(alignment: .leading, spacing: 10) {
                    Bone(width: row == 1 ? 220 : 180, height: 14)
                    Bone(height: 12)
                    Bone(width: 96, height: 12)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

/// A conversation that hasn't been read yet: a few turns, yours on the right.
struct ThreadBones: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Bone(width: 200, height: 36, radius: 16).frame(maxWidth: .infinity, alignment: .trailing)
            Bone(width: 280, height: 14)
            Bone(width: 210, height: 14)
            Bone(width: 150, height: 36, radius: 16).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}
