import SwiftUI

/// One kind of work's page (#496, Sangam's GroupView): its name, Running and Completed tabs with
/// their counts, and a card per task under the open tab. Under Completed, where older ones go.
struct GroupPane: View {
    let model: IslandModel
    let kind: WorkType
    /// The kind's tasks, in Home's order (`WorkList.ranked`).
    let items: [WorkList.Item<SidebarSections.JobRow>]
    let onOpenJob: (_ job: String, _ local: Bool) -> Void
    let onBack: () -> Void
    /// The tab picked, or nil for the one it opens on (`WorkList.firstTab`).
    @State private var picked: WorkList.Tab?

    /// Archived (#280) isn't on the Mac yet: until it is, Clear done takes finished jobs off the list.
    static let archivedLine = "Older ones will be in Archived, which isn't on the Mac yet. Until then, Clear done takes them off this list."

    private var tab: WorkList.Tab { picked ?? WorkList.firstTab(items) }
    private var ranked: [WorkList.Item<SidebarSections.JobRow>] { WorkList.ranked(items) }

    var body: some View {
        VStack(alignment: .leading, spacing: OBYStyle.Space.lg) {
            HStack(spacing: OBYStyle.Space.md) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Text(kind.label).font(OBYStyle.title).accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: OBYStyle.Space.xl) {
                ForEach(WorkList.Tab.allCases, id: \.self) { each in
                    Button { picked = each } label: {
                        VStack(spacing: OBYStyle.Space.xs) {
                            HStack(spacing: 6) {
                                Text(each.rawValue).font(OBYStyle.body.weight(.semibold))
                                Text("\(WorkList.items(items, in: each).count)").font(OBYStyle.small).foregroundStyle(OBYStyle.secondary)
                            }
                            .foregroundStyle(tab == each ? OBYStyle.primary : OBYStyle.secondary)
                            Rectangle().fill(tab == each ? OBYStyle.primary : .clear).frame(height: 2)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == each ? .isSelected : [])
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: OBYStyle.Space.sm) {
                    let cards = WorkList.items(ranked, in: tab)
                    ForEach(cards) { item in
                        let row = item.job
                        JobChip(job: row.job, account: LiveView.account(of: row.job, local: row.local, desk: model.desk, feed: model.feed),
                                onOpen: { onOpenJob(row.job.id, row.local) },
                                onStop: { model.stopChatJob(row.job.id, local: row.local) })
                    }
                    if cards.isEmpty {
                        Text(tab == .done ? "Nothing completed yet" : "Nothing running")
                            .font(OBYStyle.small).foregroundStyle(OBYStyle.tertiary).padding(.vertical, OBYStyle.Space.sm)
                    }
                    if tab == .done {
                        Text(Self.archivedLine).font(OBYStyle.caption).foregroundStyle(OBYStyle.tertiary)
                            .padding(.top, OBYStyle.Space.sm)
                    }
                }
                .frame(maxWidth: OBYStyle.threadWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, OBYStyle.Space.xl).padding(.top, 46).padding(.bottom, OBYStyle.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The tab it opens on stays put while you're on it, so a task arriving doesn't switch it.
        .onAppear { picked = picked ?? WorkList.firstTab(items) }
    }
}
