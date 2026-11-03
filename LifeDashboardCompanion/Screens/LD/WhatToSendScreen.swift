import SwiftUI
import HealthKit

/// The rule behind Grant, under the name the tests hold it to.
enum HealthKitScreen {
    /// HealthKit never says whether read access was given, only whether asking would show the sheet.
    static func showsGrant(_ request: HKAuthorizationRequestStatus?, enabledCount: Int) -> Bool {
        enabledCount > 0 && request == .shouldRequest
    }
}

/// Which types go out and how: the presets, the categories, resolution, history and preview, and
/// Grant while iOS still has something to ask.
struct WhatToSendScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared
    @ObservedObject private var healthKit = HealthKitManager.shared
    @ObservedObject private var backfill = BackfillController.shared
    @EnvironmentObject private var navigator: LDNavigator

    @State private var accessRequest: HKAuthorizationRequestStatus?
    @State private var confirmNone = false

    var body: some View {
        let enabled = prefs.healthEnabledDataTypes
        LDScreen {
            LDHeading(Text("\(enabled.count) of \(HealthDataType.allCases.count) types."))
            LDSectionLabel("Start from")
            presets(enabled)
            LDSectionLabel("By category")
            categories(enabled)
                .ldStaggerRise(0)
            LDSectionLabel("How it goes out")
            howItGoesOut(enabled)
                .ldStaggerRise(1)
            if let job = backfill.job, job.status == .done {
                LDNote(Text("Backfill complete: \(job.recordsSent) records sent"), color: LDTheme.accentTextSoft)
            }
            LDGap(10)
            LDCard {
                accessRow
            }
            .ldStaggerRise(2)
        }
        .navigationTitle("What to send")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: enabled) { await refreshAccessRequest() }
        .confirmationDialog("Stop sending all types?", isPresented: $confirmNone, titleVisibility: .visible) {
            Button("Turn off all types", role: .destructive) { apply([]) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing is sent until you pick types again.")
        }
        #if DEBUG
        .onAppear { LDTypeCategory.assertCoversEveryType() }
        #endif
    }

    // MARK: - Presets

    @ViewBuilder
    private func presets(_ enabled: Set<HealthDataType>) -> some View {
        let everything = Set(HealthDataType.allCases)
        LDChips {
            LDChip("Essentials", isSelected: enabled == OnboardingView.essentials) {
                apply(OnboardingView.essentials)
            }
            LDChip("All types", isSelected: enabled == everything) {
                apply(everything)
            }
            LDChip("None", isSelected: enabled.isEmpty) {
                if !enabled.isEmpty { confirmNone = true }
            }
        }
    }

    private func apply(_ types: Set<HealthDataType>) {
        Task {
            await WhatToSendSelection.apply(types, prefs: prefs)
            await refreshAccessRequest()
        }
    }

    // MARK: - Cards

    private func categories(_ enabled: Set<HealthDataType>) -> some View {
        LDCard {
            ForEach(LDTypeCategory.allCases, id: \.self) { category in
                let types = category.types
                LDRow(category.title, value: types.isEmpty ? Text("Not available yet") : Text("\(types.filter(enabled.contains).count) of \(types.count)"))
                    .ldLink(to: .typeCategory(category))
            }
            AboutLinkRow("Missing a type?", subtitle: Text("Tell us which one you want next"), url: AboutLinks.missingType)
        }
    }

    private func howItGoesOut(_ enabled: Set<HealthDataType>) -> some View {
        let bucketed = DataResolutionScreen.bucketedCount(prefs.seriesResolutions, enabled: enabled)
        return LDCard {
            LDRow("Data resolution", value: bucketed == 0 ? Text("Every record") : Text("\(bucketed) bucketed"))
                .ldLink(to: .dataResolution)
            LDRow("Send history", value: backfillValue, valueColor: backfill.job?.status == .failed ? LDTheme.warning : LDTheme.muted)
                .ldButton(action: openBackfill)
            LDRow("Preview payload")
                .ldButton { navigator.present(.payloadPreview) }
                .disabled(enabled.isEmpty)
        }
    }

    private var backfillValue: Text {
        guard let job = backfill.job, let line = LDBackfillStatus.shortLine(job, backfill: backfill) else {
            return Text("Backfill")
        }
        return line
    }

    /// A backfill that is running or waiting continues from its own page.
    private func openBackfill() {
        if let job = backfill.job, job.status != .done {
            navigator.push(.backfillRun)
        } else {
            navigator.present(.backfill)
        }
    }

    // MARK: - Apple Health access

    /// HealthKit never says whether read access was given, only whether asking would show the
    /// sheet, so there is no "granted" state to show: without Grant the row is plain.
    @ViewBuilder
    private var accessRow: some View {
        let subtitle = healthKit.isAvailable
            ? Text("iOS asks once per type")
            : Text("This device cannot share Health data with apps.")
        if HealthKitScreen.showsGrant(accessRequest, enabledCount: prefs.healthEnabledDataTypes.count) {
            LDRow("Apple Health access", subtitle: subtitle, value: Text("Grant"))
                .ldButton {
                    Task {
                        try? await healthKit.requestAuthorization(for: prefs.healthEnabledDataTypes)
                        await refreshAccessRequest()
                    }
                }
        } else {
            LDRow("Apple Health access", subtitle: subtitle, showsChevron: false)
        }
    }

    private func refreshAccessRequest() async {
        let types = healthKit.readTypesFor(prefs.healthEnabledDataTypes)
        guard !types.isEmpty else {
            accessRequest = nil
            return
        }
        accessRequest = try? await healthKit.healthStore.statusForAuthorizationRequest(toShare: [], read: types)
    }
}
