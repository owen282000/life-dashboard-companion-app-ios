import SwiftUI
import UniformTypeIdentifiers

/// The Advanced row's client certificate (mTLS): the Android app's ClientCertLine, with a file
/// import in place of Android's system picker, which iOS does not offer to apps.
struct ClientCertificateLine: View {
    @ObservedObject var prefs: PreferencesManager

    @State private var showImporter = false
    @State private var pickedFile: Data?
    @State private var password = ""
    @State private var isImporting = false
    @State private var confirmRemove = false
    @State private var alertMessage: String?

    /// A real .p12 is a few KB; the cap keeps a stray large file from being read into memory.
    private nonisolated static let maxFileBytes = 1_048_576

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Client certificate (mTLS)")
                        .font(.subheadline)
                    status
                }
                Spacer(minLength: 8)
                if isImporting {
                    ProgressView()
                } else {
                    if prefs.clientCertificate == nil {
                        Button("Import") { showImporter = true }
                            .font(.subheadline)
                            .tint(Brand.ink)
                    } else {
                        Button("Remove", role: .destructive) { confirmRemove = true }
                            .font(.subheadline)
                        Button("Replace") { showImporter = true }
                            .font(.subheadline)
                            .tint(Brand.ink)
                    }
                }
            }
            Text("For a server that requires a client certificate. Import it as a .p12 file with its password; it is kept in this iPhone's Keychain and never leaves it. Used for every webhook, also in the background. MQTT is unaffected.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
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
            Button("Remove", role: .destructive) {
                guard ClientCertificateStore.remove() else {
                    alertMessage = String(localized: "Could not remove the certificate from the Keychain")
                    return
                }
                prefs.clientCertificate = nil
                Task { await WebhookManager.shared.dropConnections() }
            }
        } message: {
            Text("Webhooks that require it refuse every sync until you import it again.")
        }
        .alert(alertMessage ?? "", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder private var status: some View {
        if let certificate = prefs.clientCertificate {
            Text(verbatim: certificate.subject)
                .font(.footnote)
                .foregroundColor(.secondary)
            if let expiresAt = certificate.expiresAt {
                let date = expiresAt.formatted(date: .abbreviated, time: .omitted)
                Group {
                    if certificate.isExpired() {
                        Text("Expired on \(date)")
                    } else {
                        Text("Expires on \(date)")
                    }
                }
                .font(.footnote)
                .foregroundColor(certificate.isExpired() ? Brand.errorInk : certificate.needsAttention() ? Brand.warningInk : .secondary)
            }
        } else {
            Text("None")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            alertMessage = String(localized: "Could not read that file")
            return
        }
        Task {
            // Off the main thread: a file in iCloud Drive is downloaded first.
            let data = await Task.detached(priority: .userInitiated) { ClientCertificateLine.read(url) }.value
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
                alertMessage = ClientCertificateLine.message(for: error)
            }
            await WebhookManager.shared.dropConnections()
        }
    }

    static func message(for error: Error) -> String {
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
