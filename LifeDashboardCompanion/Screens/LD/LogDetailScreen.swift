import SwiftUI

/// One delivery with everything the log stores about it. Duration, response body and attempt count
/// are not stored, and a row cannot be sent again, so the board's fields and Try again are not here.
struct LogDetailScreen: View {
    /// WebhookLog.id of the row to show.
    let logID: String

    @ObservedObject private var prefs = PreferencesManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var log: WebhookLog?
    @State private var preview: PayloadPreview?
    @State private var shareFileURL: URL?
    @State private var copyOutcome: PayloadCopy.Outcome?

    var body: some View {
        LDScreen {
            if let log {
                content(log)
            } else {
                LDHeading("Delivery")
                LDNote("This delivery is no longer in the log.", top: 4)
            }
        } footer: {
            if let log, log.rawPayload != nil {
                footer(log)
            }
        }
        .navigationTitle("Delivery")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .shareSheet(for: $shareFileURL)
    }

    // MARK: - Sections

    @ViewBuilder
    private func content(_ log: WebhookLog) -> some View {
        LDHeading(Text(verbatim: headline(log)))
        if let note = note(log) {
            LDNote(note, color: log.success ? LDTheme.accentTextSoft : LDTheme.warningText, top: 4)
        }
        LDGap(8)
        LDKeyValueList(facts(log))
        if let preview {
            LDGap(14)
            LDSectionLabel("Payload")
            payloadBlock(preview)
            payloadNotes(preview)
        }
        LDGap(14)
        LDButton("Delete", kind: .danger, size: .medium) { delete(log) }
    }

    private func headline(_ log: WebhookLog) -> String {
        if log.isMqtt { return "MQTT \(log.ldOutcome)" }
        if let statusCode = log.statusCode { return "\(statusCode) \(log.ldOutcome)" }
        return log.ldOutcome
    }

    /// Only what the row can back up. A failure without a status code had no answer to go on, its
    /// reason is under Error.
    private func note(_ log: WebhookLog) -> Text? {
        if log.isMqtt { return log.success ? Text("The broker accepted this publish.") : nil }
        if log.success { return Text("\(log.ldDestination) accepted this delivery.") }
        return log.statusCode == nil ? nil : Text("\(log.ldDestination) did not accept this delivery.")
    }

    private func facts(_ log: WebhookLog) -> [LDKeyValue] {
        let problem = log.success ? LDTheme.text : LDTheme.warningText
        var items = [
            LDKeyValue("Time", Text(verbatim: log.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))),
            LDKeyValue("URL", Text(verbatim: log.url), isCode: true)
        ]
        if let statusCode = log.statusCode {
            items.append(LDKeyValue("Status", Text(verbatim: "\(statusCode)"), color: problem))
        }
        if let error = log.errorMessage {
            items.append(LDKeyValue("Error", Text(verbatim: AppDiagnostic.display(error)), color: problem))
        }
        if let detail = log.errorDetail {
            items.append(LDKeyValue("Details", Text(verbatim: detail), color: problem))
        }
        if let recordCount = log.recordCount {
            items.append(LDKeyValue(log.isMqtt ? "Sensors" : "Records", Text(verbatim: "\(recordCount)")))
        }
        if let dataType = log.dataType {
            items.append(LDKeyValue("Type", Text(verbatim: dataType), isCode: true))
        }
        if let size = log.ldPayloadSize {
            items.append(LDKeyValue("Payload size", Text(verbatim: size)))
        }
        return items
    }

    private func payloadBlock(_ preview: PayloadPreview) -> some View {
        LDCodeBlock(text: preview.text, wraps: true, selectable: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Payload, \(preview.totalCount.formatted()) characters"))
    }

    @ViewBuilder
    private func payloadNotes(_ preview: PayloadPreview) -> some View {
        if preview.cutForDisplay {
            LDNote(Text("Showing the first \(PayloadPreview.maxCharacters.formatted()) of \(preview.totalCount.formatted()) characters."), color: LDTheme.muted, size: 13)
        }
        // A payload the log cut short is shared cut short too, so Share is no answer.
        if preview.cutInStorage {
            LDNote(Text("Only the first \(LogStore.maxRawPayloadCharacters.formatted()) characters of this payload were stored."), color: LDTheme.muted, size: 13)
        } else if preview.cutForDisplay {
            LDNote("Use Copy payload or Share payload for the full payload.", color: LDTheme.muted, size: 13)
        }
    }

    private func footer(_ log: WebhookLog) -> some View {
        VStack(spacing: 0) {
            if let copyOutcome {
                LogResultLine(text: Text(verbatim: copyOutcome.message), isGood: copyOutcome == .copied)
            }
            LDFooterBar {
                LDButton("Copy payload", kind: .ghost, size: .medium, inset: 0) { copy(log) }
                LDButton("Share payload", kind: .ghost, size: .medium, inset: 0) {
                    shareFileURL = log.ldPayloadFile()
                }
            }
        }
    }

    // MARK: - Actions

    private func load() {
        log = prefs.getWebhookLogs(filterType: nil).first { $0.id == logID }
        preview = log?.rawPayload.map { PayloadPreview.of($0) }
    }

    private func copy(_ log: WebhookLog) {
        guard let payload = log.rawPayload else { return }
        let outcome = PayloadCopy.copy(payload)
        copyOutcome = outcome
        AccessibilityNotification.Announcement(outcome.message).post()
    }

    private func delete(_ log: WebhookLog) {
        prefs.deleteWebhookLog(id: log.id)
        dismiss()
    }
}
