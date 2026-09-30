import SwiftUI

struct LogsScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared

    @State private var logs: [WebhookLog] = []
    @State private var expandedLogId: String?
    @State private var showExportSheet = false
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
        .sheet(isPresented: $showExportSheet) {
            if let url = exportFileURL {
                ShareSheet(activityItems: [url])
            }
        }
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
        guard let url else { return }
        exportFileURL = url
        showExportSheet = true
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
                if let payload = log.rawPayload {
                    ShareLink(item: payload) {
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
                Text(verbatim: payload.count > 1500
                     ? String(payload.prefix(1500)) + "\n" + String(localized: "... [share for the full payload]")
                     : payload)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack {
                if let payload = log.rawPayload {
                    ShareLink(item: payload) {
                        Label("Share payload", systemImage: "square.and.arrow.up")
                            .font(.footnote)
                    }
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                        .font(.footnote)
                }
                .tint(Brand.errorInk)
            }
            .frame(minHeight: 44)
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

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
