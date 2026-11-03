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

/// The app's dark ground and accents, here because the widget cannot use the app's theme.
private enum WidgetTheme {
    static let ground = Color(red: 0x0A / 255, green: 0x0F / 255, blue: 0x0D / 255)
    static let text = Color(red: 0xEE / 255, green: 0xF4 / 255, blue: 0xF0 / 255)
    static let muted = Color(red: 0xA7 / 255, green: 0xB5 / 255, blue: 0xAE / 255)
    static let accent = Color(red: 0x30 / 255, green: 0xB7 / 255, blue: 0x7E / 255)
    static let onAccent = Color(red: 0x06 / 255, green: 0x13 / 255, blue: 0x0D / 255)
    static let warning = Color(red: 0xF7 / 255, green: 0xC5 / 255, blue: 0x6C / 255)
}

/// The heartbeat line of the app and its logo, ending in a dot.
private struct WidgetPulse: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 240
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.midY + (y - 42) * scale)
        }
        var line = Path()
        line.move(to: point(0, 42))
        for (x, y) in [(136, 42), (147, 16), (164, 68), (179, 30), (186, 42), (226, 42)] as [(CGFloat, CGFloat)] {
            line.addLine(to: point(x, y))
        }
        return line
    }
}

/// The state of the last sync, the records delivered today and when.
struct SyncStatusView: View {
    let entry: SyncEntry

    private var stateColor: Color { entry.success ? WidgetTheme.accent : WidgetTheme.warning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                ZStack(alignment: .trailing) {
                    WidgetPulse()
                        .stroke(stateColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                }
                .frame(height: 24)
                .widgetAccentable()
                .flipsForRightToLeftLayoutDirection(true)
                .accessibilityHidden(true)
                SyncNowButton()
            }

            Spacer(minLength: 2)

            Text(entry.recordsToday.formatted())
                .font(.custom("SpaceGrotesk-Bold", size: 34, relativeTo: .largeTitle))
                .tracking(-0.5)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(WidgetTheme.text)
                // Dimmed from a tap on Sync Now until the sync reloads the widget.
                .invalidatableContent()
            // Picked here because the number above is styled on its own and a plural form must
            // contain it. Right for English, Dutch and German, where only 1 is singular.
            Text(entry.recordsToday == 1 ? "record today" : "records today")
                .font(.custom("SpaceGrotesk-Medium", size: 13, relativeTo: .caption))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(WidgetTheme.muted)

            Spacer(minLength: 2)

            HStack(spacing: 4) {
                // A symbol as well as a colour, so the state does not rest on colour alone.
                Image(systemName: entry.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(stateColor)
                    .widgetAccentable()
                    .accessibilityLabel(entry.success ? Text("Last sync succeeded") : Text("Last sync failed"))
                Group {
                    if let lastSync = entry.lastSync {
                        if Calendar.current.isDateInToday(lastSync) {
                            Text("Synced \(lastSync, style: .time)")
                        } else {
                            Text("Synced on \(lastSync.formatted(.dateTime.month(.abbreviated).day()))")
                        }
                    } else {
                        Text("No syncs yet")
                    }
                }
                .font(.custom("SpaceMono-Regular", size: 11, relativeTo: .caption2))
                .foregroundStyle(WidgetTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .invalidatableContent()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Runs Sync Health Data in the app, which reloads the widget when the sync is done.
struct SyncNowButton: View {
    var body: some View {
        Button(intent: SyncHealthDataIntent()) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(WidgetTheme.onAccent)
                .frame(width: 32, height: 32)
                .background(WidgetTheme.accent, in: Circle())
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
                .containerBackground(WidgetTheme.ground, for: .widget)
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
