import SwiftUI

/// One kind of work's page (#496, Sangam's GroupView): its name, Running and Completed tabs with
/// their counts, and a card per task under the open tab. Under Completed, where older ones go.
struct GroupPane: View {
    let model: IslandModel
    let kind: WorkType
    /// The kind's tasks, in Home's order (`WorkList.ranked`).
    let items: [WorkList.Item<SidebarSections.JobRow>]
    let onOpenJob: (_ job: String, _ local: Bool) -> Void
    /// The tab picked, or nil for the one it opens on (`WorkList.firstTab`).
    @State private var picked: WorkList.Tab?

    /// Archived (#280) isn't on the Mac yet: until it is, Clear done takes finished jobs off the list.
    static let archivedLine = "Older ones will be in Archived, which isn't on the Mac yet. Until then, Clear done takes them off this list."

    private var tab: WorkList.Tab { picked ?? WorkList.firstTab(items) }
    private var ranked: [WorkList.Item<SidebarSections.JobRow>] { WorkList.ranked(items) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.label).font(Tokens.font(28, .semibold)).foregroundStyle(Tokens.ink)
                    .padding(.bottom, 16).accessibilityAddTraits(.isHeader)
                LineTabs(tab: tab, counts: Dictionary(uniqueKeysWithValues: WorkList.Tab.allCases.map { ($0, WorkList.items(items, in: $0).count) })) {
                    picked = $0
                }
                .padding(.bottom, 16)
                let cards = WorkList.items(ranked, in: tab)
                ForEach(cards) { item in
                    TaskCardView(item: item, model: model) { onOpenJob(item.job.job.id, item.job.local) }
                }
                if cards.isEmpty {
                    Text(tab == .done ? "Nothing completed yet" : "Nothing running")
                        .font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.vertical, 8).padding(.horizontal, 4)
                }
                if tab == .done {
                    Text(Self.archivedLine).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                        .padding(.top, 8).padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: Tokens.column, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.gutter).padding(.top, 16).padding(.bottom, 32)
        }
        .scrollIndicators(.never)
        // The tab it opens on stays put while you're on it, so a task arriving doesn't switch it.
        .onAppear { picked = picked ?? WorkList.firstTab(items) }
    }
}

/// Underlined tabs (Sangam's `.line-tabs`): the names alone with their counts, the open one in ink
/// with a 2-point line on the 1-point line under the row, sliding to the tab picked.
struct LineTabs: View {
    let tab: WorkList.Tab
    let counts: [WorkList.Tab: Int]
    let onPick: (WorkList.Tab) -> Void
    @Namespace private var line

    var body: some View {
        HStack(spacing: 24) {
            ForEach(WorkList.Tab.allCases, id: \.self) { each in
                Button { withAnimation(Tokens.warm) { onPick(each) } } label: {
                    HStack(spacing: 6) {
                        Text(each.rawValue).font(Tokens.font(Tokens.textBase))
                            .foregroundStyle(tab == each ? Tokens.ink : Tokens.muted)
                        Text("\(counts[each] ?? 0)").font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
                    }
                    .frame(height: 36)
                    .overlay(alignment: .bottom) {
                        if tab == each {
                            Capsule().fill(Tokens.ink).frame(height: 2).offset(y: 1)
                                .matchedGeometryEffect(id: "line", in: line)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == each ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Tokens.line.frame(height: 1) }
    }
}
