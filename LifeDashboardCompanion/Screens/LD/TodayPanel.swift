import SwiftUI

/// What the user sends, at a glance: steps, sleep, resting heart rate and weight, as far as those
/// are selected and have data. One figure is drawn large; none means the records sent today; no
/// types at all, the way to pick them. A panel inside HomeScreen's scroll view, so it has no
/// LDScreen of its own. `firstIndex` is where its figures join the stagger of the screen.
struct TodayPanel: View {
    @ObservedObject var provider: TodayStatsProvider
    var firstIndex = 0

    @ObservedObject private var prefs = PreferencesManager.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if prefs.healthEnabledDataTypes.isEmpty {
            LDGap(10)
            LDButton("Pick what to send", route: .whatToSend)
        } else if provider.hasLoaded {
            VStack(alignment: .leading, spacing: 0) {
                header
                switch provider.stats.count {
                case 0: recordsToday
                case 1: large(provider.stats[0])
                default: grid
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.horizontal, LDTheme.textInset)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Today")
                .font(LDType.sectionLabel)
                .foregroundStyle(LDTheme.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if !provider.stats.isEmpty {
                Text("Lines show 7 days")
                    .font(LDType.sans(12, relativeTo: .caption))
                    .foregroundStyle(LDTheme.muted)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.bottom, 6)
    }

    private var grid: some View {
        let stats = provider.stats
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(stride(from: 0, to: stats.count, by: columns)), id: \.self) { first in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(first..<min(first + columns, stats.count), id: \.self) { index in
                        cell(stats[index], index: index)
                    }
                    if columns == 2, first + 1 == stats.count {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
    }

    private func cell(_ stat: TodayStat, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: stat.formattedLatest)
                .font(LDType.sans(26, .bold, relativeTo: .title2))
                .tracking(-0.4)
                .foregroundStyle(LDTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            stat.caption
                .font(LDType.rowSubtitle)
                .foregroundStyle(LDTheme.muted)
            SparkLine(values: stat.series)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(stat.trend)
        .ldLink(to: .whatToSend)
        .ldStaggerRise(firstIndex + index)
    }

    private func large(_ stat: TodayStat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            largeValue(stat.formattedLatest)
            stat.caption
                .font(LDType.rowSubtitle)
                .foregroundStyle(LDTheme.muted)
            SparkLine(values: stat.series, height: 44)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(stat.trend)
        .ldLink(to: .whatToSend)
        .ldStaggerRise(firstIndex)
    }

    private var recordsToday: some View {
        let count = provider.recordsToday
        return VStack(alignment: .leading, spacing: 0) {
            largeValue(count.formatted())
            Text(count == 1 ? "record" : "records")
                .font(LDType.rowSubtitle)
                .foregroundStyle(LDTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .ldLink(to: .whatToSend)
        .ldStaggerRise(firstIndex)
    }

    private func largeValue(_ value: String) -> some View {
        Text(verbatim: value)
            .font(LDType.sans(44, .bold, relativeTo: .largeTitle))
            .tracking(-0.6)
            .foregroundStyle(LDTheme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

private extension TodayStat {
    var formattedLatest: String { format(latest) }

    var caption: Text {
        switch kind {
        case .steps: return Text("steps")
        case .sleep: return Text("sleep")
        case .restingHeartRate: return Text("rest bpm")
        case .weight: return TodayStatKind.weighsInPounds ? Text("lb") : Text("kg")
        }
    }

    func format(_ value: Double) -> String {
        switch kind {
        case .steps, .restingHeartRate:
            return Int(value.rounded()).formatted()
        case .sleep:
            let minutes = Int(value.rounded())
            let rest = String(format: "%02d", minutes % 60)
            return String(localized: "\(minutes / 60)h \(rest)")
        case .weight:
            return value.formatted(.number.precision(.fractionLength(1)))
        }
    }

    /// The line in words, which VoiceOver cannot read off the drawing.
    var trend: Text {
        guard let low = series.min(), let high = series.max() else { return Text(verbatim: "") }
        switch kind {
        case .steps, .restingHeartRate:
            return Text("Lowest \(Int(low.rounded())), highest \(Int(high.rounded())), latest \(Int(latest.rounded()))")
        case .sleep, .weight:
            return Text("Lowest \(format(low)), highest \(format(high)), latest \(format(latest))")
        }
    }
}
