import SwiftUI
import HealthKit

struct HealthKitScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared
    @ObservedObject private var healthKit = HealthKitManager.shared

    @State private var syncIntervalText: String = ""
    @State private var newWebhookUrl: String = ""
    @State private var showPreview = false
    @State private var previewPayload: String = ""
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var showHeaders = false
    @State private var showDataTypes = false
    @State private var newHeaderKey: String = ""
    @State private var newHeaderValue: String = ""
    @State private var isLoadingPreview = false
    @State private var previewFullPayload: String = ""
    @State private var isTestingWebhook = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: - Availability
                if !healthKit.isAvailable {
                    unavailableSection
                } else {
                    dataTypesSection
                    configurationSection
                    headersSection
                    mqttSection
                    actionsSection
                }
            }
            .padding()
        }
        .onAppear {
            syncIntervalText = String(prefs.healthSyncIntervalMinutes)
            // Expanded on first run so new users see the data types; collapsed once configured
            showDataTypes = prefs.healthEnabledDataTypes.isEmpty
        }
        .sheet(isPresented: $showPreview) {
            previewSheet
        }
    }

    // MARK: - Sections

    private var unavailableSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.slash.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text("HealthKit Not Available")
                .font(.headline)
            Text("This device does not support HealthKit.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var dataTypesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showDataTypes.toggle() }
            } label: {
                HStack {
                    Label("Data Types", systemImage: "list.bullet")
                        .font(.headline)
                    Spacer()
                    Text("\(prefs.healthEnabledDataTypes.count) of \(HealthDataType.allCases.count) enabled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: showDataTypes ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(.plain)

            if showDataTypes {
                dataTypesList
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var dataTypesList: some View {
        ForEach(HealthDataType.allCases) { dataType in
                HStack {
                    Image(systemName: dataType.icon)
                        .foregroundColor(.accentColor)
                        .frame(width: 24)

                    Text(dataType.displayName)
                        .font(.subheadline)

                    Spacer()

                    Toggle(dataType.displayName, isOn: Binding(
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
                            // Reconfigure observer queries for changed data types
                            BackgroundSyncManager.shared.reconfigureObservers()
                        }
                    ))
                    .labelsHidden()
                }
                .padding(.vertical, 2)
        }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Configuration", systemImage: "gearshape.fill")
                .font(.headline)

            // Sync Interval
            HStack {
                Text("Sync Interval")
                    .font(.subheadline)
                Spacer()
                TextField("60", text: $syncIntervalText)
                    .keyboardType(.numberPad)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: syncIntervalText) { _, newValue in
                        if let minutes = Int(newValue), minutes >= 15 {
                            prefs.healthSyncIntervalMinutes = minutes
                        }
                    }
                Text("min")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Failure notifications
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

            if prefs.failureNotificationsEnabled {
                HStack {
                    Text("After consecutive failures")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("Failure threshold", selection: Binding(
                        get: { prefs.failureNotificationThreshold },
                        set: { prefs.failureNotificationThreshold = $0 }
                    )) {
                        Text("3").tag(3)
                        Text("5").tag(5)
                        Text("10").tag(10)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            Divider()

            // Webhook URLs
            Text("Webhook URLs")
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(Array(prefs.healthWebhookUrls.enumerated()), id: \.offset) { index, url in
                HStack {
                    Text(url)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        var urls = prefs.healthWebhookUrls
                        urls.remove(at: index)
                        prefs.healthWebhookUrls = urls
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                    }
                    .accessibilityLabel("Remove webhook URL")
                }
            }

            HStack {
                TextField("https://your-webhook.com/health", text: $newWebhookUrl)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)

                Button {
                    let trimmed = newWebhookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        prefs.healthWebhookUrls.append(trimmed)
                        newWebhookUrl = ""
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.green)
                }
                .accessibilityLabel("Add webhook URL")
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    @State private var showMqtt = false
    @State private var mqttPortText = String(PreferencesManager.shared.mqttPort)

    private var mqttSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showMqtt.toggle() }
            } label: {
                HStack {
                    Label("MQTT / Home Assistant", systemImage: "house.fill")
                        .font(.headline)
                    Spacer()
                    Text(prefs.mqttEnabled ? "On" : "Off")
                        .font(.subheadline)
                        .foregroundStyle(prefs.mqttEnabled ? Color.accentColor : Color.secondary)
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showMqtt ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            if showMqtt {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Publishes the latest value of each synced data type to your MQTT broker with Home Assistant Discovery: sensors appear automatically, no server-side setup needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Enable MQTT publishing", isOn: Binding(
                        get: { prefs.mqttEnabled },
                        set: { prefs.mqttEnabled = $0 }
                    ))

                    TextField("Broker host, e.g. 192.168.1.10", text: Binding(
                        get: { prefs.mqttHost },
                        set: { prefs.mqttHost = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    HStack {
                        TextField("Port", text: $mqttPortText)
                            .textFieldStyle(.roundedBorder)
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
                    }

                    TextField("Username (optional)", text: Binding(
                        get: { prefs.mqttUsername },
                        set: { prefs.mqttUsername = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    SecureField("Password (optional)", text: Binding(
                        get: { prefs.mqttPassword },
                        set: { prefs.mqttPassword = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)

                    TextField("Base topic", text: Binding(
                        get: { prefs.mqttBaseTopic },
                        set: { prefs.mqttBaseTopic = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    if !prefs.mqttLastStatus.isEmpty {
                        Text(prefs.mqttLastStatus)
                            .font(.caption)
                            .foregroundStyle(prefs.mqttLastStatus.hasPrefix("OK") ? Color.accentColor : Color.red)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var headersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showHeaders.toggle() }
            } label: {
                HStack {
                    Label("Custom Headers", systemImage: "doc.text.fill")
                        .font(.headline)
                    Spacer()
                    Image(systemName: showHeaders ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(.plain)

            if showHeaders {
                ForEach(Array(prefs.healthWebhookHeaders.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text("\(key): \(prefs.healthWebhookHeaders[key] ?? "")")
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            prefs.healthWebhookHeaders.removeValue(forKey: key)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .accessibilityLabel("Remove header \(key)")
                    }
                }

                HStack(spacing: 4) {
                    TextField("Key", text: $newHeaderKey)
                        .font(.caption)
                        .textFieldStyle(.roundedBorder)
                    TextField("Value", text: $newHeaderValue)
                        .font(.caption)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let key = newHeaderKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        let value = newHeaderValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !key.isEmpty, !value.isEmpty {
                            prefs.healthWebhookHeaders[key] = value
                            newHeaderKey = ""
                            newHeaderValue = ""
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.green)
                    }
                    .accessibilityLabel("Add header")
                }

                Divider()

                Text("HMAC Signing Secret")
                    .font(.subheadline)
                    .fontWeight(.medium)

                SecureField("Optional secret for X-Signature", text: Binding(
                    get: { prefs.healthSigningSecret },
                    set: { prefs.healthSigningSecret = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                ))
                .font(.caption)
                .textFieldStyle(.roundedBorder)

                Text("When set, every request includes X-Signature: sha256=HMAC-SHA256(secret, body) so your server can verify the sender.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var actionsSection: some View {
        VStack(spacing: 12) {
            // Pending queue indicator
            let pendingCount = PendingSyncStore.shared.pendingCount
            if pendingCount > 0 {
                HStack {
                    Image(systemName: "tray.full.fill")
                        .foregroundColor(.orange)
                    Text("\(pendingCount) pending sync(s)")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                    Button("Retry Now") {
                        Task {
                            await HealthSyncManager.shared.drainPendingQueue()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }

            // Test Ping: verify server setup without waiting for real data
            Button {
                isTestingWebhook = true
                syncMessage = nil
                Task {
                    let payload: [String: Any] = [
                        "test": true,
                        "message": "Test ping from Life Dashboard Companion",
                        "timestamp": Date().iso8601String,
                        "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                        "source": "healthkit_ios"
                    ]
                    guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                        return
                    }
                    let success = await WebhookManager.shared.post(
                        body: body,
                        urls: prefs.healthWebhookUrls,
                        headers: prefs.healthWebhookHeaders,
                        logType: .healthConnect,
                        dataType: "test",
                        recordCount: 0
                    )
                    await MainActor.run {
                        isTestingWebhook = false
                        syncMessage = success
                            ? "Test ping delivered"
                            : "Test ping failed, check the logs"
                    }
                }
            } label: {
                Label(isTestingWebhook ? "Pinging..." : "Send Test Ping", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(prefs.healthWebhookUrls.isEmpty || isTestingWebhook)

            // Preview Data
            Button {
                isLoadingPreview = true
                Task {
                    // Build and format off the main thread; rendering megabytes of JSON
                    // in a Text view freezes the UI, so the display copy is truncated.
                    let result: (display: String, full: String) = await Task.detached(priority: .userInitiated) {
                        do {
                            let payload = try await HealthSyncManager.shared.buildPreviewPayload()
                            let formatted = ExportManager.formatPayloadForPreview(payload)
                            let displayLimit = 100_000
                            if formatted.count > displayLimit {
                                let display = String(formatted.prefix(displayLimit))
                                    + "\n\n... [truncated for display, \(formatted.count) characters total - use the share button for the full payload]"
                                return (display, formatted)
                            }
                            return (formatted, formatted)
                        } catch {
                            let message = "Error: \(error.localizedDescription)"
                            return (message, message)
                        }
                    }.value
                    previewPayload = result.display
                    previewFullPayload = result.full
                    isLoadingPreview = false
                    showPreview = true
                }
            } label: {
                Label(isLoadingPreview ? "Loading..." : "Preview Data", systemImage: "eye.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(prefs.healthEnabledDataTypes.isEmpty || isLoadingPreview)

            // Sync Now
            Button {
                isSyncing = true
                syncMessage = nil
                Task {
                    let result = await HealthSyncManager.shared.performSync()
                    await MainActor.run {
                        isSyncing = false
                        switch result {
                        case .noData:
                            syncMessage = "No data to sync"
                        case .success(let counts):
                            let total = counts.values.reduce(0, +)
                            syncMessage = "Synced \(total) records"
                        case .failure(let error):
                            syncMessage = "Sync failed (queued for retry): \(error)"
                        }
                    }
                }
            } label: {
                Label(isSyncing ? "Syncing..." : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(prefs.healthWebhookUrls.isEmpty || prefs.healthEnabledDataTypes.isEmpty || isSyncing)

            if let message = syncMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(message.contains("failed") || message.contains("Error") ? .red : .green)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var previewSheet: some View {
        NavigationStack {
            ScrollView {
                Text(previewPayload)
                    .font(.system(.caption, design: .monospaced))
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
