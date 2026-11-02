import SwiftUI

/// Data resolution per type: every record, or one averaged (or summed) value per window. Only the
/// types where a window means something appear, and only the ones switched on, grouped by what a
/// window does to them.
struct DataResolutionScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared

    /// The enabled types that are not at every record, the number on What to send.
    static func bucketedCount(_ resolutions: [HealthDataType: SeriesResolution], enabled: Set<HealthDataType>) -> Int {
        ResolutionFamily.configurableTypes.filter { enabled.contains($0) && (resolutions[$0] ?? .raw) != .raw }.count
    }

    var body: some View {
        let configurable = ResolutionFamily.configurableTypes.filter { prefs.healthEnabledDataTypes.contains($0) }
        LDScreen {
            LDHeading("Data resolution")
            LDNote("Dense series like heart rate can be sent as averages per time window instead of every single record. Smaller payloads, less detail.", top: 6)
            ForEach(ResolutionFamily.allCases, id: \.self) { family in
                let types = configurable.filter { ResolutionFamily.of($0) == family }
                if !types.isEmpty {
                    LDSectionLabel(family == .sampled ? "Averaged per window" : "Summed per window")
                    LDCard {
                        ForEach(types) { type in
                            ResolutionMenuRow(type: type, selection: Binding(
                                get: { prefs.seriesResolutions[type] ?? .raw },
                                set: { prefs.seriesResolutions[type] = $0 == .raw ? nil : $0 }
                            ))
                        }
                    }
                }
            }
            if configurable.isEmpty {
                LDNote("Switch on a type such as heart rate or steps to choose its resolution.", top: 14)
            } else {
                LDNote("Choose every record, 1 min, 5 min, 15 min or 1 hour. Only selected types show here.", size: 13)
            }
        }
        .navigationTitle("What to send")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ResolutionMenuRow: View {
    let type: HealthDataType
    @Binding var selection: SeriesResolution

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(SeriesResolution.allCases, id: \.self) { resolution in
                    resolution.label.tag(resolution)
                }
            } label: {
                Text(type.displayName)
            }
            .pickerStyle(.inline)
        } label: {
            LDRow(
                Text(type.displayName),
                value: selection.label,
                valueColor: selection == .raw ? LDTheme.muted : LDTheme.accentTextSoft
            )
        }
        .menuOrder(.fixed)
    }
}

private extension SeriesResolution {
    var label: Text {
        switch self {
        case .raw: return Text("Every record")
        case .oneMinute: return Text("1 min")
        case .fiveMinutes: return Text("5 min")
        case .fifteenMinutes: return Text("15 min")
        case .hourly: return Text("1 hour")
        }
    }
}
