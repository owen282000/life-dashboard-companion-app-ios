import SwiftUI
import HealthKit

struct HealthKitScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared
    @ObservedObject private var healthKit = HealthKitManager.shared
    @ObservedObject private var backfill = BackfillController.shared
    @EnvironmentObject private var pairing: PairingCoordinator

    @State private var showDataTypes = false
    @State private var showSchedule = false
    @State private var showWebhook = false
    @State private var showMqtt = false
    @State private var showAdvanced = false
    @State private var showNotifications = false
    @State private var newWebhookUrl: String = ""
    @State private var newHeaderKey: String = ""
    @State private var newHeaderValue: String = ""
    @State private var mqttPortText = String(PreferencesManager.shared.mqttPort)
    @State private var phoneNameText = PreferencesManager.shared.phoneName
    @FocusState private var phoneNameFocused: Bool
    @State private var showPreview = false
    @State private var previewPayload: PayloadPreview?
    @State private var previewFullPayload: String = ""
    @State private var isLoadingPreview = false
    @State private var isSyncing = false
    @State private var isTestingWebhook = false
    @State private var isExporting = false
    @State private var exportFileURL: URL?
    @State private var outcome: SyncOutcome?
    @State private var showBackfillDialog = false
    @State private var backfillNotice: String?
    @State private var accessRequest: HKAuthorizationRequestStatus?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !healthKit.isAvailable {
                    ContentUnavailableView(
                        "Apple Health is not available",
                        systemImage: "heart.slash",
                        description: Text("This device cannot share Health data with apps.")
                    )
                } else {
                    statusHeader
                    DashboardCard()
                    CardGroup {
                        dataTypesRow
                        CardDivider()
                        SyncScheduleSection(schedule: $prefs.healthSyncSchedule, isExpanded: $showSchedule)
                    }
                    CardGroup {
                        webhookRow
                        CardDivider()
                        mqttRow
                    }
                    CardGroup {
                        advancedRow
                        CardDivider()
                        notificationsRow
                    }
                    actions
                }
            }
            .padding(16)
            .readableWidth()
        }
        .background(Color(.systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .screenshotScrollAnchor()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .onAppear {
            mqttPortText = String(prefs.mqttPort)
            // Expanded on first run so new users see the data types; collapsed once configured
            showDataTypes = prefs.healthEnabledDataTypes.isEmpty
            #if DEBUG
            // For screenshots: -ld.expand YES opens every row.
            if UserDefaults.standard.bool(forKey: "ld.expand") {
                (showDataTypes, showSchedule, showWebhook, showMqtt, showAdvanced, showNotifications) = (true, true, true, true, true, true)
            }
            #endif
        }
        .task(id: prefs.healthEnabledDataTypes) { await refreshAccessRequest() }
        .sheet(isPresented: $showPreview) {
            previewSheet
        }
        .sheet(isPresented: Binding(get: { exportFileURL != nil }, set: { if !$0 { exportFileURL = nil } })) {
            if let exportFileURL {
                ShareSheet(activityItems: [exportFileURL])
            }
        }
        // A pairing link needs the root sheet, which cannot show over this one.
        .onChange(of: pairing.incoming) { _, _ in showPreview = false }
    }

    // MARK: - Header

    /// Android's green banner: how many types are on, and Grant while iOS still has something
    /// to ask. HealthKit never says whether read access was given, only whether asking would
    /// show the sheet, so there is no "granted" state to show.
    private var statusHeader: some View {
        let count = prefs.healthEnabledDataTypes.count
        return StatusHeader(
            title: "Apple Health",
            subtitle: count == 0 ? Text("No data types selected") : Text("\(count) data types selected")
        ) {
            if HealthKitScreen.showsGrant(accessRequest, enabledCount: count) {
                HeaderChip(title: "Grant") {
                    Task {
                        try? await healthKit.requestAuthorization(for: prefs.healthEnabledDataTypes)
                        await refreshAccessRequest()
                    }
                }
            }
        }
    }

    static func showsGrant(_ request: HKAuthorizationRequestStatus?, enabledCount: Int) -> Bool {
        enabledCount > 0 && request == .shouldRequest
    }

    private func refreshAccessRequest() async {
        let types = healthKit.readTypesFor(prefs.healthEnabledDataTypes)
        guard !types.isEmpty else {
            accessRequest = nil
            return
        }
        accessRequest = try? await healthKit.healthStore.statusForAuthorizationRequest(toShare: [], read: types)
    }

    // MARK: - Rows

    private var dataTypesRow: some View {
        let count = prefs.healthEnabledDataTypes.count
        return ExpandableRow(
            title: "Data Types",
            systemImage: "waveform.path.ecg.rectangle",
            subtitle: Text("\(count) of \(HealthDataType.allCases.count) selected"),
            subtitleColor: count > 0 ? Brand.ink : .secondary,
            isExpanded: $showDataTypes
        ) {
            ForEach(HealthDataType.allCases) { dataType in
                Toggle(isOn: Binding(
                    get: { prefs.healthEnabledDataTypes.contains(dataType) },
                    set: { enabled in
                        if enabled {
                            prefs.healthEnabledDataTypes.insert(dataType)
                            // Request permission for newly enabled types
                            Task {
                                try? await healthKit.requestAuthorization(for: [dataType])
                            }
                        } else {
                            prefs.healthEnabledDataTypes.remove(dataType)
                        }
                        // Reconfigure observer queries for changed data types, and the background
                        // tasks, which the first type (or the last one gone) starts or stops
                        BackgroundSyncManager.shared.reconfigureObservers()
                        BackgroundSyncManager.shared.replan()
                    }
                )) {
                    Label {
                        Text(dataType.displayName)
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: dataType.icon)
                            .foregroundStyle(Brand.ink)
                            .frame(minWidth: 28)
                    }
                }
                .tint(Brand.green)
            }
        }
    }

    private var webhookRow: some View {
        let urls = prefs.healthWebhookUrls
        return ExpandableRow(
            title: "Webhook",
            systemImage: "link",
            subtitle: urls.isEmpty ? Text("Not configured") : Text("\(urls.count) configured"),
            subtitleColor: urls.isEmpty ? .secondary : Brand.ink,
            isExpanded: $showWebhook
        ) {
            if urls.isEmpty {
                Button {
                    pairing.startScan()
                } label: {
                    Label("Scan a pairing code", systemImage: "qrcode.viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Brand.ink)
            }

            RowSubheading("Webhook URLs")
            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                ListLine(removeLabel: Text("Remove webhook URL")) {
                    var remaining = prefs.healthWebhookUrls
                    remaining.remove(at: index)
                    prefs.healthWebhookUrls = remaining
                } content: {
                    Text(verbatim: url)
                        .font(.footnote)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !prefs.healthWebhookHeaders.isEmpty && prefs.healthUrlsWithoutHeaders.contains(url) {
                        Text("Paired by QR code: custom headers are not sent here")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Webhook URL", text: $newWebhookUrl, prompt: Text(verbatim: "https://your-webhook.com/health"))
                    .font(.footnote)
                    .textFieldStyle(.filled)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if !urls.isEmpty {
                    iconButton("qrcode.viewfinder", label: "Scan a pairing code") { pairing.startScan() }
                }
                iconButton("plus", label: "Add webhook URL") {
                    let trimmed = newWebhookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        prefs.addTypedHealthWebhookUrl(trimmed)
                        newWebhookUrl = ""
                    }
                }
            }

            Divider()
            RowSubheading("Custom Headers")
            ForEach(Array(prefs.healthWebhookHeaders.keys.sorted()), id: \.self) { key in
                ListLine(removeLabel: Text("Remove header \(key)")) {
                    prefs.healthWebhookHeaders.removeValue(forKey: key)
                } content: {
                    Text(verbatim: "\(key): \(prefs.healthWebhookHeaders[key] ?? "")")
                        .font(.footnote)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                TextField("Key", text: $newHeaderKey)
                    .font(.footnote)
                    .textFieldStyle(.filled)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Value", text: $newHeaderValue)
                    .font(.footnote)
                    .textFieldStyle(.filled)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                iconButton("plus", label: "Add header") {
                    let key = newHeaderKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = newHeaderValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !key.isEmpty, !value.isEmpty {
                        prefs.healthWebhookHeaders[key] = value
                        newHeaderKey = ""
                        newHeaderValue = ""
                    }
                }
            }

            Divider()
            RowSubheading("HMAC Signing Secret")
            SecureField("Optional secret for X-Signature", text: Binding(
                get: { prefs.healthSigningSecret },
                set: { prefs.healthSigningSecret = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ))
            .font(.footnote)
            .textFieldStyle(.filled)
            Text("When set, every request includes X-Signature: sha256=HMAC-SHA256(secret, body) so your server can verify the sender.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Android's square add button: the green fill with the dark ink glyph.
    private func iconButton(_ systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Brand.onGreen)
                .frame(width: 44, height: 44)
                .background(Brand.green, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var mqttRow: some View {
        ExpandableRow(
            title: "MQTT",
            systemImage: "house",
            subtitle: mqttSubtitle,
            subtitleColor: prefs.mqttEnabled ? Brand.ink : .secondary,
            isExpanded: $showMqtt
        ) {
            Text("Publishes today's steps, distance and calories and the latest value of every other synced data type to your MQTT broker with Home Assistant Discovery: sensors appear automatically, no server-side setup needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Enable MQTT publishing", isOn: Binding(
                get: { prefs.mqttEnabled },
                set: { prefs.mqttEnabled = $0 }
            ))
            .font(.subheadline)
            .tint(Brand.green)

            TextField("Broker host, e.g. 192.168.1.10", text: Binding(
                get: { prefs.mqttHost },
                set: { prefs.mqttHost = $0 }
            ))
            .textFieldStyle(.filled)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            HStack(spacing: 12) {
                TextField("Port", text: $mqttPortText)
                    .textFieldStyle(.filled)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 120)
                    .onChange(of: mqttPortText) { _, newValue in
                        if let port = Int(newValue.filter(\.isNumber)), port > 0, port <= 65535 {
                            prefs.mqttPort = port
                        }
                    }
                Toggle("TLS", isOn: Binding(
                    get: { prefs.mqttUseTls },
                    set: { prefs.mqttUseTls = $0 }
                ))
                .font(.subheadline)
                .tint(Brand.green)
            }

            TextField("Username (optional)", text: Binding(
                get: { prefs.mqttUsername },
                set: { prefs.mqttUsername = $0 }
            ))
            .textFieldStyle(.filled)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            SecureField("Password (optional)", text: Binding(
                get: { prefs.mqttPassword },
                set: { prefs.mqttPassword = $0 }
            ))
            .textFieldStyle(.filled)

            TextField("Base topic", text: Binding(
                get: { prefs.mqttBaseTopic },
                set: { prefs.mqttBaseTopic = $0 }
            ))
            .textFieldStyle(.filled)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            phoneNameField

            if let status = MqttStatus(stored: prefs.mqttLastStatus) {
                ResultLine(text: Text(status.text), tone: status.success ? .success : .failure)
            }
        }
    }

    /// Android's phone name: a second iPhone on the same broker gets a device of its own, and
    /// without a name nothing changes. The id is shown as it goes on the wire, and a name with
    /// nothing usable in it, which would publish nameless, is said out loud.
    @ViewBuilder
    private var phoneNameField: some View {
        Divider()
        RowSubheading("Phone name")
        Text("For a second iPhone on the same MQTT broker. Empty keeps the device and the topics as they are; a name gives this iPhone its own device and its own topics under the base topic.")
            .font(.caption)
            .foregroundStyle(.secondary)
        // Saved when the field is left, not per keystroke: a sync in between would publish a
        // device for every half-typed name and clear it again.
        TextField("Phone name", text: $phoneNameText, prompt: Text("Optional"))
            .textFieldStyle(.filled)
            .autocorrectionDisabled()
            .focused($phoneNameFocused)
            .onSubmit(savePhoneName)
            .onChange(of: phoneNameFocused) { _, focused in if !focused { savePhoneName() } }
            .onChange(of: prefs.phoneName) { _, name in if !phoneNameFocused { phoneNameText = name } }
            .onDisappear(perform: savePhoneName)
        if !phoneNameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let slug = MqttSupport.phoneSlug(phoneNameText) {
                Text("Publishes as \(MqttSupport.deviceId(slug: slug)). After a rename, the next sync removes the old device's sensors from the broker.")
                    .font(.caption)
                    .foregroundStyle(Brand.ink)
            } else {
                Text("This name has no letters from a to z or digits, so the iPhone stays unnamed.")
                    .font(.caption)
                    .foregroundStyle(Brand.errorInk)
            }
        }
    }

    private func savePhoneName() {
        let name = String(phoneNameText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SettingsImport.maxPhoneNameLength))
        if name != prefs.phoneName { prefs.phoneName = name }
        if name != phoneNameText { phoneNameText = name }
    }

    private var mqttSubtitle: Text {
        guard prefs.mqttEnabled else { return Text("Off") }
        let host = prefs.mqttHost.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? Text("On: no broker set") : Text("On: \(host)")
    }

    private var advancedRow: some View {
        ExpandableRow(
            title: "Advanced",
            systemImage: "slider.horizontal.3",
            subtitle: prefs.includeDailyTotals ? Text("Daily totals") : Text("No daily totals"),
            isExpanded: $showAdvanced
        ) {
            Toggle("Daily totals in payload", isOn: $prefs.includeDailyTotals)
                .font(.subheadline)
                .tint(Brand.green)
            Text("Per-day totals (steps, distance, calories) as the Health app counts them, with overlapping iPhone and Watch data counted once")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var notificationsRow: some View {
        ExpandableRow(
            title: "Notifications",
            systemImage: "bell",
            subtitle: prefs.failureNotificationsEnabled
                ? Text("On, after \(prefs.failureNotificationThreshold) failed syncs")
                : Text("Off"),
            subtitleColor: prefs.failureNotificationsEnabled ? Brand.ink : .secondary,
            isExpanded: $showNotifications
        ) {
            Toggle("Notify after failed syncs", isOn: Binding(
                get: { prefs.failureNotificationsEnabled },
                set: { enabled in
                    prefs.failureNotificationsEnabled = enabled
                    if enabled {
                        SyncFailureNotifier.shared.requestFullAuthorization()
                    }
                }
            ))
            .font(.subheadline)
            .tint(Brand.green)

            if prefs.failureNotificationsEnabled {
                Text("After consecutive failures")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Picker("Failure threshold", selection: Binding(
                    get: { prefs.failureNotificationThreshold },
                    set: { prefs.failureNotificationThreshold = $0 }
                )) {
                    Text(verbatim: "3").tag(3)
                    Text(verbatim: "5").tag(5)
                    Text(verbatim: "10").tag(10)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: syncNow) {
                isSyncing ? Text("Syncing...") : Text("Sync Now")
            }
                .buttonStyle(PrimaryButtonStyle(isBusy: isSyncing))
                .disabled(!prefs.healthSyncConfigured || isSyncing || backfill.isRunning)

            ActionTileRow {
                ActionTile(title: "View", systemImage: "eye", isBusy: isLoadingPreview, action: loadPreview)
                    .disabled(prefs.healthEnabledDataTypes.isEmpty || isLoadingPreview)
                ActionTile(title: "Test ping", systemImage: "dot.radiowaves.left.and.right", isBusy: isTestingWebhook, action: sendTestPing)
                    .disabled(prefs.healthWebhookUrls.isEmpty || isTestingWebhook)
                exportTile
                BackfillTile(prefs: prefs, showDialog: $showBackfillDialog, notice: $backfillNotice)
            }

            BackfillSection(prefs: prefs, showDialog: $showBackfillDialog, notice: $backfillNotice)

            if let outcome {
                ResultLine(text: outcome.text, tone: outcome.tone)
            }

            // Pending queue indicator
            let pendingCount = PendingSyncStore.shared.pendingCount
            if pendingCount > 0 {
                NoticeBanner(text: Text("\(pendingCount) pending syncs"), tone: .warning) {
                    Button("Retry Now") {
                        Task {
                            await SyncCoordinator.shared.drain(automatic: false)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(Brand.warningInk)
                }
            }

            ScheduleStatusLine(schedule: prefs.healthSyncSchedule, webhookCount: prefs.healthWebhookUrls.count, mqtt: prefs.mqttConfigured)
        }
    }

    /// Android's Export tile: what View shows, as a JSON or CSV file for the share sheet.
    private var exportTile: some View {
        Menu {
            Button {
                exportHealthData(.csv)
            } label: {
                Label("Export CSV", systemImage: "tablecells")
            }
            Button {
                exportHealthData(.json)
            } label: {
                Label("Export JSON", systemImage: "curlybraces")
            }
        } label: {
            ActionTileLabel(title: "Export", systemImage: "square.and.arrow.up", isBusy: isExporting)
        }
        // A menu tints its label; the tile keeps its own colours like the others.
        .tint(Color.primary)
        .disabled(prefs.healthEnabledDataTypes.isEmpty || isExporting)
    }

    private func exportHealthData(_ format: ExportManager.HealthExportFormat) {
        isExporting = true
        outcome = nil
        Task {
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let payload = try await HealthSyncManager.shared.buildPreviewPayload()
                    return .success(try ExportManager.writeHealthExport(payload, format: format))
                } catch {
                    return .failure(error)
                }
            }.value
            isExporting = false
            switch result {
            case .success(let url): exportFileURL = url
            case .failure(let error): report(.exportFailed(error.localizedDescription))
            }
        }
    }

    private func syncNow() {
        isSyncing = true
        outcome = nil
        Task {
            let result = await SyncCoordinator.shared.runManual(full: true)
            await MainActor.run {
                isSyncing = false
                switch result {
                case .noData:
                    report(.noData)
                case .success(let counts):
                    report(.synced(counts.values.reduce(0, +)))
                case .failure(let error):
                    report(.failed(AppDiagnostic.display(error)))
                }
            }
        }
    }

    /// Test Ping: verify server setup without waiting for real data
    private func sendTestPing() {
        isTestingWebhook = true
        outcome = nil
        Task {
            let payload: [String: Any] = [
                "test": true,
                "message": "Test ping from Life Dashboard Companion",
                "timestamp": Date().iso8601String,
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                "source": "healthkit_ios"
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                isTestingWebhook = false
                return
            }
            let success = await WebhookManager.shared.post(
                body: body,
                urls: prefs.healthWebhookUrls,
                headers: prefs.healthWebhookHeaders,
                logType: .healthConnect,
                dataType: "test",
                recordCount: 0
            ).delivered
            await MainActor.run {
                isTestingWebhook = false
                report(success ? .pingDelivered : .pingFailed)
            }
        }
    }

    private func report(_ result: SyncOutcome) {
        outcome = result
        AccessibilityNotification.Announcement(result.announcement).post()
    }

    private func loadPreview() {
        isLoadingPreview = true
        Task {
            // Build, format and cap off the main thread: laying out more than PayloadPreview's
            // 12,000 characters in one Text stalls the screen (P2-11). Share has all of it.
            let result: (display: PayloadPreview?, full: String) = await Task.detached(priority: .userInitiated) {
                do {
                    let payload = try await HealthSyncManager.shared.buildPreviewPayload()
                    let formatted = ExportManager.formatPayloadForPreview(payload)
                    return (PayloadPreview.of(formatted), formatted)
                } catch {
                    return (nil, String(localized: "Error: \(error.localizedDescription)"))
                }
            }.value
            previewPayload = result.display
            previewFullPayload = result.full
            isLoadingPreview = false
            showPreview = true
        }
    }

    private var previewSheet: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if let preview = previewPayload {
                        PayloadPreviewText(
                            preview: preview,
                            font: .system(.caption, design: .monospaced),
                            whereTheRestIs: Text("Use the share button for the full payload.")
                        )
                    } else {
                        // The error a failed build left in previewFullPayload, read as it is.
                        Text(verbatim: previewFullPayload)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Health Data Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showPreview = false }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: previewFullPayload) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share full payload")
                }
            }
        }
    }
}

/// What Sync Now or Test ping last did. It decides the colour, instead of the text deciding it.
enum SyncOutcome: Equatable {
    case synced(Int)
    case noData
    case failed(String)
    case pingDelivered
    case pingFailed
    case exportFailed(String)

    var text: Text {
        switch self {
        case .synced(let records): return Text("Synced \(records) records")
        case .noData: return Text("No data to sync")
        case .failed(let reason): return Text("Sync failed: \(reason)")
        case .pingDelivered: return Text("Test ping delivered")
        case .pingFailed: return Text("Test ping failed, check the logs")
        case .exportFailed(let reason): return Text("Export failed: \(reason)")
        }
    }

    var announcement: String {
        switch self {
        case .synced(let records): return String(localized: "Synced \(records) records")
        case .noData: return String(localized: "No data to sync")
        case .failed(let reason): return String(localized: "Sync failed: \(reason)")
        case .pingDelivered: return String(localized: "Test ping delivered")
        case .pingFailed: return String(localized: "Test ping failed, check the logs")
        case .exportFailed(let reason): return String(localized: "Export failed: \(reason)")
        }
    }

    var tone: StatusTone {
        switch self {
        case .synced, .pingDelivered: return .success
        case .noData: return .info
        case .failed, .pingFailed, .exportFailed: return .failure
        }
    }
}
