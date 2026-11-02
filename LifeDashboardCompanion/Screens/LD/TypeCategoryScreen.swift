import SwiftUI

/// The groups of What to send. Every HealthDataType sits in exactly one.
enum LDTypeCategory: String, CaseIterable, Hashable {
    case activity, body, heartAndVitals, sleepAndMind, foodAndDrink, cycleTracking

    var title: LocalizedStringKey {
        switch self {
        case .activity: return "Activity"
        case .body: return "Body"
        case .heartAndVitals: return "Heart and vitals"
        case .sleepAndMind: return "Sleep and mind"
        case .foodAndDrink: return "Food and drink"
        case .cycleTracking: return "Cycle tracking"
        }
    }

    var types: [HealthDataType] {
        switch self {
        case .activity:
            return [.steps, .distance, .activeCalories, .totalCalories, .exercise]
        case .body:
            return [.weight, .height, .bodyFat, .leanBodyMass]
        case .heartAndVitals:
            return [
                .heartRate, .restingHeartRate, .heartRateVariability, .bloodPressure, .oxygenSaturation,
                .respiratoryRate, .bodyTemperature, .basalBodyTemperature, .bloodGlucose, .vo2Max
            ]
        case .sleepAndMind:
            return [.sleep, .mindfulness]
        case .foodAndDrink:
            return [.hydration, .nutrition]
        case .cycleTracking:
            return [.menstruation, .intermenstrualBleeding, .ovulationTest, .cervicalMucus, .sexualActivity]
        }
    }

    /// What All types switches on: cycle tracking stays off until someone switches it on.
    static var typesOutsideCycle: Set<HealthDataType> {
        Set(HealthDataType.allCases).subtracting(cycleTracking.types)
    }

    #if DEBUG
    /// A type added to HealthDataType without a category could not be switched on anywhere.
    static func assertCoversEveryType() {
        let listed = allCases.flatMap(\.types)
        assert(
            listed.count == Set(listed).count && Set(listed) == Set(HealthDataType.allCases),
            "Every HealthDataType must sit in exactly one LDTypeCategory"
        )
    }
    #endif
}

/// Switching types on and off, for every page of What to send.
@MainActor
enum WhatToSendSelection {
    /// One type's switch: switching on asks iOS for that type alone.
    static func binding(for type: HealthDataType, prefs: PreferencesManager) -> Binding<Bool> {
        Binding(
            get: { prefs.healthEnabledDataTypes.contains(type) },
            set: { enabled in
                if enabled {
                    prefs.healthEnabledDataTypes.insert(type)
                    Task {
                        try? await HealthKitManager.shared.requestAuthorization(for: [type])
                    }
                } else {
                    prefs.healthEnabledDataTypes.remove(type)
                }
                changed()
            }
        )
    }

    /// A preset: iOS is asked once, for the types it brings in.
    static func apply(_ types: Set<HealthDataType>, prefs: PreferencesManager) async {
        let added = types.subtracting(prefs.healthEnabledDataTypes)
        prefs.healthEnabledDataTypes = types
        changed()
        try? await HealthKitManager.shared.requestAuthorization(for: added)
    }

    /// Reconfigure observer queries for changed data types, and the background tasks, which the
    /// first type (or the last one gone) starts or stops.
    private static func changed() {
        BackgroundSyncManager.shared.reconfigureObservers()
        BackgroundSyncManager.shared.replan()
    }
}

struct TypeCategoryScreen: View {
    let category: LDTypeCategory

    @ObservedObject private var prefs = PreferencesManager.shared

    var body: some View {
        let types = category.types
        LDScreen {
            LDHeading(category.title)
            if category == .cycleTracking {
                LDNote("This stays off until you switch it on. It only goes to your own destinations.", top: 4)
            } else {
                LDNote(Text("\(types.filter(prefs.healthEnabledDataTypes.contains).count) of \(types.count) selected"), top: 4)
            }
            LDGap(12)
            LDCard {
                ForEach(types) { type in
                    LDToggleRow(Text(type.displayName), isOn: WhatToSendSelection.binding(for: type, prefs: prefs))
                }
            }
            .ldStaggerRise(0)
        }
        .navigationTitle("What to send")
        .navigationBarTitleDisplayMode(.inline)
    }
}
