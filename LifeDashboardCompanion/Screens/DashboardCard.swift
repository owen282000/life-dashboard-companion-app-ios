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
            #if DEBUG
            // For screenshots: the simulator has no Health data, so -ld.demoSteps "5200,7100,..."
            // stands in for the last seven daily step totals.
            if let demo = UserDefaults.standard.string(forKey: "ld.demoSteps") {
                stepsPerDay = demo.split(separator: ",").compactMap { Int($0) }
            }
            #endif
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

/// The iPhone half of Android's battery card (P2-27), above the dashboard on the Health screen.
/// iOS has no battery optimization per app, but two settings hold background syncs the same way:
/// Background App Refresh off (a card, until "Don't show again"), and Low Power Mode on (one
/// line, since it switches itself off). And when nothing was delivered for longer than the
/// schedule explains (`SyncHealthCheck`), a line that says since when, with the likely cause.
/// Checked again whenever the app comes to the foreground or either setting changes.
struct SyncHoldCard: View {
    static let troubleshootingURL = URL(string: "https://owen282000.com/life-dashboard/troubleshooting/")!

    @ObservedObject private var prefs = PreferencesManager.shared
    // UI state, not a setting, so it stays out of PreferencesManager and the settings backup.
    @AppStorage("refresh_hint_dismissed") private var refreshHintDismissed = false
    @State private var refreshOff = false
    @State private var lowPower = false
    @State private var overdueSince: Date?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if prefs.healthSyncConfigured {
                if showsRefreshCard {
                    refreshCard
                }
                if lowPower {
                    Label("Low Power Mode is on, so syncs can wait until it switches off.", systemImage: "battery.25percent")
                        .font(.footnote)
                        .foregroundStyle(Brand.warningInk)
                }
                // With the card showing, the card says since when; the banner would say it twice.
                if let overdueSince, !showsRefreshCard {
                    NoticeBanner(text: overdueText(since: overdueSince), tone: .warning) { EmptyView() }
                }
            }
        }
        .padding(.bottom, showsSomething ? 12 : 0)
        .onAppear(perform: check)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { check() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)) { _ in check() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in check() }
    }

    private var showsRefreshCard: Bool { refreshOff && !refreshHintDismissed }

    private var showsSomething: Bool {
        prefs.healthSyncConfigured && (showsRefreshCard || lowPower || overdueSince != nil)
    }

    private var refreshCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Background App Refresh is off")
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Brand.warningInk)
            }
            Text("iOS holds background syncs until you open the app. Allow Background App Refresh for Life Dashboard.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let overdueSince {
                Text("Nothing delivered since \(overdueSince.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.warningInk)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { refreshActions }
                VStack(alignment: .leading, spacing: 8) { refreshActions }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var refreshActions: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(Brand.warningInk)
        Button("Help for your phone") { openURL(SyncHoldCard.troubleshootingURL) }
            .font(.footnote.weight(.semibold))
        Button("Don't show again") { refreshHintDismissed = true }
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func overdueText(since: Date) -> Text {
        let day = since.formatted(date: .abbreviated, time: .omitted)
        switch SyncHealthCheck.cause(refreshOff: refreshOff, lowPower: lowPower) {
        case .refreshOff: return Text("Nothing delivered since \(day). Background App Refresh is off for Life Dashboard.")
        case .lowPower: return Text("Nothing delivered since \(day). Low Power Mode may be holding the syncs.")
        case .unknown: return Text("Nothing delivered since \(day). The Logs tab shows what happened.")
        }
    }

    private func check() {
        refreshOff = UIApplication.shared.backgroundRefreshStatus != .available
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let delivered = SharedSyncStatus.read().lastDelivered
        overdueSince = SyncHealthCheck.isOverdue(
            lastDelivered: delivered, now: Date(), schedule: prefs.healthSyncSchedule,
            hasDestination: prefs.healthSyncConfigured, timeZone: .current
        ) ? delivered : nil
        #if DEBUG
        // For screenshots: -ld.holds "refresh,power,quiet" shows the card and both lines.
        if let holds = UserDefaults.standard.string(forKey: "ld.holds")?.split(separator: ",").map(String.init) {
            refreshOff = holds.contains("refresh")
            lowPower = holds.contains("power")
            overdueSince = holds.contains("quiet") ? Date().addingTimeInterval(-3 * 86400) : nil
        }
        #endif
    }
}
