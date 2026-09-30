import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The file handed to the save dialog. `.fileExporter` writes it straight to where the user
/// picks, so no copy of an export with secrets is left in the app's temporary folder.
struct SettingsBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Backup & restore: export every setting to a file, and import one from this app or the
/// Android app. Self-contained, so it can move to another screen without touching the logic.
struct SettingsBackupSection: View {
    @EnvironmentObject private var pairing: PairingCoordinator
    @State private var showExport = false
    @State private var showImporter = false
    @State private var importStep: ImportStep?
    @State private var importedTypes: Set<HealthDataType>?
    @State private var status: String?
    @State private var alertMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save your settings to a file, to set up this app again or move to the Android app.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button {
                    showExport = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Saves your settings as a file")

                Button {
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Replaces your settings with a file")
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                    handlePickedFile(result)
                }
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet { report("Settings exported") }
        }
        .sheet(item: $importStep, onDismiss: requestHealthAccessAfterImport) { step in
            ImportSheet(step: step) { types in
                importedTypes = types
                report("Settings imported")
            }
        }
        // A pairing link needs the root sheet, which cannot show over one of these.
        .onChange(of: pairing.incoming) { _, _ in
            showExport = false
            showImporter = false
            importStep = nil
        }
        .alert(alertMessage ?? "", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
    }

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

    static func message(for error: Error) -> String {
        switch error {
        case SettingsBackupError.notASettingsFile(let path?):
            return String(localized: "Not a valid settings file (\(path))")
        case SettingsBackupError.notASettingsFile(nil), SettingsBackupCryptoError.notAnEnvelope:
            return String(localized: "Not a valid settings file")
        case SettingsBackupCryptoError.wrongPassword:
            return String(localized: "Wrong password, or the file is damaged")
        case SettingsBackupCryptoError.unsupported:
            return String(localized: "This file needs a newer version of the app")
        default:
            return String(localized: "Could not read that file")
        }
    }
}

/// What the import sheet opens with: a password prompt for an encrypted file, or the preview.
enum ImportStep: Identifiable {
    case unlock(Data)
    case preview(ConfigBackup)

    var id: String {
        switch self {
        case .unlock: return "unlock"
        case .preview: return "preview"
        }
    }
}

// MARK: - Export

private struct ExportSheet: View {
    let onExported: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var includeSecrets = true
    @State private var password = ""
    @State private var repeatPassword = ""
    @State private var isWorking = false
    @State private var document: SettingsBackupDocument?
    @State private var showExporter = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case password, repeatPassword }

    private static let minimumPasswordLength = 8

    private var passwordIsValid: Bool {
        password.count >= ExportSheet.minimumPasswordLength && password == repeatPassword
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $includeSecrets) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Include secrets")
                            Text("Auth headers, signing secret and MQTT password")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    if !includeSecrets {
                        Text("The file holds your webhook URLs, MQTT host and options, but no credentials. A webhook URL can work as a password, so share the file with care.")
                    }
                }

                if includeSecrets {
                    Section {
                        SecureField("Password", text: $password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .repeatPassword }
                        SecureField("Repeat password", text: $repeatPassword)
                            .focused($focusedField, equals: .repeatPassword)
                            .submitLabel(.done)
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            if !password.isEmpty && password.count < ExportSheet.minimumPasswordLength {
                                Label("At least 8 characters", systemImage: "exclamationmark.triangle.fill")
                            } else if !repeatPassword.isEmpty && password != repeatPassword {
                                Label("The passwords do not match", systemImage: "exclamationmark.triangle.fill")
                            }
                            Text("The file contains your secrets, encrypted with this password. Without it the export cannot be restored, so store it somewhere safe. Use a long password, for example four random words.")
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Export settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Export") { prepareExport() }
                            .disabled(includeSecrets && !passwordIsValid)
                    }
                }
            }
            // Presented from inside the sheet, so it never races the sheet's own dismissal.
            .fileExporter(
                isPresented: $showExporter,
                document: document,
                contentType: .json,
                defaultFilename: includeSecrets ? "life-dashboard-config.encrypted" : "life-dashboard-config"
            ) { result in
                switch result {
                case .success:
                    onExported()
                    close()
                case .failure(let error):
                    errorMessage = String(localized: "Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func prepareExport() {
        errorMessage = nil
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
                errorMessage = String(localized: "Export failed: \(error.localizedDescription)")
            }
        }
    }

    private func close() {
        password = ""
        repeatPassword = ""
        document = nil
        dismiss()
    }
}

// MARK: - Import

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
    }

    // MARK: Unlock

    private var unlockForm: some View {
        Form {
            Section {
                SecureField("Password", text: $password)
                    .focused($passwordFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(unlock)
                    .onChange(of: password) { errorMessage = nil }
            } header: {
                Text("This file is password-protected.")
            } footer: {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
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
            Form {
                Label(SettingsBackupSection.message(for: error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
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
        return Form {
            Section {
                LabeledContent("Webhooks", value: "\(result.healthWebhookUrls.count)")
                ForEach(result.healthWebhookUrls, id: \.self) { url in
                    let host = URLComponents(string: url)?.host ?? url
                    Group {
                        if !result.healthWebhookHeaders.isEmpty && result.healthUrlsWithoutHeaders.contains(url) {
                            Text("\(host), no custom headers")
                        } else {
                            Text(host)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                if !result.healthWebhookHeaders.isEmpty {
                    LabeledContent("Custom headers", value: result.healthWebhookHeaders.keys.sorted().joined(separator: ", "))
                }
                LabeledContent("Data types", value: "\(result.healthEnabledDataTypes.count)")
                LabeledContent(
                    "Sync schedule",
                    value: result.healthSyncSchedule.isNeverRunning ? String(localized: "Never syncs") : result.healthSyncSchedule.summary
                )
                LabeledContent("MQTT", value: mqttSummary(result))
                LabeledContent(
                    "Secrets",
                    value: plan.includesSecrets ? String(localized: "Included") : String(localized: "Not included")
                )
            } header: {
                Text("This replaces your current settings:")
            } footer: {
                Text(sourceLine(plan))
            }

            Section {
                ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                    Text(note.text)
                        .font(.subheadline)
                }
            } footer: {
                Text("Logs and sync progress are not affected.")
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

    private func sourceLine(_ plan: ImportPlan) -> String {
        let app = plan.platform == SettingsBackup.platformName
            ? String(localized: "the iPhone app")
            : String(localized: "the Android app")
        let version = plan.appVersion.map { " \($0)" } ?? ""
        guard let date = plan.exportedAt else { return String(localized: "Exported by \(app)\(version).") }
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Exported \(when) by \(app)\(version).")
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
