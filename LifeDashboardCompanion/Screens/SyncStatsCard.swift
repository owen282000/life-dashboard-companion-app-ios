import SwiftUI

/// Sync history at the top of the Logs tab: success rate, deliveries and records over the rows
/// the log keeps, the last success, and the latest failures. Draws a `SyncStats` value and reads
/// no store, so it can be restyled or previewed on its own.
struct SyncStatsCard: View {
    let stats: SyncStats

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if stats.isEmpty {
                Text("No deliveries yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                tiles
                details
                if !stats.recentFailures.isEmpty {
                    failures
                }
            }
        }
        .cardStyle()
    }

    private var header: some View {
        // Side by side, or one under the other at the accessibility text sizes.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return layout {
            Label {
                Text("Sync History")
            } icon: {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(Brand.logsInk)
            }
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer()
            }
            if let since = stats.since {
                Text("Since \(since.formatted(SyncStatsCard.dateFormat))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var tiles: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            StatCard(
                title: "Success",
                value: stats.successPercent.map { "\($0)%" } ?? "-",
                color: Brand.successInk
            )
            StatCard(title: "Deliveries", value: stats.deliveries.formatted(), color: .primary)
            StatCard(title: "Records", value: stats.records.formatted(), color: .primary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if stats.mqttDeliveries > 0 {
                Text("Webhook \(stats.webhookSucceeded) / \(stats.webhookDeliveries) · MQTT \(stats.mqttSucceeded) / \(stats.mqttDeliveries)")
            }
            if let lastSuccess = stats.lastSuccess {
                Text("Last success: \(lastSuccess.formatted(SyncStatsCard.dateFormat))")
            } else {
                Text("Last success: never")
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var failures: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent failures")
                .font(.caption)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            ForEach(stats.recentFailures) { failure in
                FailureLine(failure: failure)
            }
        }
    }

    static let dateFormat = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
}

private struct FailureLine: View {
    let failure: SyncStats.Failure

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundColor(Brand.errorInk)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    sourceName
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(failure.latest.formatted(SyncStatsCard.dateFormat))
                        .foregroundColor(.secondary)
                }
                Text(message)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    /// The two sources the app names itself are translated; a webhook is shown by its host.
    private var sourceName: Text {
        switch failure.source {
        case SyncStats.readFailureSource: return Text("Apple Health")
        case SyncStats.mqttSource: return Text(verbatim: "MQTT")
        default: return Text(verbatim: failure.source)
        }
    }

    private var message: String {
        let text = failure.message.map(AppDiagnostic.display) ?? String(localized: "Unknown error")
        return failure.count > 1 ? String(localized: "\(text) (\(failure.count) times)") : text
    }
}
