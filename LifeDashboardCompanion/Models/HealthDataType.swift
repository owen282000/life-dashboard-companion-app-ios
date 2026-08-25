import Foundation
import HealthKit

enum HealthDataType: String, CaseIterable, Codable, Identifiable {
    case steps = "STEPS"
    case sleep = "SLEEP"
    case heartRate = "HEART_RATE"
    case distance = "DISTANCE"
    case activeCalories = "ACTIVE_CALORIES"
    case totalCalories = "TOTAL_CALORIES"
    case weight = "WEIGHT"
    case height = "HEIGHT"
    case bloodPressure = "BLOOD_PRESSURE"
    case bloodGlucose = "BLOOD_GLUCOSE"
    case oxygenSaturation = "OXYGEN_SATURATION"
    case bodyTemperature = "BODY_TEMPERATURE"
    case respiratoryRate = "RESPIRATORY_RATE"
    case restingHeartRate = "RESTING_HEART_RATE"
    case exercise = "EXERCISE"
    case hydration = "HYDRATION"
    case nutrition = "NUTRITION"
    case mindfulness = "MINDFULNESS"
    case bodyFat = "BODY_FAT"
    case leanBodyMass = "LEAN_BODY_MASS"
    case heartRateVariability = "HEART_RATE_VARIABILITY"
    case menstruation = "MENSTRUATION"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .steps: return "Steps"
        case .sleep: return "Sleep"
        case .heartRate: return "Heart Rate"
        case .distance: return "Distance"
        case .activeCalories: return "Active Calories"
        case .totalCalories: return "Total Calories"
        case .weight: return "Weight"
        case .height: return "Height"
        case .bloodPressure: return "Blood Pressure"
        case .bloodGlucose: return "Blood Glucose"
        case .oxygenSaturation: return "Oxygen Saturation"
        case .bodyTemperature: return "Body Temperature"
        case .respiratoryRate: return "Respiratory Rate"
        case .restingHeartRate: return "Resting Heart Rate"
        case .exercise: return "Exercise Sessions"
        case .hydration: return "Hydration"
        case .nutrition: return "Nutrition"
        case .mindfulness: return "Mindfulness"
        case .bodyFat: return "Body Fat"
        case .leanBodyMass: return "Lean Body Mass"
        case .heartRateVariability: return "Heart Rate Variability"
        case .menstruation: return "Cycle Tracking"
        }
    }

    var icon: String {
        switch self {
        case .steps: return "figure.walk"
        case .sleep: return "bed.double.fill"
        case .heartRate: return "heart.fill"
        case .distance: return "map.fill"
        case .activeCalories: return "flame.fill"
        case .totalCalories: return "flame"
        case .weight: return "scalemass.fill"
        case .height: return "ruler.fill"
        case .bloodPressure: return "heart.text.square.fill"
        case .bloodGlucose: return "drop.fill"
        case .oxygenSaturation: return "lungs.fill"
        case .bodyTemperature: return "thermometer.medium"
        case .respiratoryRate: return "wind"
        case .restingHeartRate: return "heart.circle.fill"
        case .exercise: return "figure.run"
        case .hydration: return "drop.triangle.fill"
        case .nutrition: return "fork.knife"
        case .mindfulness: return "brain.head.profile"
        case .bodyFat: return "percent"
        case .leanBodyMass: return "figure.strengthtraining.traditional"
        case .heartRateVariability: return "waveform.path.ecg"
        case .menstruation: return "calendar.circle.fill"
        }
    }

    var hkSampleTypes: [HKSampleType] {
        switch self {
        case .steps:
            return [HKQuantityType(.stepCount)]
        case .sleep:
            return [HKCategoryType(.sleepAnalysis)]
        case .heartRate:
            return [HKQuantityType(.heartRate)]
        case .distance:
            return [HKQuantityType(.distanceWalkingRunning)]
        case .activeCalories:
            return [HKQuantityType(.activeEnergyBurned)]
        case .totalCalories:
            return [HKQuantityType(.basalEnergyBurned), HKQuantityType(.activeEnergyBurned)]
        case .weight:
            return [HKQuantityType(.bodyMass)]
        case .height:
            return [HKQuantityType(.height)]
        case .bloodPressure:
            return [HKQuantityType(.bloodPressureSystolic), HKQuantityType(.bloodPressureDiastolic)]
        case .bloodGlucose:
            return [HKQuantityType(.bloodGlucose)]
        case .oxygenSaturation:
            return [HKQuantityType(.oxygenSaturation)]
        case .bodyTemperature:
            return [HKQuantityType(.bodyTemperature)]
        case .respiratoryRate:
            return [HKQuantityType(.respiratoryRate)]
        case .restingHeartRate:
            return [HKQuantityType(.restingHeartRate)]
        case .exercise:
            return [HKWorkoutType.workoutType()]
        case .hydration:
            return [HKQuantityType(.dietaryWater)]
        case .nutrition:
            return [
                HKQuantityType(.dietaryEnergyConsumed),
                HKQuantityType(.dietaryProtein),
                HKQuantityType(.dietaryCarbohydrates),
                HKQuantityType(.dietaryFatTotal)
            ]
        case .mindfulness:
            return [HKCategoryType(.mindfulSession)]
        case .bodyFat:
            return [HKQuantityType(.bodyFatPercentage)]
        case .leanBodyMass:
            return [HKQuantityType(.leanBodyMass)]
        case .heartRateVariability:
            return [HKQuantityType(.heartRateVariabilitySDNN)]
        case .menstruation:
            return [HKCategoryType(.menstrualFlow)]
        }
    }

    var hkReadTypes: Set<HKObjectType> {
        Set(hkSampleTypes.map { $0 as HKObjectType })
    }
}
