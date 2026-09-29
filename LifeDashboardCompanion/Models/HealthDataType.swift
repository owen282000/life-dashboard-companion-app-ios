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
    case vo2Max = "VO2_MAX"
    case menstruation = "MENSTRUATION"
    case basalBodyTemperature = "BASAL_BODY_TEMPERATURE"
    case intermenstrualBleeding = "INTERMENSTRUAL_BLEEDING"
    case ovulationTest = "OVULATION_TEST"
    case cervicalMucus = "CERVICAL_MUCUS"
    case sexualActivity = "SEXUAL_ACTIVITY"

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
        case .vo2Max: return "VO2 Max"
        case .menstruation: return "Menstruation"
        case .basalBodyTemperature: return "Basal Body Temperature"
        case .intermenstrualBleeding: return "Intermenstrual Bleeding"
        case .ovulationTest: return "Ovulation Test"
        case .cervicalMucus: return "Cervical Mucus"
        case .sexualActivity: return "Sexual Activity"
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
        case .vo2Max: return "gauge.with.dots.needle.67percent"
        case .menstruation: return "calendar.circle.fill"
        case .basalBodyTemperature: return "thermometer.low"
        case .intermenstrualBleeding: return "drop.halffull"
        case .ovulationTest: return "testtube.2"
        case .cervicalMucus: return "humidity.fill"
        case .sexualActivity: return "person.2.fill"
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
        case .vo2Max:
            return [HKQuantityType(.vo2Max)]
        case .menstruation:
            return [HKCategoryType(.menstrualFlow)]
        case .basalBodyTemperature:
            return [HKQuantityType(.basalBodyTemperature)]
        case .intermenstrualBleeding:
            // Not .persistentIntermenstrualBleeding: that is Apple's analysis over a range of
            // cycles, not a logged event, and Android's record has no such meaning.
            return [HKCategoryType(.intermenstrualBleeding)]
        case .ovulationTest:
            return [HKCategoryType(.ovulationTestResult)]
        case .cervicalMucus:
            return [HKCategoryType(.cervicalMucusQuality)]
        case .sexualActivity:
            return [HKCategoryType(.sexualActivity)]
        }
    }

    /// The payload array a sync counts for this type, the same key the Android app uses.
    /// Menstruation also emits derived `menstruation_period` records, which are not counted.
    var countedPayloadKey: String {
        switch self {
        case .steps: return "steps"
        case .sleep: return "sleep"
        case .heartRate: return "heart_rate"
        case .distance: return "distance"
        case .activeCalories: return "active_calories"
        case .totalCalories: return "total_calories"
        case .weight: return "weight"
        case .height: return "height"
        case .bloodPressure: return "blood_pressure"
        case .bloodGlucose: return "blood_glucose"
        case .oxygenSaturation: return "oxygen_saturation"
        case .bodyTemperature: return "body_temperature"
        case .respiratoryRate: return "respiratory_rate"
        case .restingHeartRate: return "resting_heart_rate"
        case .exercise: return "exercise"
        case .hydration: return "hydration"
        case .nutrition: return "nutrition"
        case .mindfulness: return "mindfulness"
        case .bodyFat: return "body_fat"
        case .leanBodyMass: return "lean_body_mass"
        case .heartRateVariability: return "heart_rate_variability"
        case .vo2Max: return "vo2_max"
        case .menstruation: return "menstruation_flow"
        case .basalBodyTemperature: return "basal_body_temperature"
        case .intermenstrualBleeding: return "intermenstrual_bleeding"
        case .ovulationTest: return "ovulation_test"
        case .cervicalMucus: return "cervical_mucus"
        case .sexualActivity: return "sexual_activity"
        }
    }

    var hkReadTypes: Set<HKObjectType> {
        Set(hkSampleTypes.map { $0 as HKObjectType })
    }
}

// MARK: - Payload mapping

/// Maps HealthKit samples of the types added for Android parity to the fields the Android
/// app sends, so one backend serves both. Kept free of the health store so it is unit
/// testable; `uuid` and `source` are added by the reader. Enum values arrive as raw Ints
/// because a sample with an out-of-range value cannot be built in a test.
enum HealthRecordMapping {

    /// ml/(kg*min). Composed as mL / (kg * min): mL / kg * min would be a different unit,
    /// and asking a VO2 max sample for it raises at runtime.
    static let vo2MaxUnit = HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

    /// HealthKit records no sensation for cervical mucus. Android sends "unknown" when
    /// Health Connect has none, and the field is required, so every iOS record says so.
    static let cervicalMucusSensation = "unknown"

    static func ovulationTestResult(_ rawValue: Int) -> String {
        guard let value = HKCategoryValueOvulationTestResult(rawValue: rawValue) else { return "unknown" }
        switch value {
        case .luteinizingHormoneSurge: return "positive"
        case .estrogenSurge: return "high"
        case .negative: return "negative"
        case .indeterminate: return "inconclusive"
        @unknown default: return "unknown"
        }
    }

    static func cervicalMucusAppearance(_ rawValue: Int) -> String {
        guard let value = HKCategoryValueCervicalMucusQuality(rawValue: rawValue) else { return "unknown" }
        switch value {
        case .dry: return "dry"
        case .sticky: return "sticky"
        case .creamy: return "creamy"
        case .watery: return "watery"
        case .eggWhite: return "egg_white"
        @unknown default: return "unknown"
        }
    }

    /// Protection is optional metadata on a sexual activity sample; absent means not recorded.
    static func protectionUsed(_ metadata: [String: Any]?) -> String {
        guard let used = metadata?[HKMetadataKeySexualActivityProtectionUsed] as? Bool else { return "unknown" }
        return used ? "protected" : "unprotected"
    }

    static func vo2MaxFields(_ sample: HKQuantitySample) -> [String: Any] {
        [
            "vo2_ml_per_min_per_kg": sample.quantity.doubleValue(for: vo2MaxUnit),
            "time": sample.startDate.iso8601String
        ]
    }

    static func basalBodyTemperatureFields(_ sample: HKQuantitySample) -> [String: Any] {
        [
            "celsius": sample.quantity.doubleValue(for: .degreeCelsius()),
            "time": sample.startDate.iso8601String
        ]
    }

    static func intermenstrualBleedingFields(_ sample: HKCategorySample) -> [String: Any] {
        ["time": sample.startDate.iso8601String]
    }

    static func ovulationTestFields(_ sample: HKCategorySample) -> [String: Any] {
        [
            "result": ovulationTestResult(sample.value),
            "time": sample.startDate.iso8601String
        ]
    }

    static func cervicalMucusFields(_ sample: HKCategorySample) -> [String: Any] {
        [
            "appearance": cervicalMucusAppearance(sample.value),
            "sensation": cervicalMucusSensation,
            "time": sample.startDate.iso8601String
        ]
    }

    static func sexualActivityFields(_ sample: HKCategorySample) -> [String: Any] {
        [
            "protection_used": protectionUsed(sample.metadata),
            "time": sample.startDate.iso8601String
        ]
    }
}
