import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Backup and restore: export every setting to a file, and import one from this app or the
/// Android app.
struct BackupRestoreScreen: View {
    @EnvironmentObject private var pairing: PairingCoordinator

    @State private var includeSecrets = true
    @State private var password = ""
    @State private var repeatPassword = ""
    @State private var isWorking = false
    @State private var document: SettingsBackupDocument?
    @State private var showExporter = false
    @State private var exportError: String?
    @FocusState private var focusedField: Field?

    @State private var showImporter = false
    @State private var importStep: ImportStep?
    @State private var importedTypes: Set<HealthDataType>?
    @State private var status: String?
    @State private var alertMessage: String?

    private enum Field { case password, repeatPassword }

    private static let minimumPasswordLength = 8

    private var passwordIsValid: Bool {
        password.count >= BackupRestoreScreen.minimumPasswordLength && password == repeatPassword
    }

    var body: some View {
        LDScreen {
            LDHeading("Backup and restore")
            LDNote("Move your settings to another phone. Logs and sync progress stay where they are.", top: 6)

            LDSectionLabel("Export")
            exportCard
            exportNotes
            LDGap(10)
            // The picker and the save dialog hang on separate views: SwiftUI shows only one of
            // two on the same view.
            LDButton("Export settings", action: prepareExport)
                .overlay(alignment: .trailing) {
                    if isWorking {
                        ProgressView()
                            .tint(LDTheme.onAccent)
                            .padding(.trailing, 32)
                    }
                }
                .disabled(isWorking || (includeSecrets && !passwordIsValid))
                .accessibilityHint("Saves your settings as a file")
                .fileExporter(
                    isPresented: $showExporter,
                    document: document,
                    contentType: .json,
                    defaultFilename: includeSecrets ? "life-dashboard-config.encrypted" : "life-dashboard-config"
                ) { result in
                    switch result {
                    case .success:
                        report("Settings exported")
                        clearExport()
                    case .failure(let error):
                        exportError = String(localized: "Export failed: \(error.localizedDescription)")
                    }
                }

            LDSectionLabel("Import")
            LDCard {
                LDRow("Choose a backup file")
                    .ldButton { showImporter = true }
                    .accessibilityHint("Replaces your settings with a file")
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                handlePickedFile(result)
            }

            if let status {
                LDNote(Text(verbatim: status), size: 13)
            }
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $importStep, onDismiss: requestHealthAccessAfterImport) { step in
            ImportSheet(step: step) { types in
                importedTypes = types
                report("Settings imported")
            }
        }
        // A pairing link needs the root sheet, which cannot show over one of these.
        .onChange(of: pairing.incoming) { _, _ in
            showExporter = false
            showImporter = false
            importStep = nil
        }
        .alert(alertMessage ?? "", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
        .onDisappear {
            password = ""
            repeatPassword = ""
        }
    }

    // MARK: - Export

    private var exportCard: some View {
        LDCard {
            LDToggleRow(
                "Include secrets",
                subtitle: Text("Auth headers, signing secret and MQTT password"),
                isOn: $includeSecrets
            )
            if includeSecrets {
                LDFieldRow("Password", text: $password, isSecure: true)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .repeatPassword }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LDFieldRow("Repeat password", text: $repeatPassword, isSecure: true)
                    .focused($focusedField, equals: .repeatPassword)
                    .submitLabel(.done)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    @ViewBuilder private var exportNotes: some View {
        if includeSecrets {
            if !password.isEmpty && password.count < BackupRestoreScreen.minimumPasswordLength {
                LDNote("At least 8 characters", color: LDTheme.warning, size: 13)
            } else if !repeatPassword.isEmpty && password != repeatPassword {
                LDNote("The passwords do not match", color: LDTheme.warning, size: 13)
            }
            LDNote("The file contains your secrets, encrypted with this password. Without it the export cannot be restored, so store it somewhere safe. Use a long password, for example four random words.", size: 13)
        } else {
            LDNote("The file holds your webhook URLs, MQTT host and options, but no credentials. A webhook URL can work as a password, so share the file with care.", size: 13)
        }
        if let exportError {
            LDNote(Text(verbatim: exportError), color: LDTheme.warning, size: 13)
        }
    }

    private func prepareExport() {
        exportError = nil
        status = nil
        isWorking = true
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let backup = SettingsBackup.export(
            PreferencesManager.shared.backupSnapshot(),
            includeSecrets: includeSecrets,
            appVersion: version
        )
        let password = includeSecrets ? password : nil
        Task {
            // The key derivation takes a noticeable moment on older phones: keep it off the main actor.
            let result = await Task.detached {
                Result {
                    let plain = try SettingsBackup.encode(backup)
                    guard let password else { return plain }
                    return try SettingsBackupCrypto.encrypt(plain, password: password)
                }
            }.value
            isWorking = false
            switch result {
            case .success(let data):
                document = SettingsBackupDocument(data: data)
                showExporter = true
            case .failure(let error):
                exportError = String(localized: "Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func clearExport() {
        password = ""
        repeatPassword = ""
        document = nil
    }

    // MARK: - Import

    private func handlePickedFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            alertMessage = String(localized: "Could not read that file")
            return
        }
        Task {
            let contents = await Task.detached {
                Result { try SettingsBackup.classify(SettingsBackup.readPickedFile(url)) }
            }.value
            switch contents {
            case .success(.encrypted(let envelope)):
                importStep = .unlock(envelope)
            case .success(.plain(let backup)):
                importStep = .preview(backup)
            case .failure(let error):
                alertMessage = SettingsBackupSection.message(for: error)
            }
        }
    }

    /// HealthKit's permission sheet cannot appear while the import sheet is still closing.
    private func requestHealthAccessAfterImport() {
        guard let types = importedTypes else { return }
        importedTypes = nil
        guard !types.isEmpty else { return }
        Task { try? await HealthKitManager.shared.requestAuthorization(for: types) }
    }

    private func report(_ message: String.LocalizationValue) {
        let text = String(localized: message)
        status = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AccessibilityNotification.Announcement(text).post()
    }
}

// MARK: - Import sheet

private struct ImportSheet: View {
    let onImported: (Set<HealthDataType>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var envelope: Data?
    @State private var backup: ConfigBackup?
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var passwordFocused: Bool

    init(step: ImportStep, onImported: @escaping (Set<HealthDataType>) -> Void) {
        self.onImported = onImported
        switch step {
        case .unlock(let data): _envelope = State(initialValue: data)
        case .preview(let file): _backup = State(initialValue: file)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let backup {
                    preview(backup)
                } else {
                    unlockForm
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(LDTheme.accentText)
        .presentationDragIndicator(.visible)
        .presentationBackground(LDTheme.sheet)
    }

    // MARK: Unlock

    private var unlockForm: some View {
        LDScreen(background: LDTheme.sheet) {
            LDSectionLabel("This file is password-protected.")
            LDCard {
                LDFieldRow("Password", text: $password, isSecure: true)
                    .focused($passwordFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(unlock)
                    .onChange(of: password) { errorMessage = nil }
            }
            if let errorMessage {
                LDNote(Text(verbatim: errorMessage), color: LDTheme.warning, size: 13)
            }
        }
        .navigationTitle("Encrypted export")
        .onAppear { passwordFocused = true }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { close() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isWorking {
                    ProgressView()
                } else {
                    Button("Unlock", action: unlock)
                        .disabled(password.isEmpty)
                }
            }
        }
    }

    private func unlock() {
        guard let envelope, !password.isEmpty, !isWorking else { return }
        isWorking = true
        let password = password
        Task {
            let result = await Task.detached {
                Result { try SettingsBackup.decode(SettingsBackupCrypto.decrypt(envelope, password: password)) }
            }.value
            isWorking = false
            switch result {
            case .success(let file):
                self.password = ""
                backup = file
            case .failure(let error):
                let message = SettingsBackupSection.message(for: error)
                errorMessage = message
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }

    // MARK: Preview

    @ViewBuilder
    private func preview(_ file: ConfigBackup) -> some View {
        let prefs = PreferencesManager.shared
        switch Result(catching: { try SettingsImport.plan(file, current: prefs.backupSnapshot()) }) {
        case .success(let plan):
            previewForm(plan, file: file)
        case .failure(let error):
            LDScreen(background: LDTheme.sheet) {
                LDNote(Text(verbatim: SettingsBackupSection.message(for: error)), color: LDTheme.warning, top: 16)
            }
            .navigationTitle("Import settings?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }
                }
            }
        }
    }

    private func previewForm(_ plan: ImportPlan, file: ConfigBackup) -> some View {
        let result = plan.result
        return LDScreen(background: LDTheme.sheet) {
            LDSectionLabel("This replaces your current settings:")
            LDCard {
                LDRow("Webhooks", value: Text(verbatim: "\(result.healthWebhookUrls.count)"), showsChevron: false)
                ForEach(result.healthDestinations) { destination in
                    let names = destination.headers.keys.sorted().joined(separator: ", ")
                    Group {
                        if names.isEmpty {
                            Text("\(destination.host), no custom headers")
                        } else {
                            Text("\(destination.host), headers: \(names)")
                        }
                    }
                    .font(LDType.rowSubtitle)
                    .foregroundStyle(LDTheme.muted)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                LDRow("Data Types", value: Text(verbatim: "\(result.healthEnabledDataTypes.count)"), showsChevron: false)
                LDRow(
                    "Sync Schedule",
                    value: Text(verbatim: result.healthSyncSchedule.isNeverRunning ? String(localized: "Never syncs") : result.healthSyncSchedule.summary),
                    showsChevron: false
                )
                LDRow("MQTT", value: Text(verbatim: mqttSummary(result)), showsChevron: false)
                LDRow(
                    "Secrets",
                    value: plan.includesSecrets ? Text("Included") : Text("Not included"),
                    showsChevron: false
                )
            }
            LDNote(Text(verbatim: sourceLine(plan)), size: 13)
            ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                LDNote(Text(note.text))
            }
            LDNote("Logs and sync progress are not affected.", size: 13)
            if let errorMessage {
                LDNote(Text(verbatim: errorMessage), color: LDTheme.warning, size: 13)
            }
        }
        .navigationTitle("Import settings?")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { close() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") { apply(file) }
            }
        }
    }

    private func mqttSummary(_ settings: SettingsSnapshot) -> String {
        guard settings.mqttEnabled, !settings.mqttHost.isEmpty else { return String(localized: "Off") }
        let tls = settings.mqttUseTls ? String(localized: "TLS") : String(localized: "no TLS")
        return "\(settings.mqttHost):\(settings.mqttPort), \(tls)"
    }

    /// Whole sentences per app, so no translation has to fit "the iPhone app" into another
    /// sentence's grammar. The version is a number, so it can be appended.
    private func sourceLine(_ plan: ImportPlan) -> String {
        let fromIPhone = plan.platform == SettingsBackup.platformName
        let version = plan.appVersion.map { " \($0)" } ?? ""
        guard let date = plan.exportedAt else {
            return fromIPhone
                ? String(localized: "Exported by the iPhone app\(version).")
                : String(localized: "Exported by the Android app\(version).")
        }
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return fromIPhone
            ? String(localized: "Exported \(when) by the iPhone app\(version).")
            : String(localized: "Exported \(when) by the Android app\(version).")
    }

    private func apply(_ file: ConfigBackup) {
        let prefs = PreferencesManager.shared
        // Planned again against the settings as they are now, not as they were when the
        // preview opened.
        guard let plan = try? SettingsImport.plan(file, current: prefs.backupSnapshot()) else {
            errorMessage = String(localized: "Not a valid settings file")
            return
        }
        prefs.applyBackup(plan.result)

        let background = BackgroundSyncManager.shared
        background.reconfigureObservers()
        background.replan()
        onImported(plan.result.healthEnabledDataTypes)
        close()
    }

    private func close() {
        password = ""
        dismiss()
    }
}
