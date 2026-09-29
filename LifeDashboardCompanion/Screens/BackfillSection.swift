import SwiftUI

/// The Backfill History button, its dialog and the status of a running or unfinished backfill.
/// Kept in one view so the Health screen places it with one line.
struct BackfillSection: View {
    @ObservedObject var prefs: PreferencesManager
    @ObservedObject private var backfill = BackfillController.shared

    @State private var showDialog = false
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 8) {
            if let job = backfill.job, job.status != .done {
                status(of: job)
            } else {
                startButton
                if let job = backfill.job, job.status == .done {
                    doneLine(job)
                }
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog("Backfill History", isPresented: $showDialog, titleVisibility: .visible) {
            ForEach(BackfillController.rangeOptions, id: \.self) { days in
                Button("Last \(days) days") {
                    backfill.start(days: days)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(dialogMessage)
        }
    }

    // MARK: - Start

    private var startButton: some View {
        Button {
            if prefs.healthWebhookUrls.isEmpty {
                // History goes to webhooks; MQTT only holds the latest value of each type.
                notice = prefs.mqttEnabled
                    ? "Backfill needs a webhook URL: MQTT only carries the latest value of each type"
                    : "Add a webhook URL to backfill"
            } else {
                notice = nil
                showDialog = true
            }
        } label: {
            Label("Backfill History", systemImage: "clock.arrow.circlepath")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(prefs.healthEnabledDataTypes.isEmpty)
    }

    private var dialogMessage: String {
        var message = "Sends historical data for all enabled types to your webhooks in 3-day chunks, oldest first. "
            + "Regular syncing is unaffected; overlapping records deduplicate on their uuid. "
            + "Keep your iPhone unlocked: Health data can't be read while it's locked. "
            + "This can take a while and use mobile data."
        let hosts = prefs.healthWebhookUrls.compactMap { URL(string: $0)?.host }
        if !hosts.isEmpty {
            message += "\n\nGoes to \(hosts.joined(separator: ", "))."
        }
        return message
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
                        .foregroundColor(.red)
                }
                Text(headline(job, done: done, total: total))
                    .font(.subheadline.weight(.medium))
            }
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .accessibilityLabel("Backfill progress")
                .accessibilityValue("\(done) of \(total) windows, \(records) records sent")
            Text(recordsLine(records))
                .font(.caption)
                .foregroundColor(.secondary)
            if let caption = caption(job) {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(job.status == .failed ? .red : .secondary)
            }
            if job.truncatedWindows > 0 {
                Text(job.truncatedWindows == 1
                     ? "1 window could not be sent in full"
                     : "\(job.truncatedWindows) windows could not be sent in full")
                    .font(.caption)
                    .foregroundColor(.orange)
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

    private func headline(_ job: BackfillJob, done: Int, total: Int) -> String {
        switch job.status {
        case .running, .done:
            return "Backfilling \(done)/\(total)..."
        case .paused:
            return "Paused at \(done)/\(total)"
        case .failed:
            switch job.failure {
            case .read(let type):
                return "Stopped after \(done) of \(total) windows: HealthKit did not return \(type)."
            case .delivery, nil:
                return "Delivery failed after \(done) of \(total) windows. Resume continues from there."
            }
        }
    }

    private func caption(_ job: BackfillJob) -> String? {
        switch job.status {
        case .running:
            return "Keep the app open. The screen stays on until the backfill is done."
        case .paused:
            switch job.pauseReason {
            case .background: return "iOS pauses the backfill shortly after you leave the app."
            case .locked: return "Health data can't be read while your iPhone is locked."
            case .system: return "iOS stopped the backfill in the background."
            case .closed: return "The app was closed before the backfill finished."
            case .user, .interrupted, nil: return nil
            }
        case .failed, .done:
            return nil
        }
    }

    private func recordsLine(_ records: Int) -> String {
        records == 1 ? "1 record sent" : "\(records) records sent"
    }

    private func doneLine(_ job: BackfillJob) -> some View {
        Text(job.recordsSent == 1
             ? "Backfill complete: 1 record sent"
             : "Backfill complete: \(job.recordsSent) records sent")
            .font(.caption)
            .foregroundColor(.green)
            .frame(maxWidth: .infinity)
    }
}
