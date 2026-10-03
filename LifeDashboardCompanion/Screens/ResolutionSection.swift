import SwiftUI

/// Data resolution per type, the Android app's ResolutionRow: every record, or one averaged
/// (or summed) value per window. Only the types where a window means something appear, and
/// only the ones switched on, grouped by what a window does to them, so it is clear that heart
/// rate is averaged while steps are added up.
struct ResolutionRow: View {
    @ObservedObject var prefs: PreferencesManager
    @Binding var isExpanded: Bool

    var body: some View {
        let configurable = ResolutionFamily.configurableTypes.filter { prefs.healthEnabledDataTypes.contains($0) }
        let bucketed = ResolutionRow.bucketedCount(prefs.seriesResolutions, enabled: prefs.healthEnabledDataTypes)
        ExpandableRow(
            title: "Data Resolution",
            systemImage: "chart.bar.xaxis",
            subtitle: bucketed == 0 ? Text("Every record") : Text("\(bucketed) bucketed"),
            subtitleColor: bucketed == 0 ? .secondary : Brand.ink,
            isExpanded: $isExpanded
        ) {
            Text("Dense series like heart rate can be sent as averages per time window instead of every single record. Smaller payloads, less detail.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(ResolutionFamily.allCases, id: \.self) { family in
                let types = configurable.filter { ResolutionFamily.of($0) == family }
                if !types.isEmpty {
                    Divider()
                    RowSubheading(family == .sampled ? "Averaged per window" : "Summed per window")
                    ForEach(types) { type in
                        TypeResolutionPicker(type: type, selection: Binding(
                            get: { prefs.seriesResolutions[type] ?? .raw },
                            set: { prefs.seriesResolutions[type] = $0 == .raw ? nil : $0 }
                        ))
                    }
                }
            }
        }
    }

    /// The enabled types that are not at every record, the number in the subtitle.
    static func bucketedCount(_ resolutions: [HealthDataType: SeriesResolution], enabled: Set<HealthDataType>) -> Int {
        ResolutionFamily.configurableTypes.filter { enabled.contains($0) && (resolutions[$0] ?? .raw) != .raw }.count
    }
}

/// One type's choice as a row of chips, with Android's weights: Every record 1.7, each
/// window 1.
private struct TypeResolutionPicker: View {
    let type: HealthDataType
    @Binding var selection: SeriesResolution
    @ScaledMetric(relativeTo: .caption) private var chipHeight: CGFloat = 34

    private static let spacing: CGFloat = 6
    private static let rawWeight: CGFloat = 1.7

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(type.displayName)
                .font(.subheadline)
            GeometryReader { geometry in
                let cases = SeriesResolution.allCases
                let unit = max(0, geometry.size.width - Self.spacing * CGFloat(cases.count - 1))
                    / (Self.rawWeight + CGFloat(cases.count - 1))
                HStack(spacing: Self.spacing) {
                    ForEach(cases, id: \.self) { resolution in
                        chip(resolution)
                            .frame(width: unit * (resolution == .raw ? Self.rawWeight : 1))
                    }
                }
            }
            .frame(height: max(34, chipHeight))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(type.displayName))
    }

    private func chip(_ resolution: SeriesResolution) -> some View {
        let isSelected = resolution == selection
        return Button {
            selection = resolution
        } label: {
            resolution.label
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(isSelected ? Brand.ink : .secondary)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? Brand.green.opacity(0.18) : Color(.tertiarySystemFill))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
