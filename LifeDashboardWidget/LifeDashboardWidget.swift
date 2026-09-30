import AppIntents
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
        // The app reloads the timeline after every sync; this refresh is a fallback so the
        // records of a new day start at 0.
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

/// The Android app's widget: the state of the last sync, the records delivered today and when.
struct SyncStatusView: View {
    let entry: SyncEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                // A symbol as well as a colour, so the state does not rest on colour alone.
                Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(entry.success ? Brand.success : Brand.error)
                    .widgetAccentable()
                    .accessibilityLabel(entry.success ? Text("Last sync succeeded") : Text("Last sync failed"))
                Text("Life Dashboard")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                SyncNowButton()
            }

            Spacer()

            Text(entry.recordsToday.formatted())
                .font(.largeTitle.bold())
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .widgetAccentable()
                // Dimmed from a tap on Sync Now until the sync reloads the widget.
                .invalidatableContent()
            // Picked here because the number above is styled on its own and a plural form must
            // contain it. Right for English, Dutch and German, where only 1 is singular.
            Text(entry.recordsToday == 1 ? "record today" : "records today")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Group {
                if let lastSync = entry.lastSync {
                    if Calendar.current.isDateInToday(lastSync) {
                        Text("Synced \(lastSync, style: .time)")
                    } else {
                        Text("Synced on \(lastSync.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    }
                } else {
                    Text("No syncs yet")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .invalidatableContent()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Android's Quick Settings tile on the home screen: runs Sync Health Data in the app, which
/// reloads the widget when the sync is done.
struct SyncNowButton: View {
    var body: some View {
        Button(intent: SyncHealthDataIntent()) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.bold))
                .foregroundStyle(Brand.onGreen)
                .frame(width: 28, height: 28)
                .background(Brand.green, in: Circle())
                .widgetAccentable()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Sync Now"))
    }
}

/// The Control Center control (iOS 18): one tap runs Sync Health Data, like the Android app's
/// Quick Settings tile. It can be added to the Lock Screen as well, but Health data can't be
/// read while the iPhone is locked, so there it syncs nothing until the iPhone is unlocked.
@available(iOS 18.0, *)
struct SyncNowControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.owen282000.lifedashboard.syncnow") {
            ControlWidgetButton(action: SyncHealthDataIntent()) {
                Label("Sync Life Dashboard", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .displayName("Sync Now")
        .description("Syncs your health data to your webhooks and MQTT broker.")
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
        .description("Last sync result and records delivered today, with a button that syncs now.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct LifeDashboardWidgetBundle: WidgetBundle {
    var body: some Widget {
        SyncStatusWidget()
        if #available(iOS 18.0, *) {
            SyncNowControl()
        }
    }
}
