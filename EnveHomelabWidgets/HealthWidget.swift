import SwiftUI
import WidgetKit

struct HealthEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct HealthProvider: TimelineProvider {
    func placeholder(in context: Context) -> HealthEntry {
        HealthEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (HealthEntry) -> Void) {
        completion(HealthEntry(date: .now, snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HealthEntry>) -> Void) {
        completion(Timeline(entries: [HealthEntry(date: .now, snapshot: WidgetSnapshot.load())], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

private let accent = Color(red: 245 / 255, green: 146 / 255, blue: 26 / 255)

private extension WidgetSnapshot.Item.Level {
    var color: Color {
        switch self {
        case .ok: .green
        case .unknown: .secondary
        case .warning: .yellow
        case .critical: .red
        }
    }

    var name: String {
        switch self {
        case .ok: "healthy"
        case .unknown: "unknown"
        case .warning: "warning"
        case .critical: "critical"
        }
    }
}

struct HealthWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HealthEntry

    var body: some View {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: accessory
        default: system
        }
    }

    @ViewBuilder private var accessory: some View {
        let snapshot = entry.snapshot.flatMap { $0.items.isEmpty ? nil : $0 }
        let attention = snapshot?.attentionCount ?? 0
        let symbol = snapshot == nil ? "server.rack" : (attention > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
        let summary = snapshot == nil ? "No checks yet" : (attention > 0 ? "\(attention) need attention" : "All healthy")
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: symbol).font(.caption)
                    if snapshot != nil { Text(attention > 0 ? "\(attention)" : "OK").font(.headline) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Homelab: \(summary)")
        case .accessoryInline:
            Label(summary, systemImage: symbol)
        default:
            VStack(alignment: .leading, spacing: 1) {
                Label(summary, systemImage: symbol).font(.headline).widgetAccentable()
                if let snapshot {
                    ForEach(snapshot.ranked.filter { $0.level == .critical || $0.level == .warning }.prefix(2)) { item in
                        Text("\(item.name): \(item.level.name)").font(.caption).lineLimit(1)
                    }
                    if attention == 0 {
                        Text("Updated \(snapshot.updatedAt, style: .relative) ago").font(.caption).lineLimit(1)
                    }
                } else {
                    Text("Open Petty: Homelab to add checks.").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var system: some View {
        if let snapshot = entry.snapshot, !snapshot.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: snapshot.attentionCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .foregroundStyle(snapshot.attentionCount > 0 ? .yellow : .green)
                    Text(snapshot.attentionCount > 0 ? "\(snapshot.attentionCount) need attention" : "All healthy")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .accessibilityElement(children: .combine)
                ForEach(snapshot.ranked.prefix(family == .systemSmall ? 3 : 4)) { item in
                    Link(destination: URL(string: "envehomelab://\(item.kind)/\(item.id)")!) {
                    HStack(spacing: 6) {
                        Circle().fill(item.level.color).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(item.name).font(.caption.weight(.semibold)).lineLimit(1)
                        if family != .systemSmall {
                            Spacer()
                            Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.name), \(item.level.name), \(item.detail)")
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    if snapshot.unreadAlerts > 0 {
                        Label("\(snapshot.unreadAlerts)", systemImage: "bell.badge.fill").font(.caption2).foregroundStyle(accent)
                    }
                    Spacer()
                    Text(snapshot.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "server.rack").foregroundStyle(accent).font(.title2)
                Text("Open Petty: Homelab to add service checks or integrations.").font(.caption)
            }
        }
    }
}

struct HealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EnveHomelabHealth", provider: HealthProvider()) { entry in
            HealthWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "envehomelab://alerts"))
        }
        .configurationDisplayName("Homelab Health")
        .description("The status Petty: Homelab last saw for your service checks and integrations.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct EnveHomelabWidgets: WidgetBundle {
    var body: some Widget {
        HealthWidget()
    }
}
