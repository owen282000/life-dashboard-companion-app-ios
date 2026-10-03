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

    /// Apple's own name for the type in the Health app, in the phone's language.
    var displayName: LocalizedStringResource {
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
            return HealthDataType.distanceIdentifiers.map { HKQuantityType($0) }
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
            return HealthRecordMapping.mainNutrients.map { HKQuantityType($0.identifier) }
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

    /// Every distance HealthKit keeps, one type per kind of activity, so `distance` covers
    /// what Health Connect's distance does. None of them overlaps another.
    static var distanceIdentifiers: [HKQuantityTypeIdentifier] {
        var identifiers: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair, .distanceDownhillSnowSports
        ]
        if #available(iOS 18.0, *) {
            identifiers += [.distanceRowing, .distancePaddleSports, .distanceCrossCountrySkiing, .distanceSkatingSports]
        }
        return identifiers
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

    /// What the type asks Health access for: its sample types, and for nutrition also the
    /// nutrients that are only read from inside a food.
    var hkReadTypes: Set<HKObjectType> {
        var types = Set(hkSampleTypes.map { $0 as HKObjectType })
        if self == .nutrition {
            types.formUnion(HealthRecordMapping.foodOnlyNutrients.map { HKQuantityType($0.identifier) })
        }
        return types
    }

    /// The sample types whose deletions `deleted_records` names for this type: those whose own
    /// uuid can reach the payload. A diastolic value never does, because naming the reading it
    /// belongs to would delete one that still exists. A nutrient deleted from a food whose uuid
    /// comes from another nutrient is named under a uuid no record carries.
    var deletionSampleTypes: [HKSampleType] {
        switch self {
        case .bloodPressure:
            return [HKQuantityType(.bloodPressureSystolic)]
        case .steps, .sleep, .heartRate, .distance, .activeCalories, .totalCalories, .weight,
             .height, .bloodGlucose, .oxygenSaturation, .bodyTemperature, .respiratoryRate,
             .restingHeartRate, .exercise, .hydration, .nutrition, .mindfulness, .bodyFat, .leanBodyMass,
             .heartRateVariability, .vo2Max, .menstruation, .basalBodyTemperature,
             .intermenstrualBleeding, .ovulationTest, .cervicalMucus, .sexualActivity:
            return hkSampleTypes
        }
    }

    /// The payload key a deletion of this type is named under. Menstruation names flow days;
    /// `menstruation_period` is derived from them and has no uuid to name.
    var deletionPayloadKey: String {
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

    /// Beats per minute as the whole number Android's schema asks for. Rounded: HealthKit
    /// stores the Watch's heart rate as a fraction (71.9), which truncation made 71.
    static func bpm(_ sample: HKQuantitySample) -> Int {
        Int(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())).rounded())
    }

    static func heartRateFields(_ sample: HKQuantitySample) -> [String: Any] {
        [
            "bpm": bpm(sample),
            "time": sample.startDate.iso8601String
        ]
    }

    /// Some apps write fractional step counts; rounded like the daily totals round their sum.
    static func stepsFields(_ sample: HKQuantitySample) -> [String: Any] {
        [
            "count": Int(sample.quantity.doubleValue(for: .count()).rounded()),
            "start_time": sample.startDate.iso8601String,
            "end_time": sample.endDate.iso8601String
        ]
    }

    /// `duration_seconds` is the end minus the start, pauses included, as Android's exercise
    /// session gives it, so one key means one thing whichever phone sent it. HKWorkout.duration
    /// leaves the pauses out, which made a run with a coffee stop shorter on iOS.
    static func exerciseFields(type: String, start: Date, end: Date) -> [String: Any] {
        [
            "type": type,
            "start_time": start.iso8601String,
            "end_time": end.iso8601String,
            "duration_seconds": Int(end.timeIntervalSince(start))
        ]
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

    /// Adds the sample's HealthKit uuid and the name of the app that wrote it.
    static func record(_ fields: [String: Any], from sample: HKSample) -> [String: Any] {
        var record = fields
        record["uuid"] = sample.uuid.uuidString
        record["source"] = sample.sourceRevision.source.name
        return record
    }

    /// How far outside a read window the correlations are fetched whose samples it may hold.
    /// A sample and its correlation normally share their start; this covers an app that dates
    /// them apart, so such a sample is still known to belong to a correlation.
    static let correlationMargin: TimeInterval = 86_400

    // MARK: Blood pressure

    /// A second: the most a lone systolic and diastolic value from one app may lie apart to
    /// still count as one reading.
    static let loosePressureTolerance: TimeInterval = 1

    /// Blood pressure records for the samples that start in `[start, end)`.
    ///
    /// A reading is a blood pressure correlation holding a systolic and a diastolic sample;
    /// `correlations` may reach past the window (see `correlationMargin`), and only those that
    /// start inside it become records. The few apps that save the two values without a
    /// correlation are paired by source and time; `systolic` and `diastolic` may reach
    /// `loosePressureTolerance` past the window, and a pair is sent by the window its systolic
    /// value starts in. Android's schema requires `diastolic`, so a value without its other
    /// half is not sent. The uuid is the systolic sample's, as before,
    /// so a receiver keeps deduplicating against what earlier versions sent, and its deletion
    /// is what `deleted_records` names.
    static func bloodPressureRecords(
        correlations: [HKCorrelation],
        systolic: [HKQuantitySample],
        diastolic: [HKQuantitySample],
        start: Date,
        end: Date
    ) -> [[String: Any]] {
        let systolicType = HKQuantityType(.bloodPressureSystolic)
        let diastolicType = HKQuantityType(.bloodPressureDiastolic)
        var pairs: [(systolic: HKQuantitySample, diastolic: HKQuantitySample)] = []
        var inCorrelation = Set<UUID>()
        for correlation in correlations {
            inCorrelation.formUnion(correlation.objects.map(\.uuid))
            guard correlation.startDate >= start, correlation.startDate < end,
                  let high = firstByUuid(correlation.objects(for: systolicType)) as? HKQuantitySample,
                  let low = firstByUuid(correlation.objects(for: diastolicType)) as? HKQuantitySample else { continue }
            pairs.append((high, low))
        }

        var unpaired = diastolic.filter { !inCorrelation.contains($0.uuid) }
        let loneSystolic = systolic.filter { !inCorrelation.contains($0.uuid) && $0.startDate >= start && $0.startDate < end }
        for high in loneSystolic.sorted(by: { $0.startDate < $1.startDate }) {
            let candidates = unpaired.enumerated().filter { _, low in
                low.sourceRevision.source.bundleIdentifier == high.sourceRevision.source.bundleIdentifier
                    && abs(low.startDate.timeIntervalSince(high.startDate)) < loosePressureTolerance
            }
            guard let match = candidates.min(by: {
                abs($0.element.startDate.timeIntervalSince(high.startDate)) < abs($1.element.startDate.timeIntervalSince(high.startDate))
            }) else { continue }
            pairs.append((high, match.element))
            unpaired.remove(at: match.offset)
        }

        let mmHg = HKUnit.millimeterOfMercury()
        return pairs.sorted { $0.systolic.startDate < $1.systolic.startDate }.map { pair in
            record([
                "systolic": pair.systolic.quantity.doubleValue(for: mmHg),
                "diastolic": pair.diastolic.quantity.doubleValue(for: mmHg),
                "time": pair.systolic.startDate.iso8601String
            ], from: pair.systolic)
        }
    }

    /// The same sample of a set every time, should a correlation hold two of one type.
    private static func firstByUuid(_ samples: Set<HKSample>) -> HKSample? {
        samples.min { $0.uuid.uuidString < $1.uuid.uuidString }
    }

    // MARK: Nutrition

    struct Nutrient {
        let identifier: HKQuantityTypeIdentifier
        let field: String
        let unit: HKUnit
    }

    private static let milligram = HKUnit.gramUnit(with: .milli)
    private static let microgram = HKUnit.gramUnit(with: .micro)

    /// Read on their own as well as inside a food, in the order a record takes its uuid from.
    static let mainNutrients: [Nutrient] = [
        Nutrient(identifier: .dietaryEnergyConsumed, field: "calories", unit: .kilocalorie()),
        Nutrient(identifier: .dietaryProtein, field: "protein_grams", unit: .gram()),
        Nutrient(identifier: .dietaryCarbohydrates, field: "carbs_grams", unit: .gram()),
        Nutrient(identifier: .dietaryFatTotal, field: "fat_grams", unit: .gram())
    ]

    /// Every other HealthKit nutrient whose meaning and unit match a field of Android's
    /// nutrition record. Read only inside a food that has a main nutrient: on their own they
    /// would add a query per nutrient to every sync. Android's trans fat, unsaturated fat, energy from fat and folic
    /// acid have no HealthKit type; HealthKit's folate goes out as `folate_mcg`.
    static let foodOnlyNutrients: [Nutrient] = [
        Nutrient(identifier: .dietaryFiber, field: "dietary_fibre_g", unit: .gram()),
        Nutrient(identifier: .dietarySugar, field: "sugars_g", unit: .gram()),
        Nutrient(identifier: .dietaryFatSaturated, field: "saturated_fat_g", unit: .gram()),
        Nutrient(identifier: .dietaryFatMonounsaturated, field: "monounsaturated_fat_g", unit: .gram()),
        Nutrient(identifier: .dietaryFatPolyunsaturated, field: "polyunsaturated_fat_g", unit: .gram()),
        Nutrient(identifier: .dietaryCholesterol, field: "cholesterol_mg", unit: milligram),
        Nutrient(identifier: .dietarySodium, field: "sodium_mg", unit: milligram),
        Nutrient(identifier: .dietaryPotassium, field: "potassium_mg", unit: milligram),
        Nutrient(identifier: .dietaryCalcium, field: "calcium_mg", unit: milligram),
        Nutrient(identifier: .dietaryChloride, field: "chloride_mg", unit: milligram),
        Nutrient(identifier: .dietaryChromium, field: "chromium_mcg", unit: microgram),
        Nutrient(identifier: .dietaryCopper, field: "copper_mg", unit: milligram),
        Nutrient(identifier: .dietaryIodine, field: "iodine_mcg", unit: microgram),
        Nutrient(identifier: .dietaryIron, field: "iron_mg", unit: milligram),
        Nutrient(identifier: .dietaryMagnesium, field: "magnesium_mg", unit: milligram),
        Nutrient(identifier: .dietaryManganese, field: "manganese_mg", unit: milligram),
        Nutrient(identifier: .dietaryMolybdenum, field: "molybdenum_mcg", unit: microgram),
        Nutrient(identifier: .dietaryPhosphorus, field: "phosphorus_mg", unit: milligram),
        Nutrient(identifier: .dietarySelenium, field: "selenium_mcg", unit: microgram),
        Nutrient(identifier: .dietaryZinc, field: "zinc_mg", unit: milligram),
        Nutrient(identifier: .dietaryVitaminA, field: "vitamin_a_mcg", unit: microgram),
        Nutrient(identifier: .dietaryVitaminB6, field: "vitamin_b6_mg", unit: milligram),
        Nutrient(identifier: .dietaryVitaminB12, field: "vitamin_b12_mcg", unit: microgram),
        Nutrient(identifier: .dietaryVitaminC, field: "vitamin_c_mg", unit: milligram),
        Nutrient(identifier: .dietaryVitaminD, field: "vitamin_d_mcg", unit: microgram),
        Nutrient(identifier: .dietaryVitaminE, field: "vitamin_e_mg", unit: milligram),
        Nutrient(identifier: .dietaryVitaminK, field: "vitamin_k_mcg", unit: microgram),
        Nutrient(identifier: .dietaryThiamin, field: "thiamin_mg", unit: milligram),
        Nutrient(identifier: .dietaryRiboflavin, field: "riboflavin_mg", unit: milligram),
        Nutrient(identifier: .dietaryNiacin, field: "niacin_mg", unit: milligram),
        Nutrient(identifier: .dietaryPantothenicAcid, field: "pantothenic_acid_mg", unit: milligram),
        Nutrient(identifier: .dietaryBiotin, field: "biotin_mcg", unit: microgram),
        Nutrient(identifier: .dietaryFolate, field: "folate_mcg", unit: microgram),
        Nutrient(identifier: .dietaryCaffeine, field: "caffeine_mg", unit: milligram)
    ]

    private static let nutrientsByIdentifier: [String: Nutrient] = Dictionary(
        uniqueKeysWithValues: (mainNutrients + foodOnlyNutrients).map { ($0.identifier.rawValue, $0) }
    )

    /// Nutrition records for the samples that start in `[start, end)`.
    ///
    /// A food an app logged is a food correlation, and becomes one record with every nutrient
    /// in it and its name. `correlations` may reach past the window (see `correlationMargin`);
    /// only those that start inside it become records. Samples of the main nutrients that no
    /// food holds are grouped when they share app, time and name and no nutrient twice, which
    /// is how apps without correlations save one entry; any other lone sample is a record of
    /// its own. No value is dropped or counted twice.
    ///
    /// The uuid is the first of the food's energy, protein, carbohydrate and fat samples, which
    /// is what 1.4 sent for a food with energy, and those four are deletion targets. A food with
    /// none of them, such as a coffee logged with caffeine only, is not sent: nothing would wake
    /// a sync for it, read it at a set time, or name its deletion.
    static func nutritionRecords(
        correlations: [HKCorrelation],
        samples: [HKQuantitySample],
        start: Date,
        end: Date
    ) -> [[String: Any]] {
        var records: [(start: Date, record: [String: Any])] = []
        var inCorrelation = Set<UUID>()
        for food in correlations {
            inCorrelation.formUnion(food.objects.map(\.uuid))
            guard food.startDate >= start, food.startDate < end else { continue }
            let parts = food.objects.compactMap { $0 as? HKQuantitySample }
            guard let primary = primarySample(parts), let fields = nutrientFields(parts) else { continue }
            let name = foodName(food.metadata) ?? foodName(primary.metadata)
            records.append((food.startDate, record(entryFields(fields, start: food.startDate, end: food.endDate, name: name), from: primary)))
        }

        var groups: [String: [HKQuantitySample]] = [:]
        var order: [String] = []
        for sample in samples where !inCorrelation.contains(sample.uuid) {
            let key = [
                sample.sourceRevision.source.bundleIdentifier,
                "\(sample.startDate.timeIntervalSinceReferenceDate)",
                "\(sample.endDate.timeIntervalSinceReferenceDate)",
                foodName(sample.metadata) ?? ""
            ].joined(separator: "|")
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(sample)
        }
        for key in order {
            guard let group = groups[key], let first = group.first else { continue }
            let entries = Set(group.map(\.quantityType)).count == group.count ? [group] : group.map { [$0] }
            for entry in entries {
                guard let fields = nutrientFields(entry), let primary = primarySample(entry) else { continue }
                let fieldsWithTime = entryFields(fields, start: first.startDate, end: first.endDate, name: foodName(first.metadata))
                records.append((first.startDate, record(fieldsWithTime, from: primary)))
            }
        }

        return records.sorted {
            $0.start != $1.start ? $0.start < $1.start : ($0.record["uuid"] as? String ?? "") < ($1.record["uuid"] as? String ?? "")
        }.map(\.record)
    }

    /// The nutrient fields of some samples, summed per field; nil when none is a known nutrient.
    private static func nutrientFields(_ samples: [HKQuantitySample]) -> [String: Any]? {
        var sums: [String: Double] = [:]
        for sample in samples {
            guard let nutrient = nutrientsByIdentifier[sample.quantityType.identifier] else { continue }
            let value = sample.quantity.doubleValue(for: nutrient.unit)
            guard value.isFinite else { continue }
            sums[nutrient.field, default: 0] += value
        }
        return sums.isEmpty ? nil : sums
    }

    private static func entryFields(_ nutrients: [String: Any], start: Date, end: Date, name: String?) -> [String: Any] {
        var fields = nutrients
        fields["start_time"] = start.iso8601String
        fields["end_time"] = end.iso8601String
        if let name { fields["name"] = name }
        return fields
    }

    /// The sample a food's uuid comes from: the first main nutrient it has, the lowest uuid if
    /// it has two, so the same food always gets the same uuid.
    private static func primarySample(_ samples: [HKQuantitySample]) -> HKQuantitySample? {
        for nutrient in mainNutrients {
            let matching = samples.filter { $0.quantityType.identifier == nutrient.identifier.rawValue }
            if let first = matching.min(by: { $0.uuid.uuidString < $1.uuid.uuidString }) { return first }
        }
        return nil
    }

    private static func foodName(_ metadata: [String: Any]?) -> String? {
        guard let name = metadata?[HKMetadataKeyFoodType] as? String, !name.isEmpty else { return nil }
        return name
    }
}

// MARK: - Serialization

/// The payload as JSON, with every number at a precision that fits its field. HealthKit's unit
/// conversions leave float noise, and JSONSerialization writes a double with 17 significant
/// digits, so even 78.2 itself went out as 78.200000000000003. Each fraction goes out as a
/// decimal number instead, rounded to its field's decimals.
enum PayloadJSON {

    /// Decimals per payload field. Android's MQTT precision where it keeps a value as it was
    /// entered in any unit Health offers; more where it does not (0.1 lb, 0.1 °F, 1 mL, 1 mm).
    static let decimals: [String: Int] = [
        "meters": 3,
        "distance_meters": 2,
        "kilograms": 2,
        "calories": 2,
        "active_calories": 2,
        "total_calories": 2,
        "celsius": 2,
        "liters": 3,
        "mmol_per_liter": 2,
        "percentage": 1,
        "systolic": 1,
        "diastolic": 1,
        "rate": 1,
        "heart_rate_variability_millis": 1,
        "vo2_ml_per_min_per_kg": 1
    ]

    /// Nutrient amounts in grams, milligrams and micrograms.
    static let nutrientDecimals = 2
    private static let nutrientSuffixes = ["_grams", "_g", "_mg", "_mcg"]

    /// Nil for a field without fixed decimals, which keeps its shortest exact form.
    static func decimals(for field: String) -> Int? {
        if let fixed = decimals[field] { return fixed }
        return nutrientSuffixes.contains { field.hasSuffix($0) } ? nutrientDecimals : nil
    }

    /// The bytes every payload is sent and queued with.
    static func data(_ payload: [String: Any], options: JSONSerialization.WritingOptions = [.sortedKeys]) -> Data? {
        let value = rounded(payload) ?? [:]
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: options)
    }

    /// `value` with every fraction in it, at any depth, as a decimal number. Integers, booleans
    /// and text stay as they are. A fraction JSON cannot hold, NaN or infinity, is left out
    /// with its key, rather than costing the payload every other record.
    static func rounded(_ value: Any, field: String? = nil) -> Any? {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = rounded(entry.value, field: entry.key)
            }
        case let array as [Any]:
            return array.compactMap { rounded($0, field: field) }
        default:
            guard let fraction = fraction(value) else { return value }
            return decimal(fraction, decimals: field.flatMap(decimals(for:))).map(NSDecimalNumber.init(decimal:))
        }
    }

    /// The value of a Double, or of an NSNumber that holds one; nil for anything else.
    private static func fraction(_ value: Any) -> Double? {
        if let double = value as? Double, type(of: value) == Double.self { return double }
        guard let number = value as? NSNumber, !(number is NSDecimalNumber),
              CFGetTypeID(number) != CFBooleanGetTypeID(), CFNumberIsFloatType(number) else { return nil }
        return number.doubleValue
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// `value` rounded half up from its shortest form (Swift's description, the shortest text
    /// that reads back as the same double) to `decimals`, the way Java's String.format and so
    /// the Android app's MQTT states round. Nil for NaN and infinity.
    static func decimal(_ value: Double, decimals: Int?) -> Decimal? {
        guard value.isFinite else { return nil }
        // Past Decimal's range, below 1e-128, the value is 0 at any precision a field has.
        guard var exact = Decimal(string: "\(value)", locale: posix) ?? (value.magnitude < 1 ? 0 : nil),
              !exact.isNaN else { return nil }
        guard let decimals else { return exact }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &exact, decimals, .plain)
        return rounded
    }
}
