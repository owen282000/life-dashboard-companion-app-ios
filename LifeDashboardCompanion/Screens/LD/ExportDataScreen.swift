import SwiftUI

struct ExportDataScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared
    @EnvironmentObject private var pairing: PairingCoordinator

    @State private var exporting: ExportManager.HealthExportFormat?
    @State private var exportFileURL: URL?
    @State private var failure: String?

    private var canExport: Bool {
        !prefs.healthEnabledDataTypes.isEmpty && exporting == nil
    }

    var body: some View {
        LDScreen {
            LDHeading("Export your data.")
            LDNote("A file with the selected types from Apple Health.", top: 6)
            LDGap(12)
            LDCard {
                exportRow("Export CSV", format: .csv)
                exportRow("Export JSON", format: .json)
            }
            .ldStaggerRise(0)
            if prefs.healthEnabledDataTypes.isEmpty {
                LDNote("No data types selected", size: 13)
            } else {
                LDNote("Opens the share sheet.", size: 13)
            }
            if let failure {
                LDNote(Text("Export failed: \(failure)"), color: LDTheme.warning, size: 13)
            }
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .shareSheet(for: $exportFileURL)
        // A pairing link needs the root sheet, which cannot show over this one.
        .onChange(of: pairing.incoming) { _, _ in exportFileURL = nil }
    }

    private func exportRow(_ title: LocalizedStringKey, format: ExportManager.HealthExportFormat) -> some View {
        LDRow(title) {
            if exporting == format {
                ProgressView()
            }
        }
        .ldButton { export(format) }
        // The row at work stays bright, with its spinner.
        .disabled(!canExport && exporting != format)
    }

    private func export(_ format: ExportManager.HealthExportFormat) {
        guard exporting == nil else { return }
        exporting = format
        failure = nil
        Task {
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let payload = try await HealthSyncManager.shared.buildPreviewPayload()
                    return .success(try ExportManager.writeHealthExport(payload, format: format))
                } catch {
                    return .failure(error)
                }
            }.value
            exporting = nil
            switch result {
            case .success(let url):
                exportFileURL = url
            case .failure(let error):
                let reason = error.localizedDescription
                failure = reason
                AccessibilityNotification.Announcement(String(localized: "Export failed: \(reason)")).post()
            }
        }
    }
}
