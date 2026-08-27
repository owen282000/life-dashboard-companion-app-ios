import SwiftUI

/// Compact at-a-glance dashboard at the top of the Health screen: delivery stats from
/// SharedSyncStatus and the lifetime counters, plus a 7-day steps sparkline built from
/// HealthKit's deduplicated daily statistics. Read-only; mirrors the Android DashboardCard.
struct DashboardCard: View {
    @State private var status = SharedSyncStatus.read()
    @State private var lifetimeRecords = UserDefaults.standard.integer(forKey: "stats_lifetime_records")
    @State private var stepsPerDay: [Int] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                statTile(label: "Today", value: "\(status.recordsToday)", unit: "records")
                Spacer()
                statTile(label: "Lifetime", value: lifetimeRecords.formatted(), unit: "records")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last sync")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(status.lastSuccess ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(status.lastSync.map { $0.formatted(date: .omitted, time: .shortened) } ?? "never")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                }
            }

            if stepsPerDay.count >= 2 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Steps, last \(stepsPerDay.count) days")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    SparklineView(values: stepsPerDay)
                        .frame(height: 36)
                }
            }
        }
        .padding(14)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .task {
            status = SharedSyncStatus.read()
            lifetimeRecords = UserDefaults.standard.integer(forKey: "stats_lifetime_records")
            stepsPerDay = await HealthKitManager.shared.readDailyStepTotals(days: 7)
        }
    }

    private func statTile(label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.headline)
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct SparklineView: View {
    let values: [Int]

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard let minValue = values.min(), let maxValue = values.max() else { return }
                let range = CGFloat(max(maxValue - minValue, 1))
                let stepX = geo.size.width / CGFloat(max(values.count - 1, 1))
                for (index, value) in values.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(index) * stepX,
                        y: geo.size.height - CGFloat(value - minValue) / range * geo.size.height
                    )
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
