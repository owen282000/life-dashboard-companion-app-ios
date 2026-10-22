import SwiftUI

/// The Backfill tile in the Health screen's action row. It opens the range dialog that
/// `BackfillSection` shows, or says why a backfill cannot start.
struct BackfillTile: View {
    @ObservedObject var prefs: PreferencesManager
    @Binding var showDialog: Bool
    @Binding var notice: String?
    @ObservedObject private var backfill = BackfillController.shared

    var body: some View {
        ActionTile(title: "Backfill", systemImage: "clock.arrow.circlepath") {
            if prefs.healthWebhookUrls.isEmpty {
                // History goes to webhooks; MQTT only holds the latest value of each type.
                notice = prefs.mqttEnabled
                    ? String(localized: "Backfill needs a webhook URL: MQTT only carries the latest value of each type")
                    : String(localized: "Add a webhook URL to backfill")
            } else {
                notice = nil
                showDialog = true
            }
        }
        // A backfill that is running or waiting continues from its own status below.
        .disabled(prefs.healthEnabledDataTypes.isEmpty || backfill.job.map { $0.status != .done } ?? false)
    }
}

/// The backfill range dialog and the status of a running, paused or finished backfill. The
/// tile that starts it sits in the action row, so the Health screen places both.
struct BackfillSection: View {
    @ObservedObject var prefs: PreferencesManager
    @Binding var showDialog: Bool
    @Binding var notice: String?
    @ObservedObject private var backfill = BackfillController.shared

    var body: some View {
        VStack(spacing: 8) {
            if let job = backfill.job, job.status != .done {
                status(of: job)
                    .cardStyle()
            } else if let job = backfill.job, job.status == .done {
                doneLine(job)
            }
            if let notice {
                ResultLine(text: Text(notice), tone: .warning)
            }
        }
        .sheet(isPresented: $showDialog) {
            BackfillLengthSheet(enabledTypes: prefs.healthEnabledDataTypes, message: dialogMessage) { days, earliest in
                backfill.start(days: days, earliest: earliest)
            }
        }
    }

    private var dialogMessage: Text {
        let hosts = prefs.healthWebhookUrls.compactMap { URL(string: $0)?.host }
        guard !hosts.isEmpty else {
            return Text("Sends historical data for all enabled types to your webhooks in 3-day chunks, oldest first. Regular syncing is unaffected; overlapping records deduplicate on their uuid. Keep your iPhone unlocked: Health data can't be read while it's locked. This can take a while and use mobile data.")
        }
        return Text("Sends historical data for all enabled types to your webhooks in 3-day chunks, oldest first. Regular syncing is unaffected; overlapping records deduplicate on their uuid. Keep your iPhone unlocked: Health data can't be read while it's locked. This can take a while and use mobile data.\n\nGoes to \(hosts.formatted(.list(type: .and))).")
    }

    // MARK: - Status

    @ViewBuilder
    private func status(of job: BackfillJob) -> some View {
        let done = backfill.progress?.windowsDone ?? job.nextWindow
        let total = job.windowCount
        let records = backfill.progress?.recordsSent ?? job.recordsSent

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if job.status == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Brand.errorInk)
                }
                headline(job, done: done, total: total)
                    .font(.subheadline.weight(.medium))
            }
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .accessibilityLabel("Backfill progress")
                .accessibilityValue(Text("\(done) of \(total) windows, \(records) records sent"))
            Text("\(records) records sent")
                .font(.caption)
                .foregroundColor(.secondary)
            if let caption = caption(job) {
                caption
                    .font(.caption)
                    .foregroundColor(job.status == .failed ? Brand.errorInk : .secondary)
            }
            if job.truncatedWindows > 0 {
                Text("\(job.truncatedWindows) windows could not be sent in full")
                    .font(.caption)
                    .foregroundColor(Brand.warningInk)
            }
            buttons(job)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func buttons(_ job: BackfillJob) -> some View {
        HStack {
            if job.status == .running {
                Button(backfill.isStopping ? "Pausing..." : "Pause") {
                    backfill.pause()
                }
                .disabled(backfill.isStopping)
                .accessibilityHint("Stops after the current chunk. You can resume later.")
            } else {
                Button("Resume") {
                    backfill.resume()
                }
                .disabled(prefs.healthWebhookUrls.isEmpty || prefs.healthEnabledDataTypes.isEmpty)
                Button("Discard", role: .destructive) {
                    backfill.discard()
                }
                .accessibilityHint("Forgets the progress. Data already sent stays on your server.")
            }
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }

    private func headline(_ job: BackfillJob, done: Int, total: Int) -> Text {
        switch job.status {
        case .running, .done:
            return Text("Backfilling \(done)/\(total)...")
        case .paused:
            return Text("Paused at \(done)/\(total)")
        case .failed:
            switch job.failure {
            case .read(let type):
                // Jobs from before 1.4 stored the English display name instead of the raw value.
                let name = HealthDataType(rawValue: type).map { Text($0.displayName) } ?? Text(verbatim: type)
                return Text("Stopped after \(done) of \(total) windows: HealthKit did not return \(name).")
            case .delivery, nil:
                return Text("Delivery failed after \(done) of \(total) windows. Resume continues from there.")
            }
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

    private func doneLine(_ job: BackfillJob) -> some View {
        Text("Backfill complete: \(job.recordsSent) records sent")
            .font(.caption)
            .foregroundColor(Brand.successInk)
            .frame(maxWidth: .infinity)
    }
}

/// The lengths a backfill can take (P2-29), as on Android since 1.28.0: 30 and 90 days, 6 months,
/// 1, 2 and 5 years, and All history from the oldest record of the enabled types, each with the
/// number of 3-day chunks it covers. The oldest record is looked up when the list opens; until
/// then every length is listed, and the fixed ones that reach back past it are left out after.
struct BackfillLengthSheet: View {
    let enabledTypes: Set<HealthDataType>
    let message: Text
    let onStart: (Int, Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var earliest: Date?
    @State private var lookedUp = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    message
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(BackfillPlan.lengths(earliest: earliest, now: Date()), id: \.self) { days in
                        Button {
                            onStart(days, earliest)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                title(days)
                                    .font(.body)
                                    .foregroundStyle(Brand.ink)
                                subtitle(days)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(days == BackfillPlan.allHistory && earliest == nil)
                    }
                }
            }
            .navigationTitle("Backfill History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            earliest = await HealthKitManager.shared.oldestSampleDate(for: enabledTypes)
            lookedUp = true
        }
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

    private func subtitle(_ days: Int) -> Text {
        guard days == BackfillPlan.allHistory else {
            return Text("\(BackfillPlan.windows(days: days)) chunks of 3 days")
        }
        guard let earliest else {
            return lookedUp ? Text("No records found for the enabled types") : Text("Everything Apple Health has, from your oldest record")
        }
        let range = BackfillPlan.range(days: days, now: Date(), earliest: earliest)
        let month = range.start.formatted(.dateTime.month(.wide).year())
        return Text("Everything since \(month), \(BackfillPlan.windowCount(of: range)) chunks of 3 days")
    }
}
