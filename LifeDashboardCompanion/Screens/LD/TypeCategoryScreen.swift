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
}

struct TypeCategoryScreen: View {
    let category: LDTypeCategory

    var body: some View {
        LDScreen {
            LDHeading(category.title)
        }
        .navigationTitle("What to send")
        .navigationBarTitleDisplayMode(.inline)
    }
}
