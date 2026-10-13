import SwiftUI

struct LogsScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared

    @State private var logs: [WebhookLog] = []
    @State private var expandedLogId: String?
    @State private var exportFileURL: URL?
    @State private var showClearConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SyncStatsCard(stats: SyncStats(logs: logs))
                ActionTileRow {
                    Menu {
                        Button {
                            export(ExportManager.shared.exportLogsToCSV(logs: logs))
                        } label: {
                            Label("Export CSV", systemImage: "tablecells")
                        }
                        Button {
                            export(ExportManager.shared.exportLogsToJSON(logs: logs))
                        } label: {
                            Label("Export JSON", systemImage: "curlybraces")
                        }
                    } label: {
                        ActionTileLabel(title: "Export logs", systemImage: "square.and.arrow.up", ink: Brand.logsInk)
                    }
                    // A menu tints its label; the tile keeps its own colours like the others.
                    .tint(Color.primary)
                    .disabled(logs.isEmpty)
                    ActionTile(title: "Clear logs", systemImage: "trash", ink: Brand.errorInk) {
                        showClearConfirm = true
                    }
                    .disabled(logs.isEmpty)
                }
                logsList
            }
            .padding(16)
            .readableWidth()
        }
        .background(Color(.systemGroupedBackground))
        .tint(Brand.logsInk)
        .screenshotScrollAnchor()
        .refreshable { refreshLogs() }
        .onAppear { refreshLogs() }
        .shareSheet(for: $exportFileURL)
        .confirmationDialog("Clear logs", isPresented: $showClearConfirm) {
            Button("Clear All Logs", role: .destructive) {
                prefs.clearWebhookLogs(filterType: nil)
                refreshLogs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every log entry. The sync history above is counted from these entries, so it starts over.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var logsList: some View {
        if logs.isEmpty {
            ContentUnavailableView(
                "No logs yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Every delivery and MQTT publish shows up here.")
            )
            .padding(.vertical, 24)
        } else {
            CardGroup {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(logs.enumerated()), id: \.element.id) { index, log in
                        if index > 0 {
                            CardDivider()
                        }
                        LogRow(
                            log: log,
                            isExpanded: expandedLogId == log.id,
                            onTap: {
                                withAnimation {
                                    expandedLogId = expandedLogId == log.id ? nil : log.id
                                }
                            },
                            onDelete: {
                                prefs.deleteWebhookLog(id: log.id)
                                refreshLogs()
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func refreshLogs() {
        logs = prefs.getWebhookLogs(filterType: nil)
    }

    private func export(_ url: URL?) {
        exportFileURL = url
    }
}

// MARK: - Subviews

/// One figure on the sync history card: the label above the number, as in the Android app.
struct StatCard: View {
    let title: LocalizedStringKey
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(verbatim: value)
                .font(.title2.bold())
                .monospacedDigit()
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A delivery in the list, laid out like the Android app's log row: where it went, when, how
/// much, and a pill that says how it went. Tap for the details and the payload.
struct LogRow: View {
    let log: WebhookLog
    let isExpanded: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var shareFileURL: URL?
    @State private var copyOutcome: PayloadCopy.Outcome?

    private var urlHost: String {
        URL(string: log.url)?.host ?? log.url
    }

    private var payloadSize: String? {
        guard let payload = log.rawPayload else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(payload.utf8.count), countStyle: .file)
    }

    private var time: String {
        log.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }

    private var subtitle: Text {
        guard let count = log.recordCount, count > 0 else { return Text(verbatim: time) }
        return log.isMqtt ? Text("\(time) · \(count) sensors") : Text("\(time) · \(count) records")
    }

    private var pill: StatusPill {
        if log.isInterrupted { return StatusPill(title: "Interrupted", tone: .info) }
        if !log.success { return StatusPill(title: "Failed", tone: .failure) }
        return log.isMqtt ? StatusPill(title: "Published", tone: .success) : StatusPill(title: "Delivered", tone: .success)
    }

    private var icon: some View {
        IconTile(systemName: log.isMqtt ? "house" : "link", tint: Brand.logs, ink: Brand.logsInk)
    }

    /// Where it went. A read failure names Apple Health, stored in English as its address.
    private var title: Text {
        if log.isMqtt { return Text(verbatim: "MQTT") }
        if log.url == SyncStats.readFailureSource { return Text("Apple Health") }
        return Text(verbatim: urlHost)
    }

    private func details(showsPill: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            subtitle
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !log.success, !log.isInterrupted, let error = log.errorMessage {
                Text(verbatim: AppDiagnostic.display(error))
                    .font(.footnote)
                    .foregroundStyle(Brand.errorInk)
                    .lineLimit(isExpanded ? nil : 1)
                    // Shortened with an ellipsis rather than deciding the layout on its own.
                    .frame(idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            if showsPill {
                pill.padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                // Dutch and German dates and counts are longer: when the row does not fit on one
                // line beside the pill, the pill moves under the text instead of squeezing it.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        icon
                        details(showsPill: false)
                        pill
                    }
                    HStack(alignment: .top, spacing: 12) {
                        icon
                        details(showsPill: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(isExpanded ? Text("Hides the details") : Text("Shows the details"))
            .accessibilityAction(named: Text("Delete"), onDelete)
            .contextMenu {
                if log.rawPayload != nil {
                    Button(action: sharePayload) {
                        Label("Share payload", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }

            if isExpanded {
                details
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        }
        .shareSheet(for: $shareFileURL)
        .onChange(of: isExpanded) { _, _ in copyOutcome = nil }
    }

    private func copyPayload() {
        guard let payload = log.rawPayload else { return }
        let outcome = PayloadCopy.copy(payload)
        copyOutcome = outcome
        AccessibilityNotification.Announcement(outcome.message).post()
    }

    /// The payload as a JSON file named after the delivery's time, not as text: a share target
    /// handles a file of any size.
    private func sharePayload() {
        guard let payload = log.rawPayload else { return }
        shareFileURL = try? ExportManager.writePayloadFile(payload, prefix: ExportManager.logPayloadPrefix, date: log.timestamp)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailRow(label: "URL", value: log.url)
            if let statusCode = log.statusCode {
                DetailRow(label: "Status", value: "\(statusCode)")
            }
            if let error = log.errorMessage {
                DetailRow(label: "Error", value: AppDiagnostic.display(error))
            }
            if let detail = log.errorDetail {
                DetailRow(label: "Details", value: detail)
            }
            if let recordCount = log.recordCount {
                DetailRow(label: log.isMqtt ? "Sensors" : "Records", value: "\(recordCount)")
            }
            if let dataType = log.dataType {
                DetailRow(label: "Type", value: dataType)
            }
            if let size = payloadSize {
                DetailRow(label: "Payload", value: size)
            }

            if let payload = log.rawPayload {
                PayloadPreviewText(
                    preview: PayloadPreview.of(payload),
                    font: .system(.caption2, design: .monospaced),
                    whereTheRestIs: Text("Use Copy payload or Share payload for the full payload.")
                )
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // Dutch and German labels are longer: when the three do not fit on one line, Delete
            // goes under the payload's two.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    payloadButtons
                    Spacer()
                    deleteButton
                }
                .frame(minHeight: 44)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 16) { payloadButtons }
                        .frame(minHeight: 44)
                    deleteButton
                        .frame(minHeight: 44)
                }
            }

            if let copyOutcome {
                PayloadCopyLine(outcome: copyOutcome)
            }
        }
    }

    @ViewBuilder
    private var payloadButtons: some View {
        if log.rawPayload != nil {
            Button(action: copyPayload) {
                Label("Copy payload", systemImage: "doc.on.doc")
                    .font(.footnote)
            }
            Button(action: sharePayload) {
                Label("Share payload", systemImage: "square.and.arrow.up")
                    .font(.footnote)
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Label("Delete", systemImage: "trash")
                .font(.footnote)
        }
        .tint(Brand.errorInk)
    }
}

/// What Copy did, under the buttons: copied for a short while, or too large for the clipboard.
struct PayloadCopyLine: View {
    let outcome: PayloadCopy.Outcome

    var body: some View {
        ResultLine(text: Text(verbatim: outcome.message), tone: outcome == .copied ? .success : .warning)
    }
}

/// A payload on screen, capped like the Android app (P2-11): at most 12,000 characters, a line
/// that says how many there are and where the rest is, and for VoiceOver the size instead of the
/// whole text. The lines under it stay readable on their own.
struct PayloadPreviewText: View {
    let preview: PayloadPreview
    let font: Font
    /// Where the rest of a payload cut for display is, in the words of the screen's own button.
    let whereTheRestIs: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: preview.text)
                .font(font)
                .accessibilityLabel(Text("Payload, \(preview.totalCount.formatted()) characters"))
            if preview.cutForDisplay || preview.cutInStorage {
                VStack(alignment: .leading, spacing: 2) {
                    if preview.cutForDisplay {
                        Text("Showing the first \(PayloadPreview.maxCharacters.formatted()) of \(preview.totalCount.formatted()) characters.")
                    }
                    // A payload the log cut short is shared cut short too, so Share is no answer.
                    if preview.cutInStorage {
                        Text("Only the first \(LogStore.maxRawPayloadCharacters.formatted()) characters of this payload were stored.")
                    } else {
                        whereTheRestIs
                    }
                }
                .font(.caption2)
            }
        }
    }
}

struct DetailRow: View {
    let label: LocalizedStringKey
    let value: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        layout {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
                .frame(minWidth: 64, alignment: .leading)
            Text(verbatim: value)
                .font(.caption)
                .lineLimit(3)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ShareSheet (UIKit bridge)

extension View {
    /// The share sheet for a file, open while `url` holds one.
    func shareSheet(for url: Binding<URL?>) -> some View {
        sheet(isPresented: Binding(get: { url.wrappedValue != nil }, set: { if !$0 { url.wrappedValue = nil } })) {
            if let file = url.wrappedValue {
                ShareSheet(activityItems: [file])
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
