import SwiftUI

/// What a sync would send now. The screen shows at most PayloadPreview's 12,000 characters; Copy
/// and Share have all of it.
struct PayloadPreviewScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared

    @State private var isLoading = true
    @State private var preview: PayloadPreview?
    @State private var fullPayload = ""
    @State private var fileURL: URL?
    @State private var copyOutcome: PayloadCopy.Outcome?

    var body: some View {
        LDScreen(background: LDTheme.sheet) {
            LDNote("This is what your server receives.", top: 4)
            LDGap(10)
            content
        } footer: {
            VStack(spacing: 0) {
                if let copyOutcome {
                    LDNote(
                        Text(verbatim: copyOutcome.message),
                        color: copyOutcome == .copied ? LDTheme.accentTextSoft : LDTheme.warning,
                        size: 13
                    )
                    .padding(.bottom, 8)
                    .background(LDTheme.sheet)
                }
                LDFooterBar(background: LDTheme.sheet) {
                    LDButton("Copy JSON", kind: .ghost, size: .medium, inset: 0, action: copy)
                    LDButton("Share", kind: .ghost, size: .medium, inset: 0, action: share)
                }
                // Not for a preview that failed to build: the text is then the error.
                .disabled(preview == nil)
            }
        }
        .navigationTitle("Preview")
        .ldSheetToolbar(cancel: "Done")
        .shareSheet(for: $fileURL)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if prefs.healthEnabledDataTypes.isEmpty {
            LDNote("No data types selected", top: 0)
        } else if isLoading {
            ProgressView()
                .tint(LDTheme.accent)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let preview {
            LDCodeBlock(text: preview.text, wraps: true, selectable: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Payload, \(preview.totalCount.formatted()) characters"))
            if preview.cutForDisplay {
                LDNote(Text("Showing the first \(PayloadPreview.maxCharacters.formatted()) of \(preview.totalCount.formatted()) characters."), size: 13)
                LDNote("Use the copy or share button for the full payload.", top: 2, size: 13)
            }
        } else {
            // The error a failed build left in fullPayload, read as it is.
            LDNote(Text(verbatim: fullPayload), color: LDTheme.warning, top: 0)
        }
    }

    private func load() async {
        guard isLoading, !prefs.healthEnabledDataTypes.isEmpty else { return }
        // Build, format and cap off the main thread: laying out more than PayloadPreview's
        // 12,000 characters in one Text stalls the screen (P2-11).
        let result: (display: PayloadPreview?, full: String) = await Task.detached(priority: .userInitiated) {
            do {
                let payload = try await HealthSyncManager.shared.buildPreviewPayload()
                let formatted = ExportManager.formatPayloadForPreview(payload)
                return (PayloadPreview.of(formatted), formatted)
            } catch {
                return (nil, String(localized: "Error: \(error.localizedDescription)"))
            }
        }.value
        preview = result.display
        fullPayload = result.full
        isLoading = false
    }

    private func copy() {
        let outcome = PayloadCopy.copy(fullPayload)
        copyOutcome = outcome
        AccessibilityNotification.Announcement(outcome.message).post()
    }

    /// The same file as Export JSON, written off the main thread: a week of heart rate is a few
    /// megabytes.
    private func share() {
        let payload = fullPayload
        Task {
            fileURL = await Task.detached(priority: .userInitiated) {
                try? ExportManager.writePayloadFile(payload, prefix: ExportManager.healthExportPrefix)
            }.value
        }
    }
}
