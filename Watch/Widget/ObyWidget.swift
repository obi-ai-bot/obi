import SwiftUI
import WidgetKit

@main
struct ObyWatchWidgets: WidgetBundle {
    var body: some Widget { NeedsYouWidget() }
}

/// The complications and the Smart Stack: how many things need you, with Oby in a still pose
/// (calm, busy, or waving). The watch app saves what to show when the job list arrives and
/// reloads this. On a paired watch the runner also sends a WidgetKit push when the counts change
/// (docs/runner-api.md): then this fetches the jobs from the Watch API itself, phone or not.
struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Glance.kind, provider: GlanceProvider()) { entry in
            GlanceView(glance: entry.glance)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Oby")
        .description("How many things need you.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
        .pushHandler(GlancePushHandler.self)
    }
}

/// The complications' push token, issued or rotated, goes to the app group and straight to the
/// runner when the watch is paired; the app tries again whenever it runs until the runner has it.
struct GlancePushHandler: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        Glance.issued(pushInfo.token)
        guard let link = WatchLink.saved else { return }
        Task { _ = await Glance.uploadWidgetToken(link, attempts: 3) }
    }
}

struct GlanceEntry: TimelineEntry {
    let date: Date
    let glance: Glance

    /// The Smart Stack brings Oby up while something needs you.
    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: glance.needs > 0 ? 100 : glance.working > 0 ? 10 : 0)
    }
}

struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: .now, glance: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        completion(GlanceEntry(date: .now, glance: context.isPreview ? .sample : .stored))
    }

    /// The runner's jobs when the watch is paired, else what the app saved.
    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        guard let link = WatchLink.saved else {
            completion(Timeline(entries: [GlanceEntry(date: .now, glance: .stored)], policy: .never))
            return
        }
        Task {
            var glance = Glance.stored
            if let jobs = try? await link.jobs() {
                glance = Glance.of(jobs)
                _ = Glance.save(glance)
            }
            // A token the runner hasn't accepted yet gets another try.
            _ = await Glance.uploadWidgetToken(link, attempts: 1)
            completion(Timeline(entries: [GlanceEntry(date: .now, glance: glance)], policy: .never))
        }
    }
}

struct GlanceView: View {
    let glance: Glance
    @Environment(\.widgetFamily) private var family

    /// Waving while something needs you, busy while agents work, calm otherwise.
    private var pose: String {
        if glance.needs > 0 { return "ObyNeedsYou" }
        return glance.working > 0 ? "ObyWorking" : "ObyCalm"
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if glance.needs > 0 {
                    VStack(spacing: 0) {
                        oby.frame(height: 20)
                        Text("\(glance.needs)")
                            .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                            .widgetAccentable()
                    }
                } else {
                    oby.padding(6)
                }
            }
            .accessibilityLabel(glance.line)
        case .accessoryCorner:
            oby
                .widgetLabel { Text(glance.line) }
        case .accessoryInline:
            Text("Oby · \(glance.line)")
        default:
            // Rectangular: on the face and in the Smart Stack.
            HStack(spacing: 8) {
                oby.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(glance.line)
                        .font(.headline)
                        .widgetAccentable()
                    if let top = glance.top {
                        Text(top).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    } else if glance.needs > 0, glance.working > 0 {
                        Text("\(glance.working) working").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var oby: some View {
        Image(pose)
            .resizable()
            .scaledToFit()
            .accessibilityLabel("Oby")
    }
}
