import SwiftUI

/// Compact at-a-glance dashboard at the top of the Health screen: delivery stats from
/// SharedSyncStatus and the lifetime counters, plus a 7-day steps sparkline built from
/// HealthKit's deduplicated daily statistics. Read-only; mirrors the Android DashboardCard.
struct DashboardCard: View {
    @State private var status = SharedSyncStatus.read()
    @State private var lifetimeRecords = UserDefaults.standard.integer(forKey: "stats_lifetime_records")
    @State private var stepsPerDay: [Int] = []

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    statTiles
                }
            } else {
                HStack(alignment: .top) {
                    statTiles
                }
            }

            if stepsPerDay.count >= 2 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Steps, last \(stepsPerDay.count) days")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SparklineView(values: stepsPerDay)
                        .frame(height: 36)
                        .accessibilityElement()
                        .accessibilityLabel(Text("Steps, last \(stepsPerDay.count) days"))
                        .accessibilityValue(sparklineValue)
                }
            }
        }
        .cardStyle()
        .task {
            status = SharedSyncStatus.read()
            lifetimeRecords = UserDefaults.standard.integer(forKey: "stats_lifetime_records")
            stepsPerDay = await HealthKitManager.shared.readDailyStepTotals(days: 7)
        }
    }

    @ViewBuilder
    private var statTiles: some View {
        statTile(label: "Today", count: status.recordsToday)
        Spacer(minLength: 8)
        statTile(label: "Lifetime", count: lifetimeRecords)
        Spacer(minLength: 8)
        lastSyncTile
    }

    private func statTile(label: LocalizedStringKey, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                // Never broken over two lines: a longer label beside it, such as German's
                // "Letzte Synchronisierung", wraps instead.
                Text(verbatim: count.formatted())
                    .font(.title2.bold())
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // The number is styled on its own, and a plural form must contain it, so the
                // label is picked here. Right for English, Dutch and German, where only 1 is
                // singular; a language with more plural forms needs a plural key instead.
                Text(count == 1 ? "record" : "records")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
    }

    private var lastSyncTile: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
            Text("Last sync")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 6) {
                if status.lastSync != nil {
                    // A symbol as well as a colour, so the state does not rest on colour alone.
                    Image(systemName: status.lastSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(status.lastSuccess ? Brand.successInk : Brand.errorInk)
                        .accessibilityLabel(status.lastSuccess ? Text("Succeeded") : Text("Failed"))
                }
                Text(status.lastSync.map { $0.formatted(date: .omitted, time: .shortened) } ?? String(localized: "never"))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .frame(minHeight: 44, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    private var sparklineValue: Text {
        guard let low = stepsPerDay.min(), let high = stepsPerDay.max(), let last = stepsPerDay.last else {
            return Text(verbatim: "")
        }
        return Text("Lowest \(low), highest \(high), latest \(last)")
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
            .stroke(Brand.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
