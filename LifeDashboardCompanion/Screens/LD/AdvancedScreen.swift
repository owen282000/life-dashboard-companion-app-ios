import SwiftUI
import UniformTypeIdentifiers

/// Daily totals and the client certificate (mTLS), imported from a file: iOS offers apps no system
/// picker for certificates.
struct AdvancedScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared
    @EnvironmentObject private var pairing: PairingCoordinator

    @State private var showImporter = false
    @State private var pickedFile: Data?
    @State private var password = ""
    @State private var isImporting = false
    @State private var confirmRemove = false
    @State private var alertMessage: String?

    /// A real .p12 is a few KB; the cap keeps a stray large file from being read into memory.
    private nonisolated static let maxFileBytes = 1_048_576

    var body: some View {
        LDScreen {
            LDHeading("Advanced")
            LDSectionLabel("Payload")
            LDCard {
                LDToggleRow("Daily totals in payload", isOn: $prefs.includeDailyTotals)
            }
            .ldStaggerRise(0)
            LDNote("Per-day totals (steps, distance, calories) as the Health app counts them, with overlapping iPhone and Watch data counted once", size: 13)

            LDSectionLabel("Connection")
            LDCard {
                LDRow(
                    "Client certificate (mTLS)",
                    subtitle: Text("Used for every webhook"),
                    value: prefs.clientCertificate == nil ? Text("None") : nil,
                    showsChevron: false
                )
                if let certificate = prefs.clientCertificate {
                    LDRow(Text(verbatim: certificate.subject), subtitle: expiry(of: certificate), showsChevron: false)
                }
            }
            .ldStaggerRise(1)
            LDGap(10)
            certificateActions
            LDNote("For a server that requires a client certificate. Import it as a .p12 file with its password; it is kept in this iPhone's Keychain and never leaves it. Used for every webhook, also in the background. MQTT is unaffected.", size: 13)
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pkcs12]) { result in
            handlePickedFile(result)
        }
        .alert("Certificate password", isPresented: Binding(
            get: { pickedFile != nil },
            set: { if !$0 { pickedFile = nil; password = "" } }
        )) {
            SecureField("Password", text: $password)
            Button("Cancel", role: .cancel) { password = "" }
            Button("Import") { importPickedFile() }
        } message: {
            Text("The password the .p12 file was exported with.")
        }
        .confirmationDialog("Remove the client certificate?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { removeCertificate() }
        } message: {
            Text("Webhooks that require it refuse every sync until you import it again.")
        }
        .alert(alertMessage ?? "", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
        // A pairing link needs the root sheet, which cannot show over the file picker.
        .onChange(of: pairing.incoming) { _, _ in showImporter = false }
    }

    @ViewBuilder private var certificateActions: some View {
        if isImporting {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 44)
        } else if prefs.clientCertificate == nil {
            LDButton("Import .p12", kind: .ghost, size: .medium) { showImporter = true }
        } else {
            HStack(spacing: 8) {
                LDButton("Replace", kind: .ghost, size: .medium, inset: 0) { showImporter = true }
                LDButton("Remove", kind: .danger, size: .medium, inset: 0) { confirmRemove = true }
            }
            .padding(.horizontal, LDTheme.cardInset)
        }
    }

    private func expiry(of certificate: ClientCertificateInfo) -> Text? {
        guard let expiresAt = certificate.expiresAt else { return nil }
        let date = expiresAt.formatted(date: .abbreviated, time: .omitted)
        if certificate.isExpired() {
            return Text("Expired on \(date)").foregroundColor(LDTheme.warning)
        }
        return Text("Expires on \(date)")
            .foregroundColor(certificate.needsAttention() ? LDTheme.warning : LDTheme.muted)
    }

    private func removeCertificate() {
        guard ClientCertificateStore.remove() else {
            alertMessage = String(localized: "Could not remove the certificate from the Keychain")
            return
        }
        prefs.clientCertificate = nil
        Task { await WebhookManager.shared.dropConnections() }
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            alertMessage = String(localized: "Could not read that file")
            return
        }
        Task {
            // Off the main thread: a file in iCloud Drive is downloaded first.
            let data = await Task.detached(priority: .userInitiated) { AdvancedScreen.read(url) }.value
            guard let data else {
                alertMessage = String(localized: "Could not read that file")
                return
            }
            password = ""
            pickedFile = data
        }
    }

    /// The file's bytes, or nil when it cannot be read or is larger than any real .p12.
    private nonisolated static func read(_ url: URL) -> Data? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes + 1), data.count <= maxFileBytes else { return nil }
        return data
    }

    private func importPickedFile() {
        guard let data = pickedFile else { return }
        let secret = password
        password = ""
        pickedFile = nil
        isImporting = true
        Task {
            // The file's key derivation takes a moment; off the main thread.
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ClientCertificateStore.importPKCS12(data, password: secret) }
            }.value
            isImporting = false
            switch result {
            case .success(let info):
                prefs.clientCertificate = info
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .failure(let error):
                // The Keychain refused the new identity after the old one was deleted.
                if case .keychain = error as? ClientCertificateError { prefs.clientCertificate = nil }
                alertMessage = Self.message(for: error)
            }
            await WebhookManager.shared.dropConnections()
        }
    }

    private static func message(for error: Error) -> String {
        switch error as? ClientCertificateError {
        case .wrongPassword:
            return String(localized: "Wrong password for this certificate file")
        case .noIdentity:
            return String(localized: "This file has no private key. Export the certificate together with its key.")
        case .keychain(let status):
            return String(localized: "Could not save the certificate in the Keychain (error \(Int(status)))")
        case .unreadable, nil:
            return String(localized: "This is not a certificate file the iPhone can read. Export it as a .p12 file with its private key.")
        }
    }
}
