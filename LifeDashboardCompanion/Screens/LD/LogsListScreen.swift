import SwiftUI

private let logDateFormat = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()

/// The Logs tab, for developers who scan: one row per delivery with what the log stores. Duration,
/// response body and attempt count are not stored, so they are not here.
struct LogsListScreen: View {
    private enum Filter: Hashable {
        case all, failed, webhook, mqtt

        func includes(_ log: WebhookLog) -> Bool {
            switch self {
            case .all: return true
            case .failed: return log.ldIsFailure
            case .webhook: return log.ldIsWebhook
            case .mqtt: return log.isMqtt
            }
        }
    }

    @ObservedObject private var prefs = PreferencesManager.shared

    @State private var logs: [WebhookLog] = []
    @State private var stats = SyncStats(logs: [])
    @State private var pendingCount = 0
    @State private var filter = Filter.all
    @State private var showsHistory = false
    @State private var shareFileURL: URL?
    @State private var showClearConfirm = false
    @State private var isSendingTest = false
    @State private var testDelivered: Bool?

    private var failedCount: Int { logs.filter(\.ldIsFailure).count }
    private var deliveredCount: Int { logs.filter(\.success).count }

    var body: some View {
        LDScreen {
            if logs.isEmpty {
                LDHeading("Nothing sent yet.")
                subLine
                LDNote("Every delivery and MQTT publish shows up here.", top: 6)
                LDNote(Text("The list keeps the last \(LogStore.maxLogs)."), top: 0)
            } else {
                LDHeading(Text("\(failedCount) failed, \(deliveredCount) delivered."))
                subLine
                history
                filters
                LDGap(10)
                rows
            }
        } footer: {
            footer
        }
        .refreshable { refreshLogs() }
        .onAppear { refreshLogs() }
        .shareSheet(for: $shareFileURL)
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

    // MARK: - Above the rows

    private var subLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            LDSeparatedText(stateLine)
            if !logs.isEmpty {
                if let lastSuccess = stats.lastSuccess {
                    Text("Last success: \(lastSuccess.formatted(logDateFormat))")
                } else {
                    Text("Last success: never")
                }
            }
        }
        .font(LDType.monoValue)
        .foregroundStyle(LDTheme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .padding(.horizontal, LDTheme.textInset)
        .padding(.bottom, 12)
    }

    private var stateLine: String {
        let outbox = pendingCount == 0 ? String(localized: "Outbox empty") : String(localized: "\(pendingCount) pending")
        guard let percent = stats.successPercent else { return outbox }
        return outbox + " · " + String(localized: "\(percent)% success")
    }

    /// The figures and failure groups of the old Sync History card, folded so the rows stay high
    /// on the screen.
    @ViewBuilder
    private var history: some View {
        if !stats.isEmpty {
            Button {
                showsHistory.toggle()
            } label: {
                HStack(spacing: 8) {
                    if stats.recentFailures.isEmpty {
                        Text("Sync History")
                    } else {
                        Text("Recent failures")
                        Text(verbatim: stats.recentFailures.count.formatted())
                            .font(LDType.mono(13, bold: true))
                            .foregroundStyle(LDTheme.warning)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: showsHistory ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LDTheme.muted)
                        .accessibilityHidden(true)
                }
                .font(LDType.sectionLabel)
                .foregroundStyle(LDTheme.text)
                .frame(minHeight: 44)
                .padding(.horizontal, LDTheme.textInset)
                .contentShape(Rectangle())
            }
            .buttonStyle(.ldPress)
            .accessibilityElement(children: .combine)
            .accessibilityValue(showsHistory ? Text("Expanded") : Text("Collapsed"))
            .accessibilityHint(showsHistory ? Text("Hides the details") : Text("Shows the details"))

            if showsHistory {
                historyDetails
            }
        }
    }

    private var historyDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                if let since = stats.since {
                    Text("Since \(since.formatted(logDateFormat))")
                }
                LDSeparatedText(String(localized: "Deliveries") + " \(stats.deliveries.formatted()) · "
                    + String(localized: "Records") + " \(stats.records.formatted())")
                if stats.mqttDeliveries > 0 {
                    LDSeparatedText(String(localized: "Webhook \(stats.webhookSucceeded) / \(stats.webhookDeliveries) · MQTT \(stats.mqttSucceeded) / \(stats.mqttDeliveries)"))
                }
            }
            .font(LDType.mono(12))
            .foregroundStyle(LDTheme.secondary)
            .padding(.horizontal, LDTheme.textInset)

            ForEach(stats.recentFailures) { failure in
                LogFailureGroupLine(failure: failure)
                    .ldLink(to: .logDetail(id: failure.logId))
            }
        }
        .padding(.bottom, 10)
    }

    private var filters: some View {
        LDChips {
            LDChip("All", isSelected: filter == .all) { filter = .all }
            LDChip(Text("Failed \(failedCount)"), isSelected: filter == .failed) { filter = .failed }
            LDChip("Webhook", isSelected: filter == .webhook) { filter = .webhook }
            LDChip("MQTT", isSelected: filter == .mqtt) { filter = .mqtt }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private var rows: some View {
        let shown = logs.filter(filter.includes)
        LDHairline()
        if shown.isEmpty {
            LDNote("No logs match this filter.", top: 12)
        }
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, log in
            if let day = dayHeader(at: index, in: shown) {
                LogDayHeader(text: day)
            }
            row(log)
                .ldStaggerRise(index)
        }
    }

    private func row(_ log: WebhookLog) -> some View {
        LogDeliveryRow(log: log)
            .ldLink(to: .logDetail(id: log.id))
            .accessibilityHint(Text("Shows the details"))
            .accessibilityAction(named: Text("Delete")) { delete(log) }
            .contextMenu {
                if log.rawPayload != nil {
                    Button { share(log) } label: {
                        Label("Share payload", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) { delete(log) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    /// The rows show a time only, and the log can go back days: every day but today gets a line
    /// above its first row.
    private func dayHeader(at index: Int, in shown: [WebhookLog]) -> String? {
        let day = shown[index].timestamp
        let calendar = Calendar.current
        let startsDay = index == 0 || !calendar.isDate(shown[index - 1].timestamp, inSameDayAs: day)
        guard startsDay else { return nil }
        if calendar.isDateInToday(day) { return nil }
        return day.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if let testDelivered {
                LogResultLine(
                    text: testDelivered ? Text("Test ping delivered") : Text("Test ping failed, check the logs"),
                    isGood: testDelivered
                )
            }
            LDFooterBar {
                LDButton("Send test", kind: .ghost, size: .small, inset: 0, action: sendTest)
                    .disabled(prefs.healthWebhookUrls.isEmpty || isSendingTest)
                exportMenu
                LDButton("Clear", kind: .ghost, size: .small, inset: 0) {
                    showClearConfirm = true
                }
                .disabled(logs.isEmpty)
            }
        }
    }

    /// A Menu keeps its own look under LDButtonStyle, so its label draws the small ghost capsule.
    private var exportMenu: some View {
        Menu {
            Button {
                shareFileURL = ExportManager.shared.exportLogsToCSV(logs: logs)
            } label: {
                Label("Export CSV", systemImage: "tablecells")
            }
            Button {
                shareFileURL = ExportManager.shared.exportLogsToJSON(logs: logs)
            } label: {
                Label("Export JSON", systemImage: "curlybraces")
            }
        } label: {
            Text("Export")
                .font(LDType.sans(LDButtonSize.small.fontSize, .medium, relativeTo: .subheadline))
                .foregroundStyle(LDTheme.text)
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: LDButtonSize.small.height)
                .overlay {
                    Capsule().strokeBorder(LDTheme.ghostBorder, lineWidth: 1)
                }
                .contentShape(Capsule())
                .opacity(logs.isEmpty ? 0.45 : 1)
        }
        .tint(LDTheme.text)
        .disabled(logs.isEmpty)
    }

    // MARK: - Actions

    private func refreshLogs() {
        logs = prefs.getWebhookLogs(filterType: nil)
        stats = SyncStats(logs: logs)
        pendingCount = PendingSyncStore.shared.pendingCount
    }

    private func delete(_ log: WebhookLog) {
        prefs.deleteWebhookLog(id: log.id)
        refreshLogs()
    }

    private func share(_ log: WebhookLog) {
        shareFileURL = log.ldPayloadFile()
    }

    private func sendTest() {
        isSendingTest = true
        testDelivered = nil
        Task {
            let delivered = await TestPing.send(prefs: prefs)
            await MainActor.run {
                isSendingTest = false
                testDelivered = delivered
                refreshLogs()
                if let delivered {
                    let outcome: SyncOutcome = delivered ? .pingDelivered : .pingFailed
                    AccessibilityNotification.Announcement(outcome.announcement).post()
                }
            }
        }
    }
}

// MARK: - What the screens say about a row

extension WebhookLog {
    /// Interrupted says nothing about the receiver, so it is not a failure.
    var ldIsFailure: Bool { !success && !isInterrupted }

    /// A webhook row, also a failed backfill run, which the sync figures leave out.
    var ldIsWebhook: Bool {
        guard !isMqtt, syncKind != .readFailure else { return false }
        return destination == nil || destination == LogDestination.webhook.rawValue
    }

    /// The fixed column: the status code, MQTT, or a short mark when no answer came.
    var ldCode: String {
        if isMqtt { return "MQTT" }
        if let statusCode { return "\(statusCode)" }
        if isInterrupted { return "---" }
        return success ? "OK" : "ERR"
    }

    var ldCodeColor: Color {
        if ldIsFailure { return LDTheme.warning }
        return isInterrupted ? LDTheme.muted : LDTheme.accentText
    }

    /// How it went, in the words of the old status pill.
    var ldOutcome: String {
        if isInterrupted { return String(localized: "Interrupted") }
        if !success { return String(localized: "Failed") }
        return isMqtt ? String(localized: "Published") : String(localized: "Delivered")
    }

    /// Where it went, never the full URL: a webhook URL can hold a secret id. A sync row can
    /// name several URLs, a read failure stores "Apple Health" as its address.
    var ldDestination: String {
        if url == SyncStats.readFailureSource { return String(localized: "Apple Health") }
        if isMqtt { return URL(string: url)?.host ?? SyncStats.mqttSource }
        return url.components(separatedBy: ", ")
            .map { URL(string: $0)?.host ?? $0 }
            .joined(separator: ", ")
    }

    var ldPayloadSize: String? {
        rawPayload.map { ByteCountFormatter.string(fromByteCount: Int64($0.utf8.count), countStyle: .file) }
    }

    private var ldTypeLabel: String {
        if syncKind == .readFailure { return String(localized: "Apple Health") }
        switch dataType {
        case nil, "health_connect", "mqtt": return String(localized: "Health")
        case "test": return String(localized: "Test ping")
        case BackfillController.logDataType, WebhookLog.backfillRunDataType: return String(localized: "Backfill")
        case let type?: return type
        }
    }

    /// Type, count and size.
    private var ldFacts: [String] {
        let type = ldTypeLabel
        var parts: [String]
        if let count = recordCount, count > 0 {
            parts = [isMqtt ? String(localized: "\(type) · \(count) sensors") : String(localized: "\(type) · \(count) records")]
        } else {
            parts = [type]
        }
        if let size = ldPayloadSize { parts.append(size) }
        return parts
    }

    /// The row's second line: type, count and size, and the word when it was not a plain delivery.
    var ldSummary: String {
        var parts = ldFacts
        if !success || isMqtt { parts.append(ldOutcome) }
        return parts.joined(separator: " · ")
    }

    /// The row as VoiceOver reads it: how it went first, so a failure is heard before the rest. The
    /// dots of the summary are commas here, and the seconds are left out.
    var ldSpokenRow: String {
        var parts = [ldOutcome]
        if let statusCode { parts.append("\(statusCode)") }
        parts.append(ldDestination)
        parts.append(timestamp.formatted(date: .omitted, time: .shortened))
        parts += ldFacts.joined(separator: " · ").components(separatedBy: " · ")
        if let reason = ldFailureLine { parts.append(reason) }
        return parts.joined(separator: ", ")
    }

    /// The reason under a failed row. An MQTT row has the error as iOS reported it.
    var ldFailureLine: String? {
        guard ldIsFailure else { return nil }
        if isMqtt, let errorDetail { return errorDetail }
        return errorMessage.map(AppDiagnostic.display)
    }

    /// The payload as a JSON file named after the delivery's time: a share target handles a file
    /// of any size.
    func ldPayloadFile() -> URL? {
        guard let rawPayload else { return nil }
        return try? ExportManager.writePayloadFile(rawPayload, prefix: ExportManager.logPayloadPrefix, date: timestamp)
    }
}

// MARK: - Subviews

private struct LogDeliveryRow: View {
    let log: WebhookLog

    @ScaledMetric(relativeTo: .footnote) private var codeWidth: CGFloat = 38
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: log.ldCode)
                .font(LDType.mono(13, bold: true))
                .foregroundStyle(log.ldCodeColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: codeWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                titleLine
                LDSeparatedText(log.ldSummary)
                    .font(LDType.mono(12))
                    .foregroundStyle(log.ldIsFailure ? LDTheme.warningText : LDTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let reason = log.ldFailureLine {
                    Text(verbatim: reason)
                        .font(LDType.mono(12))
                        .foregroundStyle(LDTheme.warningText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            LDChevron()
                .frame(width: 18)
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, 8)
        .padding(.leading, LDTheme.textInset)
        .padding(.trailing, 12)
        .frame(minHeight: 58)
        .background(log.ldIsFailure ? LDTheme.warningSurface : Color.clear)
        .overlay(alignment: .bottom) {
            LDHairline()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: log.ldSpokenRow))
    }

    private var titleLine: some View {
        // Under each other at the accessibility text sizes, where the time would squeeze the name.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text(verbatim: log.ldDestination)
                .font(LDType.sans(15, .bold, relativeTo: .subheadline))
                .foregroundStyle(LDTheme.text)
                // A host cut down to "hom...ocal" says nothing: at these sizes it may wrap.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: log.timestamp.formatted(.dateTime.hour().minute().second()))
                .font(LDType.monoValue)
                .foregroundStyle(LDTheme.muted)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

private struct LogDayHeader: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(LDType.mono(12))
            .foregroundStyle(LDTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .padding(.horizontal, LDTheme.textInset)
            .overlay(alignment: .bottom) {
                LDHairline()
            }
            .accessibilityAddTraits(.isHeader)
    }
}

/// One group of the old card's Recent failures.
private struct LogFailureGroupLine: View {
    let failure: SyncStats.Failure

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var source: String {
        switch failure.source {
        case SyncStats.readFailureSource: return String(localized: "Apple Health")
        default: return failure.source
        }
    }

    private var message: String {
        let text = failure.message.map(AppDiagnostic.display) ?? String(localized: "Unknown error")
        return failure.count > 1 ? String(localized: "\(text) (\(failure.count) times)") : text
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // As LogDeliveryRow: under each other at the accessibility text sizes.
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                layout {
                    Text(verbatim: source)
                        .font(LDType.sans(14, .bold, relativeTo: .subheadline))
                        .foregroundStyle(LDTheme.text)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: failure.latest.formatted(logDateFormat))
                        .font(LDType.mono(12))
                        .foregroundStyle(LDTheme.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(verbatim: message)
                    .font(LDType.mono(12))
                    .foregroundStyle(LDTheme.warningText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LDChevron()
                .frame(width: 18)
        }
        .multilineTextAlignment(.leading)
        .padding(.leading, LDTheme.textInset)
        .padding(.trailing, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// What a footer button just did, above the footer. The icon and the words say it, not the colour.
struct LogResultLine: View {
    let text: Text
    let isGood: Bool

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: isGood ? "checkmark.circle" : "exclamationmark.triangle")
                .accessibilityHidden(true)
        }
        .font(LDType.noteSmall)
        .foregroundStyle(isGood ? LDTheme.accentTextSoft : LDTheme.warningText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, LDTheme.textInset)
        .background(LDTheme.ground)
    }
}
