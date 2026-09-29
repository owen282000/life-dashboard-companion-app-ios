import SwiftUI

/// Sync history at the top of the Logs tab: success rate, deliveries and records over the rows
/// the log keeps, the last success, and the latest failures. Draws a `SyncStats` value and reads
/// no store, so it can be restyled or previewed on its own.
struct SyncStatsCard: View {
    let stats: SyncStats

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
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Sync History", systemImage: "chart.bar.fill")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let since = stats.since {
                Text("Since \(since.formatted(SyncStatsCard.dateFormat))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var tiles: some View {
        HStack(spacing: 16) {
            StatCard(
                title: "Success",
                value: stats.successPercent.map { "\($0)%" } ?? "-",
                color: .green
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
                .foregroundColor(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(failure.source)
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

    private var message: String {
        let text = failure.message ?? String(localized: "Unknown error")
        return failure.count > 1 ? String(localized: "\(text) (\(failure.count) times)") : text
    }
}
