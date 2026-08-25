import WidgetKit
import SwiftUI

struct SyncEntry: TimelineEntry {
    let date: Date
    let lastSync: Date?
    let success: Bool
    let recordsToday: Int
}

struct SyncStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> SyncEntry {
        SyncEntry(date: Date(), lastSync: Date(), success: true, recordsToday: 1234)
    }

    func getSnapshot(in context: Context, completion: @escaping (SyncEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SyncEntry>) -> Void) {
        // The app reloads the timeline after every sync; this refresh is a fallback
        // so the relative "ago" text does not go stale.
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
        completion(Timeline(entries: [currentEntry()], policy: .after(refresh)))
    }

    private func currentEntry() -> SyncEntry {
        let status = SharedSyncStatus.read()
        return SyncEntry(
            date: Date(),
            lastSync: status.lastSync,
            success: status.lastSuccess,
            recordsToday: status.recordsToday
        )
    }
}

struct SyncStatusView: View {
    let entry: SyncEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.success ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text("Life Dashboard")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer()

            Text("\(entry.recordsToday)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("records today")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let lastSync = entry.lastSync {
                HStack(spacing: 3) {
                    Text(lastSync, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No syncs yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct SyncStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.owen282000.lifedashboard.syncstatus",
            provider: SyncStatusProvider()
        ) { entry in
            SyncStatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Sync Status")
        .description("Last sync result and records delivered today.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct LifeDashboardWidgetBundle: WidgetBundle {
    var body: some Widget {
        SyncStatusWidget()
    }
}
