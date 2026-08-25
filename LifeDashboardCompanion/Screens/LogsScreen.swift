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
            VStack(alignment: .leading, spacing: 16) {
                statsSection
                logsListSection
            }
            .padding()
        }
        .onAppear { refreshLogs() }
        .sheet(isPresented: $showExportSheet) {
            if let url = exportFileURL {
                ShareSheet(activityItems: [url])
            }
        }
        .confirmationDialog("Clear Logs", isPresented: $showClearConfirm) {
            Button("Clear All Logs", role: .destructive) {
                prefs.clearWebhookLogs(filterType: nil)
                refreshLogs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the selected logs.")
        }
    }

    // MARK: - Sections

    private var statsSection: some View {
        let successCount = logs.filter(\.success).count
        let failureCount = logs.filter { !$0.success }.count
        let totalRecords = logs.compactMap(\.recordCount).reduce(0, +)

        return VStack(alignment: .leading, spacing: 8) {
            Label("Statistics", systemImage: "chart.bar.fill")
                .font(.headline)

            HStack(spacing: 16) {
                StatCard(title: "Total", value: "\(logs.count)", color: .blue)
                StatCard(title: "Success", value: "\(successCount)", color: .green)
                StatCard(title: "Failed", value: "\(failureCount)", color: .red)
                StatCard(title: "Records", value: "\(totalRecords)", color: .purple)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var logsListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Logs (\(logs.count))", systemImage: "doc.text.fill")
                    .font(.headline)

                Spacer()

                Menu {
                    Button {
                        if let url = ExportManager.shared.exportLogsToCSV(logs: logs) {
                            exportFileURL = url
                            showExportSheet = true
                        }
                    } label: {
                        Label("Export CSV", systemImage: "tablecells")
                    }

                    Button {
                        if let url = ExportManager.shared.exportLogsToJSON(logs: logs) {
                            exportFileURL = url
                            showExportSheet = true
                        }
                    } label: {
                        Label("Export JSON", systemImage: "curlybraces")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear Logs", systemImage: "trash.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title3)
                }
            }

            if logs.isEmpty {
                Text("No logs yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(logs) { log in
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
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Helpers

    private func refreshLogs() {
        logs = prefs.getWebhookLogs(filterType: nil)
    }
}

// MARK: - Subviews

struct StatCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct LogRow: View {
    let log: WebhookLog
    let isExpanded: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .medium
        return df
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onTap) {
                HStack {
                    Circle()
                        .fill(log.success ? Color.green : Color.red)
                        .frame(width: 8, height: 8)

                    Text(log.logType.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .cornerRadius(4)

                    if let statusCode = log.statusCode {
                        Text("\(statusCode)")
                            .font(.caption)
                            .foregroundColor(log.success ? .green : .red)
                    }

                    Spacer()

                    Text(dateFormatter.string(from: log.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    DetailRow(label: "URL", value: log.url)
                    if let statusCode = log.statusCode {
                        DetailRow(label: "Status", value: "\(statusCode)")
                    }
                    DetailRow(label: "Success", value: log.success ? "Yes" : "No")
                    if let error = log.errorMessage {
                        DetailRow(label: "Error", value: error)
                    }
                    if let recordCount = log.recordCount {
                        DetailRow(label: "Records", value: "\(recordCount)")
                    }

                    HStack {
                        Spacer()
                        Button(role: .destructive, action: onDelete) {
                            Label("Delete", systemImage: "trash")
                                .font(.caption)
                        }
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(8)
        .background(Color(.systemBackground))
        .cornerRadius(8)
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.caption2)
                .lineLimit(3)
        }
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
