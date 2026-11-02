import SwiftUI

struct BackfillScreen: View {
    /// Choosing a length is a sheet, the running backfill a pushed page (`LDRoute.backfillRun`).
    enum Stage {
        case choose, running
    }

    let stage: Stage

    var body: some View {
        switch stage {
        case .choose:
            BackfillChooseSheet()
        case .running:
            BackfillRunPage()
        }
    }
}

/// The lines about a backfill that more than one page shows.
@MainActor
enum LDBackfillStatus {
    static func windowsDone(_ job: BackfillJob, backfill: BackfillController) -> Int {
        backfill.progress?.windowsDone ?? job.nextWindow
    }

    /// The value on the Send history row, nil when nothing is going on.
    static func shortLine(_ job: BackfillJob, backfill: BackfillController) -> Text? {
        let done = windowsDone(job, backfill: backfill)
        switch job.status {
        case .running: return Text("Backfilling \(done)/\(job.windowCount)...")
        case .paused: return Text("Paused at \(done)/\(job.windowCount)")
        case .failed: return Text("Failed")
        case .done: return nil
        }
    }
}

// MARK: - Choose a length

/// The lengths a backfill can take (P2-29) with the 3-day chunks each covers. The oldest record is
/// looked up when the sheet opens; until then every length is listed, and the fixed ones that reach
/// back past it are left out after. History goes to webhooks only, so without one nothing can start.
private struct BackfillChooseSheet: View {
    @ObservedObject private var prefs = PreferencesManager.shared
    @ObservedObject private var backfill = BackfillController.shared
    @EnvironmentObject private var navigator: LDNavigator

    @State private var earliest: Date?
    @State private var lookedUp = false
    @State private var selected = 365

    var body: some View {
        LDScreen(background: LDTheme.sheet) {
            LDHeading("Send your history.")
            LDNote("Sent in 3-day chunks, oldest first. Records are never counted twice.", top: 6)
            if let job = backfill.job, job.status != .done {
                LDBanner(LDBackfillStatus.shortLine(job, backfill: backfill) ?? Text("Backfill")) {
                    LDBannerAction("View") {
                        navigator.dismissSheet { navigator.push(.backfillRun) }
                    }
                }
            } else if prefs.healthEnabledDataTypes.isEmpty {
                LDBanner("No data types selected")
            } else if prefs.healthWebhookUrls.isEmpty {
                LDBanner(prefs.mqttEnabled
                    ? "Backfill needs a webhook URL: MQTT only carries the latest value of each type"
                    : "Add a webhook URL to backfill"
                ) {
                    LDBannerAction("Add destination") {
                        navigator.dismissSheet { navigator.present(.addDestination) }
                    }
                }
            } else {
                choice
            }
        }
        .navigationTitle("Backfill")
        .ldSheetToolbar()
        .task {
            earliest = await HealthKitManager.shared.oldestSampleDate(for: prefs.healthEnabledDataTypes)
            lookedUp = true
        }
    }

    @ViewBuilder
    private var choice: some View {
        let lengths = BackfillPlan.lengths(earliest: earliest, now: Date())
        let chosen = lengths.contains(selected) ? selected : BackfillPlan.allHistory
        LDGap(12)
        LDCard {
            ForEach(lengths, id: \.self) { days in
                row(days, isChosen: days == chosen)
            }
        }
        let hosts = prefs.healthWebhookUrls.compactMap { URL(string: $0)?.host }
        if !hosts.isEmpty {
            LDNote(Text("Goes to \(hosts.formatted(.list(type: .and)))."))
        }
        LDNote("Keep your iPhone unlocked. This can take a while and use mobile data.", color: LDTheme.warningText)
        // P2-28: until the integration takes in older days, say so before someone picks All.
        LDNote("Home Assistant takes in about the last year for now. A webhook or the Life Dashboard stack gets everything.", color: LDTheme.warningText, top: 2)
        LDGap(12)
        LDButton(Text("Start, \(title(chosen))")) {
            backfill.start(days: chosen, earliest: earliest)
            navigator.dismissSheet { navigator.push(.backfillRun) }
        }
        .disabled(chosen == BackfillPlan.allHistory && earliest == nil)
    }

    private func row(_ days: Int, isChosen: Bool) -> some View {
        let unknown = days == BackfillPlan.allHistory && earliest == nil
        return LDRow(
            title(days),
            subtitle: days == BackfillPlan.allHistory ? allHistorySubtitle : nil,
            value: days == BackfillPlan.allHistory ? Text("Everything") : Text("\(BackfillPlan.windows(days: days)) chunks"),
            valueColor: isChosen ? LDTheme.accentTextSoft : LDTheme.muted,
            showsChevron: false
        )
        .ldButton { selected = days }
        .disabled(unknown)
        .opacity(unknown ? 0.45 : 1)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func title(_ days: Int) -> Text {
        switch days {
        case 30: return Text("30 days")
        case 90: return Text("90 days")
        case 180: return Text("6 months")
        case 365: return Text("1 year")
        case 730: return Text("2 years")
        case 1825: return Text("5 years")
        default: return Text("All history")
        }
    }

    private var allHistorySubtitle: Text {
        guard let earliest else {
            return lookedUp ? Text("No records found for the enabled types") : Text("Everything Apple Health has, from your oldest record")
        }
        let range = BackfillPlan.range(days: BackfillPlan.allHistory, now: Date(), earliest: earliest)
        let month = range.start.formatted(.dateTime.month(.wide).year())
        return Text("Everything since \(month), \(BackfillPlan.windowCount(of: range)) chunks of 3 days")
    }
}

// MARK: - Running

private struct BackfillRunPage: View {
    @ObservedObject private var prefs = PreferencesManager.shared
    @ObservedObject private var backfill = BackfillController.shared
    @EnvironmentObject private var navigator: LDNavigator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LDScreen {
            if let job = backfill.job {
                status(of: job)
            } else {
                LDHeading("Send your history.")
                LDGap(16)
                LDButton("Send history") { navigator.present(.backfill) }
            }
        }
        .navigationTitle("Backfill")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func status(of job: BackfillJob) -> some View {
        let done = LDBackfillStatus.windowsDone(job, backfill: backfill)
        let total = job.windowCount
        let records = backfill.progress?.recordsSent ?? job.recordsSent

        LDHeading(headline(job, done: done, total: total))
        PulseLine(variant: variant(job))
        LDProgressBar(value: Double(done) / Double(max(total, 1)))
            .accessibilityLabel("Backfill progress")
            .accessibilityValue(Text("\(done) of \(total) windows, \(records) records sent"))
        LDNote(
            Text("\(records) records sent"),
            color: job.status == .done ? LDTheme.accentTextSoft : LDTheme.secondary,
            top: 10
        )
        if let failure = failureLine(job, done: done, total: total) {
            LDNote(failure, color: LDTheme.warning)
        }
        if let caption = caption(job) {
            LDNote(caption, top: 2)
        }
        if job.truncatedWindows > 0 {
            LDNote(Text("\(job.truncatedWindows) windows could not be sent in full"), color: LDTheme.warning)
        }
        buttons(job)
    }

    @ViewBuilder
    private func buttons(_ job: BackfillJob) -> some View {
        switch job.status {
        case .running:
            LDGap(16)
            LDButton(backfill.isStopping ? Text("Pausing...") : Text("Pause"), kind: .ghost) {
                backfill.pause()
            }
            .disabled(backfill.isStopping)
            .accessibilityHint("Stops after the current chunk. You can resume later.")
            LDGap(8)
            discardButton("Stop and discard")
        case .paused, .failed:
            if let reason = resumeBlocked {
                LDNote(reason, color: LDTheme.warning)
            }
            LDGap(16)
            LDButton("Resume") {
                backfill.resume()
            }
            .disabled(resumeBlocked != nil)
            LDGap(8)
            discardButton("Discard")
        case .done:
            EmptyView()
        }
    }

    private func discardButton(_ title: LocalizedStringKey) -> some View {
        LDButton(title, kind: .danger) {
            backfill.discard()
            dismiss()
        }
        .accessibilityHint("Forgets the progress. Data already sent stays on your server.")
    }

    private var resumeBlocked: Text? {
        if prefs.healthWebhookUrls.isEmpty { return Text("Add a webhook URL to backfill") }
        if prefs.healthEnabledDataTypes.isEmpty { return Text("No data types selected") }
        return nil
    }

    private func variant(_ job: BackfillJob) -> PulseLine.Variant {
        switch job.status {
        case .running, .done: return .normal
        case .paused: return .flat
        case .failed: return .warning
        }
    }

    private func headline(_ job: BackfillJob, done: Int, total: Int) -> Text {
        switch job.status {
        case .running:
            return Text("Backfilling \(done) of \(total).")
        case .paused:
            return Text("Paused at \(done)/\(total)")
        case .failed:
            if case .read = job.failure { return Text("Stopped") }
            return Text("Delivery failed")
        case .done:
            return Text("Backfill complete")
        }
    }

    private func failureLine(_ job: BackfillJob, done: Int, total: Int) -> Text? {
        guard job.status == .failed else { return nil }
        switch job.failure {
        case .read(let type):
            // Jobs from before 1.4 stored the English display name instead of the raw value.
            let name = HealthDataType(rawValue: type).map { Text($0.displayName) } ?? Text(verbatim: type)
            return Text("Stopped after \(done) of \(total) windows: HealthKit did not return \(name).")
        case .delivery, nil:
            return Text("Delivery failed after \(done) of \(total) windows. Resume continues from there.")
        }
    }

    private func caption(_ job: BackfillJob) -> Text? {
        switch job.status {
        case .running:
            return backfill.runsInBackground
                ? Text("You can switch apps. Keep your iPhone unlocked.")
                : Text("Keep the app open. The screen stays on until the backfill is done.")
        case .paused:
            switch job.pauseReason {
            case .background: return Text("iOS pauses the backfill shortly after you leave the app.")
            case .locked: return Text("Health data can't be read while your iPhone is locked.")
            case .system: return Text("iOS stopped the backfill in the background.")
            case .closed: return Text("The app was closed before the backfill finished.")
            case .user, .interrupted, nil: return nil
            }
        case .failed, .done:
            return nil
        }
    }
}
