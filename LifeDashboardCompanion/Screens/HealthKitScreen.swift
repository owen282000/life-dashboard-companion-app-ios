import SwiftUI
import HealthKit
import StoreKit

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
    @State private var showResolution = false
    @State private var showNotifications = false
    @State private var newWebhookUrl: String = ""
    @State private var editingDestination: WebhookDestination?
    @State private var mqttHostText = PreferencesManager.shared.mqttHost
    @State private var mqttPortText = String(PreferencesManager.shared.mqttPort)
    @State private var phoneNameText = PreferencesManager.shared.phoneName
    @FocusState private var phoneNameFocused: Bool
    @State private var showPreview = false
    @State private var previewPayload: PayloadPreview?
    @State private var previewFullPayload: String = ""
    @State private var previewFileURL: URL?
    @State private var previewCopyOutcome: PayloadCopy.Outcome?
    @State private var isLoadingPreview = false
    @State private var isSyncing = false
    @State private var isTestingWebhook = false
    @State private var isExporting = false
    @State private var exportFileURL: URL?
    @State private var outcome: SyncOutcome?
    @State private var showBackfillDialog = false
    @State private var backfillNotice: String?
    @State private var accessRequest: HKAuthorizationRequestStatus?
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase

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
                    // No spacing of its own: an empty hold card adds no gap above the dashboard.
                    VStack(spacing: 0) {
                        SyncHoldCard()
                        DashboardCard()
                    }
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
                        ResolutionRow(prefs: prefs, isExpanded: $showResolution)
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
            mqttHostText = prefs.mqttHost
            mqttPortText = String(prefs.mqttPort)
            // Expanded on first run so new users see the data types; collapsed once configured
            showDataTypes = prefs.healthEnabledDataTypes.isEmpty
            #if DEBUG
            // For screenshots: -ld.expand YES opens every row, -ld.expand "schedule,mqtt" only
            // those (types, schedule, webhook, mqtt, advanced, resolution, notifications).
            if UserDefaults.standard.bool(forKey: "ld.expand") {
                (showDataTypes, showSchedule, showWebhook, showMqtt, showAdvanced, showNotifications) = (true, true, true, true, true, true)
                showResolution = true
            } else if let rows = UserDefaults.standard.string(forKey: "ld.expand")?.split(separator: ",").map(String.init) {
                showDataTypes = rows.contains("types")
                showSchedule = rows.contains("schedule")
                showWebhook = rows.contains("webhook")
                showMqtt = rows.contains("mqtt")
                showAdvanced = rows.contains("advanced")
                showResolution = rows.contains("resolution")
                showNotifications = rows.contains("notifications")
            }
            // -ld.backfill YES opens the list of backfill lengths.
            if UserDefaults.standard.bool(forKey: "ld.backfill") { showBackfillDialog = true }
            // -ld.destination 0 opens the first webhook address's sheet.
            if UserDefaults.standard.object(forKey: "ld.destination") != nil {
                let index = UserDefaults.standard.integer(forKey: "ld.destination")
                if prefs.healthDestinations.indices.contains(index) {
                    editingDestination = prefs.healthDestinations[index]
                }
            }
            #endif
        }
        .task(id: prefs.healthEnabledDataTypes) { await refreshAccessRequest() }
        .task { await askOnceAfterUpdate() }
        .onAppear { considerReview() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { considerReview() } }
        // A backfill that just finished is a good moment of its own.
        .onChange(of: backfill.job?.status) { _, status in if status == .done { considerReview(backfillDone: true) } }
        .sheet(isPresented: $showPreview) {
            previewSheet
        }
        // On the screen, not in the Webhook row, which is not there while it is collapsed.
        .sheet(item: $editingDestination) { destination in
            DestinationSheet(
                destination: destination,
                others: prefs.healthDestinations.filter { $0.id != destination.id },
                onSave: { prefs.updateDestination($0) }
            )
        }
        .shareSheet(for: $exportFileURL)
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

    /// After an update that gives an enabled type more sample types (distance in 1.5.0), the
    /// Grant chip alone went unnoticed, and the type sent less than it could. The tab asks iOS
    /// once by itself when there is something to ask, never over the setup.
    private func askOnceAfterUpdate() async {
        guard UserDefaults.standard.bool(forKey: "onboarding_completed") else { return }
        #if DEBUG
        // For screenshots: -ld.ask NO, or the default, keeps the Health sheet away.
        if UserDefaults.standard.object(forKey: "ld.ask") as? Bool == false { return }
        #endif
        await healthKit.askOnceForEnabledTypes(prefs.healthEnabledDataTypes)
        await refreshAccessRequest()
    }

    private func refreshAccessRequest() async {
        let types = healthKit.readTypesFor(prefs.healthEnabledDataTypes)
        guard !types.isEmpty else {
            accessRequest = nil
            return
        }
        accessRequest = try? await healthKit.healthStore.statusForAuthorizationRequest(toShare: [], read: types)
    }

    /// Asks for an App Store rating at a good moment (P1-28): see `ReviewPrompt`. The first use
    /// is noted here too, the first time this screen shows after the setup.
    private func considerReview(backfillDone: Bool = false) {
        let defaults = UserDefaults.standard
        let now = Date()
        if defaults.object(forKey: ReviewPrompt.firstUseKey) == nil { defaults.set(now, forKey: ReviewPrompt.firstUseKey) }
        let status = SharedSyncStatus.read()
        let state = ReviewPrompt.State(
            lastDelivered: status.lastDelivered,
            lastSyncSucceeded: status.lastSuccess,
            failureStreak: defaults.integer(forKey: "sync_failure_streak"),
            partialStreak: defaults.integer(forKey: "sync_partial_streak"),
            pending: PendingSyncStore.shared.pendingCount
        )
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard ReviewPrompt.shouldAsk(
            goodMoment: backfillDone || ReviewPrompt.isGoodMoment(state, now: now),
            firstUse: defaults.object(forKey: ReviewPrompt.firstUseKey) as? Date,
            askedVersion: defaults.string(forKey: ReviewPrompt.askedVersionKey),
            version: version, now: now
        ) else { return }
        defaults.set(version, forKey: ReviewPrompt.askedVersionKey)
        requestReview()
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
                    // Tap an address for its own signing secret and headers, as on Android.
                    Button {
                        editingDestination = prefs.healthDestinations.first { $0.url == url }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: url)
                                .font(.footnote)
                                .foregroundStyle(Brand.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            destinationSummary(prefs.healthDestinations.first { $0.url == url })
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens its signing secret and headers"))
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

            Text("Every address has its own signing secret and headers. Pairing sets them for the address it adds; tap an address to see or change them.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func destinationSummary(_ destination: WebhookDestination?) -> Text {
        let signed = !(destination?.secret.isEmpty ?? true)
        let names = (destination?.headers.keys.sorted() ?? []).joined(separator: ", ")
        switch (signed, names.isEmpty) {
        case (true, true): return Text("Signed, no headers")
        case (true, false): return Text("Signed, headers: \(names)")
        case (false, true): return Text("Not signed, no headers")
        case (false, false): return Text("Not signed, headers: \(names)")
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

            // Saved only while it is a host the broker can be reached at; the line under the
            // field says what is wrong, and the last good host stays in use meanwhile.
            TextField("Broker host, e.g. 192.168.1.10", text: $mqttHostText)
                .textFieldStyle(.filled)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .onChange(of: mqttHostText) { _, text in saveMqttHost(text) }
                // A host emptied while MQTT was on is cleared once it is off.
                .onChange(of: prefs.mqttEnabled) { saveMqttHost(mqttHostText) }
                .onChange(of: prefs.mqttHost) { _, host in
                    if SettingsValidation.normalizedBrokerHost(mqttHostText) != host { mqttHostText = host }
                }
            if let problem = mqttHostProblem {
                FieldError(message: problem.message)
            }

            HStack(spacing: 12) {
                TextField("Port", text: $mqttPortText)
                    .textFieldStyle(.filled)
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 120)
                    .onChange(of: mqttPortText) { _, newValue in
                        if SettingsValidation.brokerPortProblem(newValue) == nil,
                           let port = Int(newValue.trimmingCharacters(in: .whitespaces)) {
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
            if let problem = SettingsValidation.brokerPortProblem(mqttPortText) {
                FieldError(message: problem.message)
            }

            TextField("Username (optional)", text: Binding(
                get: { prefs.mqttUsername },
                set: { prefs.mqttUsername = $0 }
            ))
            .textFieldStyle(.filled)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            RevealableSecureField("Password (optional)", text: Binding(
                get: { prefs.mqttPassword },
                set: { prefs.mqttPassword = $0 }
            ))

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

    /// An empty host is no broker, which is fine while MQTT is off.
    private var mqttHostProblem: SettingsValidation.BrokerProblem? {
        if mqttHostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !prefs.mqttEnabled { return nil }
        return SettingsValidation.brokerHostProblem(mqttHostText)
    }

    private func saveMqttHost(_ text: String) {
        let host = SettingsValidation.normalizedBrokerHost(text)
        let clears = host.isEmpty && !prefs.mqttEnabled
        guard clears || SettingsValidation.brokerHostProblem(host) == nil, host != prefs.mqttHost else { return }
        prefs.mqttHost = host
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
            subtitle: advancedSubtitle,
            subtitleColor: prefs.clientCertificate?.needsAttention() == true ? Brand.warningInk : .secondary,
            isExpanded: $showAdvanced
        ) {
            Toggle("Daily totals in payload", isOn: $prefs.includeDailyTotals)
                .font(.subheadline)
                .tint(Brand.green)
            Text("Per-day totals (steps, distance, calories) as the Health app counts them, with overlapping iPhone and Watch data counted once")
                .font(.footnote)
                .foregroundColor(.secondary)
            Divider()
            ClientCertificateLine(prefs: prefs)
        }
    }

    private var advancedSubtitle: Text {
        switch (prefs.includeDailyTotals, prefs.clientCertificate != nil) {
        case (true, false): return Text("Daily totals")
        case (false, false): return Text("No daily totals")
        case (true, true): return Text("Daily totals, client certificate")
        case (false, true): return Text("No daily totals, client certificate")
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
            let result = await SyncCoordinator.shared.runManual(syncNow: true)
            await MainActor.run {
                isSyncing = false
                report(SyncOutcome(result))
            }
        }
    }

    /// Test Ping: verify server setup without waiting for real data
    private func sendTestPing() {
        isTestingWebhook = true
        outcome = nil
        Task {
            let delivered = await TestPing.send(prefs: prefs)
            await MainActor.run {
                isTestingWebhook = false
                if let delivered { report(delivered ? .pingDelivered : .pingFailed) }
            }
        }
    }

    private func report(_ result: SyncOutcome) {
        outcome = result
        if case .synced = result { considerReview() }
        AccessibilityNotification.Announcement(result.announcement).post()
    }

    private func loadPreview() {
        isLoadingPreview = true
        Task {
            // Build, format and cap off the main thread: laying out more than PayloadPreview's
            // 12,000 characters in one Text stalls the screen (P2-11). Copy and Share have all of it.
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
            previewCopyOutcome = nil
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
                            whereTheRestIs: Text("Use the copy or share button for the full payload.")
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
            .safeAreaInset(edge: .bottom) {
                if let previewCopyOutcome {
                    PayloadCopyLine(outcome: previewCopyOutcome)
                        .padding(12)
                        .background(.bar)
                }
            }
            .navigationTitle("Health Data Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showPreview = false }
                }
                // Not for a preview that failed to build: the text is then the error.
                if previewPayload != nil {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button(action: copyPreview) {
                            Image(systemName: "doc.on.doc")
                        }
                        .accessibilityLabel("Copy full payload")
                        Button(action: sharePreview) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share full payload")
                    }
                }
            }
            .shareSheet(for: $previewFileURL)
        }
    }

    private func copyPreview() {
        let outcome = PayloadCopy.copy(previewFullPayload)
        previewCopyOutcome = outcome
        AccessibilityNotification.Announcement(outcome.message).post()
    }

    /// The same file as Export JSON, written off the main thread: a week of heart rate is a few
    /// megabytes.
    private func sharePreview() {
        let payload = previewFullPayload
        Task {
            let url = await Task.detached(priority: .userInitiated) {
                try? ExportManager.writePayloadFile(payload, prefix: ExportManager.healthExportPrefix)
            }.value
            previewFileURL = url
        }
    }
}

/// The Test ping, the same request from the Health tab and the first-run setup: a small JSON
/// POST with `test` set, to every webhook URL with the custom headers, signed when a secret is
/// set, logged with data type `test` and never queued. It counts as delivered only when every
/// URL took it: a test is there to show the address that does not work.
enum TestPing {
    static func body() -> Data? {
        let payload: [String: Any] = [
            "test": true,
            "message": "Test ping from Life Dashboard Companion",
            "timestamp": Date().iso8601String,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "source": "healthkit_ios"
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// Whether every webhook took it; nil when the request could not be built.
    static func send(prefs: PreferencesManager) async -> Bool? {
        guard let body = body() else { return nil }
        let delivery = await WebhookManager.shared.post(
            body: body,
            urls: prefs.healthWebhookUrls,
            logType: .healthConnect,
            dataType: "test",
            recordCount: 0
        )
        return delivery.delivered && delivery.missedUrls.isEmpty
    }
}

/// What Sync Now or Test ping last did. It decides the colour, instead of the text deciding it.
enum SyncOutcome: Equatable {
    /// What Sync Now's result line says, on the Health tab and in the setup.
    init(_ result: HealthSyncResult) {
        switch result {
        case .noData:
            self = .noData
        case .success(let counts, let reach):
            let records = counts.values.reduce(0, +)
            self = reach.partial ? .partlySynced(records, delivered: reach.delivered, of: reach.total) : .synced(records)
        case .failure(let error):
            self = .failed(AppDiagnostic.display(error))
        }
    }

    case synced(Int)
    /// Delivered, but not to every webhook: those that missed it get nothing queued.
    case partlySynced(Int, delivered: Int, of: Int)
    case noData
    case failed(String)
    case pingDelivered
    case pingFailed
    case exportFailed(String)

    var text: Text {
        switch self {
        case .synced(let records): return Text("Synced \(records) records")
        case .partlySynced: return Text(verbatim: announcement)
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
        case .partlySynced(let records, let delivered, let total):
            return String(localized: "Synced \(records) records") + " "
                + String(localized: "Delivered to \(delivered) of \(total) destinations, see Logs.")
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
        case .failed, .partlySynced, .pingFailed, .exportFailed: return .failure
        }
    }
}

/// One address's own signing secret and headers (P2-13), as Android's address dialog since
/// 1.28.0. Generate and the copies from another address are offered only while the field is
/// empty, so nothing typed is overwritten by a tap. Saved as a whole, or not at all.
struct DestinationSheet: View {
    @State var destination: WebhookDestination
    let others: [WebhookDestination]
    let onSave: (WebhookDestination) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var problem: SettingsValidation.HeaderProblem?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: destination.url)
                        .font(.footnote)
                        .textSelection(.enabled)
                } header: {
                    Text("Address")
                }

                Section {
                    RevealableSecureField("Optional secret for X-Signature", text: Binding(
                        get: { destination.secret },
                        set: { destination.secret = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ))
                    if destination.secret.isEmpty {
                        Button("Generate") { destination.secret = WebhookDestinations.generatedSecret() }
                        let signed = others.filter { !$0.secret.isEmpty }
                        if !signed.isEmpty {
                            Menu("Use the secret of another address") {
                                ForEach(signed) { other in
                                    Button { destination.secret = other.secret } label: { Text(verbatim: other.host) }
                                }
                            }
                        }
                    }
                } header: {
                    Text("HMAC Signing Secret")
                } footer: {
                    Text("When set, every request includes X-Signature: sha256=HMAC-SHA256(secret, body) so your server can verify the sender.")
                }

                Section {
                    ForEach(destination.headers.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(key): \(destination.headers[key] ?? "")")
                                .font(.footnote)
                                .lineLimit(1)
                            if SettingsValidation.firstInvalidHeader([key: destination.headers[key] ?? ""]) != nil {
                                Text("Not a valid header, so nothing is sent. Remove it and add it again.")
                                    .font(.caption)
                                    .foregroundStyle(Brand.errorInk)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let keys = destination.headers.keys.sorted()
                        for index in offsets { destination.headers.removeValue(forKey: keys[index]) }
                    }
                    HStack(spacing: 8) {
                        TextField("Key", text: $newKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Value", text: $newValue)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Add", action: addHeader)
                            .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .font(.footnote)
                    .onChange(of: newKey) { problem = nil }
                    .onChange(of: newValue) { problem = nil }
                    if let problem {
                        FieldError(message: problem.message)
                    }
                    let withHeaders = others.filter { !$0.headers.isEmpty }
                    if destination.headers.isEmpty && !withHeaders.isEmpty {
                        Menu("Use the headers of another address") {
                            ForEach(withHeaders) { other in
                                Button { destination.headers = other.headers } label: { Text(verbatim: other.host) }
                            }
                        }
                    }
                } header: {
                    Text("Custom Headers")
                } footer: {
                    Text("Sent to this address only. Swipe a header to remove it.")
                }
            }
            .navigationTitle(Text(verbatim: destination.host))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(destination)
                        dismiss()
                    }
                }
            }
        }
    }

    /// A header goes in only when iOS would send it as typed; otherwise the line under the
    /// fields says why, and what was typed stays to be corrected.
    private func addHeader() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = SettingsValidation.headerProblem(name: key, value: value, existing: destination.headers) {
            problem = found
            AccessibilityNotification.Announcement(found.message).post()
            return
        }
        destination.headers[key] = value
        newKey = ""
        newValue = ""
    }
}
