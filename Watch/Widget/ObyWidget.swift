import SwiftUI
import WidgetKit

@main
struct ObyWatchWidgets: WidgetBundle {
    var body: some Widget { NeedsYouWidget() }
}

/// The complications and the Smart Stack: how many things need you, with Oby in a still pose
/// (calm, busy, or waving). The watch app saves what to show when the phone sends the job list
/// and reloads this; nothing here asks for a refresh on its own.
struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Glance.kind, provider: GlanceProvider()) { entry in
            GlanceView(glance: entry.glance)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Oby")
        .description("How many things need you.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
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

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        completion(Timeline(entries: [GlanceEntry(date: .now, glance: .stored)], policy: .never))
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
