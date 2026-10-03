import XCTest
import HealthKit
@testable import LifeDashboardCompanion

final class HealthRecordMappingTests: XCTestCase {

    /// The data arrays of the Android app's payload (docs/webhook.md), minus the derived
    /// menstruation_period. Every key iOS counts must be one of these.
    private let androidPayloadKeys: Set<String> = [
        "steps", "sleep", "heart_rate", "distance", "active_calories", "total_calories",
        "weight", "height", "blood_pressure", "blood_glucose", "oxygen_saturation",
        "body_temperature", "respiratory_rate", "resting_heart_rate", "exercise", "hydration",
        "nutrition", "mindfulness", "body_fat", "lean_body_mass", "bone_mass", "body_water_mass",
        "heart_rate_variability", "menstruation_flow", "basal_metabolic_rate", "vo2_max",
        "skin_temperature", "basal_body_temperature", "intermenstrual_bleeding", "ovulation_test",
        "cervical_mucus", "sexual_activity"
    ]

    private let start = Date(timeIntervalSince1970: 1_767_254_400)  // 2026-01-01T08:00:00Z

    private func quantitySample(_ identifier: HKQuantityTypeIdentifier, _ quantity: HKQuantity) -> HKQuantitySample {
        HKQuantitySample(type: HKQuantityType(identifier), quantity: quantity, start: start, end: start)
    }

    private func categorySample(
        _ identifier: HKCategoryTypeIdentifier,
        value: Int,
        metadata: [String: Any]? = nil
    ) -> HKCategorySample {
        HKCategorySample(type: HKCategoryType(identifier), value: value, start: start, end: start, metadata: metadata)
    }

    // MARK: - Type model

    func testNewTypesUseAndroidEnumNames() {
        XCTAssertEqual(HealthDataType.vo2Max.rawValue, "VO2_MAX")
        XCTAssertEqual(HealthDataType.basalBodyTemperature.rawValue, "BASAL_BODY_TEMPERATURE")
        XCTAssertEqual(HealthDataType.intermenstrualBleeding.rawValue, "INTERMENSTRUAL_BLEEDING")
        XCTAssertEqual(HealthDataType.ovulationTest.rawValue, "OVULATION_TEST")
        XCTAssertEqual(HealthDataType.cervicalMucus.rawValue, "CERVICAL_MUCUS")
        XCTAssertEqual(HealthDataType.sexualActivity.rawValue, "SEXUAL_ACTIVITY")
        XCTAssertEqual(HealthDataType.allCases.count, 28)
    }

    func testCountedPayloadKeysAreUniqueAndKnownToAndroid() {
        let keys = HealthDataType.allCases.map(\.countedPayloadKey)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(Set(keys).isSubset(of: androidPayloadKeys), "unknown keys: \(Set(keys).subtracting(androidPayloadKeys))")
    }

    func testNewTypesReadExactlyOneSampleType() {
        let expected: [HealthDataType: HKSampleType] = [
            .vo2Max: HKQuantityType(.vo2Max),
            .basalBodyTemperature: HKQuantityType(.basalBodyTemperature),
            .intermenstrualBleeding: HKCategoryType(.intermenstrualBleeding),
            .ovulationTest: HKCategoryType(.ovulationTestResult),
            .cervicalMucus: HKCategoryType(.cervicalMucusQuality),
            .sexualActivity: HKCategoryType(.sexualActivity)
        ]
        for (type, sampleType) in expected {
            XCTAssertEqual(type.hkSampleTypes, [sampleType], "\(type)")
        }
    }

    func testDistanceReadsEveryActivity() {
        let identifiers = HealthDataType.distance.hkSampleTypes.map(\.identifier)
        for identifier: HKQuantityTypeIdentifier in [.distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair, .distanceDownhillSnowSports] {
            XCTAssertTrue(identifiers.contains(identifier.rawValue), identifier.rawValue)
        }
        if #available(iOS 18.0, *) {
            XCTAssertEqual(identifiers.count, 9)
        }
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(HealthDataType.distance.deletionSampleTypes, HealthDataType.distance.hkSampleTypes)
        for sampleType in HealthDataType.distance.hkSampleTypes {
            XCTAssertTrue((sampleType as? HKQuantityType)?.is(compatibleWith: .meter()) == true, sampleType.identifier)
        }
    }

    // MARK: - Value mappings

    func testOvulationTestResultMapsToAndroidValues() {
        XCTAssertEqual(HealthRecordMapping.ovulationTestResult(1), "negative")
        XCTAssertEqual(HealthRecordMapping.ovulationTestResult(2), "positive")
        XCTAssertEqual(HealthRecordMapping.ovulationTestResult(3), "inconclusive")
        XCTAssertEqual(HealthRecordMapping.ovulationTestResult(4), "high")
        for raw in [0, 5, 99, -1] {
            XCTAssertEqual(HealthRecordMapping.ovulationTestResult(raw), "unknown", "\(raw)")
        }
    }

    func testCervicalMucusAppearanceMapsToAndroidValues() {
        let expected = [1: "dry", 2: "sticky", 3: "creamy", 4: "watery", 5: "egg_white", 0: "unknown", 6: "unknown"]
        for (raw, appearance) in expected {
            XCTAssertEqual(HealthRecordMapping.cervicalMucusAppearance(raw), appearance, "\(raw)")
        }
    }

    func testProtectionUsedReadsTheOptionalMetadata() {
        let key = HKMetadataKeySexualActivityProtectionUsed
        XCTAssertEqual(HealthRecordMapping.protectionUsed([key: true]), "protected")
        XCTAssertEqual(HealthRecordMapping.protectionUsed([key: NSNumber(value: false)]), "unprotected")
        XCTAssertEqual(HealthRecordMapping.protectionUsed(nil), "unknown")
        XCTAssertEqual(HealthRecordMapping.protectionUsed([:]), "unknown")
        XCTAssertEqual(HealthRecordMapping.protectionUsed([key: "yes"]), "unknown")
    }

    // MARK: - Records

    func testVo2MaxRecordKeepsTheValueInAndroidsUnit() {
        let quantity = HKQuantity(unit: HKUnit(from: "ml/kg*min"), doubleValue: 42.5)
        let fields = HealthRecordMapping.vo2MaxFields(quantitySample(.vo2Max, quantity))
        XCTAssertEqual(Set(fields.keys), ["vo2_ml_per_min_per_kg", "time"])
        XCTAssertEqual(fields["vo2_ml_per_min_per_kg"] as? Double ?? 0, 42.5, accuracy: 0.0001)
        XCTAssertEqual(fields["time"] as? String, "2026-01-01T08:00:00Z")
        XCTAssertTrue(HKQuantityType(.vo2Max).is(compatibleWith: HealthRecordMapping.vo2MaxUnit))
    }

    func testBasalBodyTemperatureIsSentInCelsius() {
        let quantity = HKQuantity(unit: .degreeFahrenheit(), doubleValue: 97.7)
        let fields = HealthRecordMapping.basalBodyTemperatureFields(quantitySample(.basalBodyTemperature, quantity))
        XCTAssertEqual(Set(fields.keys), ["celsius", "time"])
        XCTAssertEqual(fields["celsius"] as? Double ?? 0, 36.5, accuracy: 0.0001)
    }

    func testIntermenstrualBleedingCarriesOnlyItsTime() {
        let sample = categorySample(.intermenstrualBleeding, value: HKCategoryValue.notApplicable.rawValue)
        let fields = HealthRecordMapping.intermenstrualBleedingFields(sample)
        XCTAssertEqual(Set(fields.keys), ["time"])
    }

    func testOvulationTestRecord() {
        let sample = categorySample(.ovulationTestResult, value: HKCategoryValueOvulationTestResult.estrogenSurge.rawValue)
        let fields = HealthRecordMapping.ovulationTestFields(sample)
        XCTAssertEqual(Set(fields.keys), ["result", "time"])
        XCTAssertEqual(fields["result"] as? String, "high")
    }

    func testCervicalMucusRecordAlwaysHasAnUnknownSensation() {
        let sample = categorySample(.cervicalMucusQuality, value: HKCategoryValueCervicalMucusQuality.eggWhite.rawValue)
        let fields = HealthRecordMapping.cervicalMucusFields(sample)
        XCTAssertEqual(Set(fields.keys), ["appearance", "sensation", "time"])
        XCTAssertEqual(fields["appearance"] as? String, "egg_white")
        XCTAssertEqual(fields["sensation"] as? String, "unknown")
    }

    func testSexualActivityRecord() {
        let sample = categorySample(
            .sexualActivity,
            value: HKCategoryValue.notApplicable.rawValue,
            metadata: [HKMetadataKeySexualActivityProtectionUsed: true]
        )
        let fields = HealthRecordMapping.sexualActivityFields(sample)
        XCTAssertEqual(Set(fields.keys), ["protection_used", "time"])
        XCTAssertEqual(fields["protection_used"] as? String, "protected")
        XCTAssertEqual(
            HealthRecordMapping.sexualActivityFields(categorySample(.sexualActivity, value: 0))["protection_used"] as? String,
            "unknown"
        )
    }

    func testHeartRateIsRoundedNotTruncated() {
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        for (value, expected) in [(71.9, 72), (71.4, 71), (59.5, 60), (60, 60)] {
            let sample = quantitySample(.heartRate, HKQuantity(unit: perMinute, doubleValue: value))
            XCTAssertEqual(HealthRecordMapping.heartRateFields(sample)["bpm"] as? Int, expected, "\(value)")
        }
        let resting = quantitySample(.restingHeartRate, HKQuantity(unit: perMinute, doubleValue: 52.7))
        XCTAssertEqual(HealthRecordMapping.bpm(resting), 53)
    }

    func testStepCountIsRounded() {
        let sample = HKQuantitySample(
            type: HKQuantityType(.stepCount),
            quantity: HKQuantity(unit: .count(), doubleValue: 99.8),
            start: start, end: start.addingTimeInterval(60)
        )
        let fields = HealthRecordMapping.stepsFields(sample)
        XCTAssertEqual(fields["count"] as? Int, 100)
        XCTAssertEqual(Set(fields.keys), ["count", "start_time", "end_time"])
    }

    // MARK: - Blood pressure

    private func pressure(_ identifier: HKQuantityTypeIdentifier, _ mmHg: Double, at offset: TimeInterval = 0) -> HKQuantitySample {
        let time = start.addingTimeInterval(offset)
        return HKQuantitySample(
            type: HKQuantityType(identifier),
            quantity: HKQuantity(unit: .millimeterOfMercury(), doubleValue: mmHg),
            start: time, end: time
        )
    }

    private func reading(_ systolic: HKQuantitySample, _ diastolic: HKQuantitySample) -> HKCorrelation {
        HKCorrelation(
            type: HKCorrelationType(.bloodPressure),
            start: systolic.startDate, end: systolic.endDate,
            objects: [systolic, diastolic]
        )
    }

    private func pressureRecords(
        _ correlations: [HKCorrelation],
        systolic: [HKQuantitySample],
        diastolic: [HKQuantitySample],
        from windowStart: Date? = nil
    ) -> [[String: Any]] {
        HealthRecordMapping.bloodPressureRecords(
            correlations: correlations,
            systolic: systolic,
            diastolic: diastolic,
            start: windowStart ?? start,
            end: start.addingTimeInterval(3600)
        )
    }

    func testBloodPressureReadingsComeFromTheirCorrelation() {
        // Two readings a moment apart: time matching could hand both the same diastolic.
        let first = (pressure(.bloodPressureSystolic, 121), pressure(.bloodPressureDiastolic, 79))
        let second = (pressure(.bloodPressureSystolic, 134, at: 0.4), pressure(.bloodPressureDiastolic, 88, at: 0.4))
        let records = pressureRecords(
            [reading(second.0, second.1), reading(first.0, first.1)],
            systolic: [first.0, second.0],
            diastolic: [second.1, first.1]
        )
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["systolic"] as? Double, 121)
        XCTAssertEqual(records[0]["diastolic"] as? Double, 79)
        XCTAssertEqual(records[1]["systolic"] as? Double, 134)
        XCTAssertEqual(records[1]["diastolic"] as? Double, 88)
        // The systolic sample's uuid, as 1.4 sent it and as deleted_records names it.
        XCTAssertEqual(records[0]["uuid"] as? String, first.0.uuid.uuidString)
        XCTAssertEqual(records[0]["time"] as? String, "2026-01-01T08:00:00Z")
        XCTAssertNotNil(records[0]["source"] as? String)
    }

    func testBloodPressureRecordsAlwaysCarryWhatAndroidRequires() {
        let lone = pressure(.bloodPressureSystolic, 118)
        let pair = (pressure(.bloodPressureSystolic, 125, at: 600), pressure(.bloodPressureDiastolic, 81, at: 600))
        let records = pressureRecords([reading(pair.0, pair.1)], systolic: [lone, pair.0], diastolic: [pair.1])
        XCTAssertEqual(records.count, 1, "a systolic value without a diastolic one is not sent")
        for record in records {
            XCTAssertTrue(["systolic", "diastolic", "time"].allSatisfy { record[$0] != nil })
        }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(records))
    }

    func testLoneBloodPressureValuesArePairedByTime() {
        let high = pressure(.bloodPressureSystolic, 140)
        let low = pressure(.bloodPressureDiastolic, 90, at: 0.3)
        let lateHigh = pressure(.bloodPressureSystolic, 150, at: 60)
        let lateLow = pressure(.bloodPressureDiastolic, 95, at: 62)
        let records = pressureRecords([], systolic: [lateHigh, high], diastolic: [lateLow, low])
        XCTAssertEqual(records.count, 1, "two seconds apart is two measurements")
        XCTAssertEqual(records[0]["systolic"] as? Double, 140)
        XCTAssertEqual(records[0]["diastolic"] as? Double, 90)
        XCTAssertEqual(records[0]["uuid"] as? String, high.uuid.uuidString)
    }

    func testLoneBloodPressureValuesPairWithTheNearestAndOnlyOnce() {
        let highs = [pressure(.bloodPressureSystolic, 120), pressure(.bloodPressureSystolic, 130, at: 0.6)]
        let lows = [pressure(.bloodPressureDiastolic, 85, at: 0.5), pressure(.bloodPressureDiastolic, 80, at: 0.1)]
        let records = pressureRecords([], systolic: highs, diastolic: lows)
        XCTAssertEqual(records.map { $0["diastolic"] as? Double }, [80, 85])
    }

    func testALonePairAcrossASliceBoundIsSentByTheWindowOfItsSystolicValue() {
        let high = pressure(.bloodPressureSystolic, 128, at: -0.5)
        let low = pressure(.bloodPressureDiastolic, 84, at: 0.2)
        let before = HealthRecordMapping.bloodPressureRecords(
            correlations: [], systolic: [high], diastolic: [low],
            start: start.addingTimeInterval(-60), end: start
        )
        let after = HealthRecordMapping.bloodPressureRecords(
            correlations: [], systolic: [high], diastolic: [low],
            start: start, end: start.addingTimeInterval(60)
        )
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before.first?["diastolic"] as? Double, 84)
        XCTAssertTrue(after.isEmpty)
    }

    func testAReadingIsSentInTheWindowItsCorrelationStartsIn() {
        let high = pressure(.bloodPressureSystolic, 120, at: 5)
        let low = pressure(.bloodPressureDiastolic, 80, at: 5)
        // The app dated the correlation a minute before its values.
        let correlation = HKCorrelation(
            type: HKCorrelationType(.bloodPressure),
            start: start.addingTimeInterval(-55), end: start.addingTimeInterval(5),
            objects: [high, low]
        )
        XCTAssertTrue(pressureRecords([correlation], systolic: [high], diastolic: [low]).isEmpty)
        XCTAssertEqual(pressureRecords([correlation], systolic: [], diastolic: [], from: start.addingTimeInterval(-60)).count, 1)
    }

    // MARK: - Nutrition

    /// The nutrition fields of Android's docs/webhook-schema.json.
    private let androidNutritionFields: Set<String> = [
        "calories", "protein_grams", "carbs_grams", "fat_grams", "name", "meal_type",
        "energy_from_fat_kcal", "dietary_fibre_g", "sugars_g", "saturated_fat_g",
        "monounsaturated_fat_g", "polyunsaturated_fat_g", "unsaturated_fat_g", "trans_fat_g",
        "cholesterol_mg", "sodium_mg", "potassium_mg", "calcium_mg", "chloride_mg", "chromium_mcg",
        "copper_mg", "iodine_mcg", "iron_mg", "magnesium_mg", "manganese_mg", "molybdenum_mcg",
        "phosphorus_mg", "selenium_mcg", "zinc_mg", "vitamin_a_mcg", "vitamin_b6_mg",
        "vitamin_b12_mcg", "vitamin_c_mg", "vitamin_d_mcg", "vitamin_e_mg", "vitamin_k_mcg",
        "thiamin_mg", "riboflavin_mg", "niacin_mg", "pantothenic_acid_mg", "biotin_mcg",
        "folate_mcg", "folic_acid_mcg", "caffeine_mg", "start_time", "end_time", "source", "uuid"
    ]

    private func nutrient(
        _ identifier: HKQuantityTypeIdentifier,
        _ value: Double,
        _ unit: HKUnit = .gram(),
        at offset: TimeInterval = 0,
        name: String? = nil
    ) -> HKQuantitySample {
        let time = start.addingTimeInterval(offset)
        return HKQuantitySample(
            type: HKQuantityType(identifier),
            quantity: HKQuantity(unit: unit, doubleValue: value),
            start: time, end: time,
            metadata: name.map { [HKMetadataKeyFoodType: $0] }
        )
    }

    private func food(_ samples: [HKQuantitySample], name: String? = nil, at offset: TimeInterval = 0) -> HKCorrelation {
        let time = start.addingTimeInterval(offset)
        return HKCorrelation(
            type: HKCorrelationType(.food),
            start: time, end: time,
            objects: Set(samples),
            metadata: name.map { [HKMetadataKeyFoodType: $0] }
        )
    }

    private func nutritionRecords(
        _ foods: [HKCorrelation],
        loose: [HKQuantitySample] = [],
        from windowStart: Date? = nil
    ) -> [[String: Any]] {
        let inFoods = foods.flatMap { $0.objects.compactMap { $0 as? HKQuantitySample } }
        return HealthRecordMapping.nutritionRecords(
            correlations: foods,
            samples: (inFoods + loose).filter { HealthRecordMapping.mainNutrients.map(\.identifier.rawValue).contains($0.quantityType.identifier) },
            start: windowStart ?? start,
            end: start.addingTimeInterval(3600)
        )
    }

    func testEveryNutrientFieldIsOneOfAndroids() {
        let fields = (HealthRecordMapping.mainNutrients + HealthRecordMapping.foodOnlyNutrients).map(\.field)
        XCTAssertEqual(Set(fields).count, fields.count)
        XCTAssertEqual(HealthRecordMapping.foodOnlyNutrients.count, 34, "docs/webhook.md and docs/features.md give the number")
        XCTAssertTrue(Set(fields).isSubset(of: androidNutritionFields), "unknown: \(Set(fields).subtracting(androidNutritionFields))")
        for nutrient in HealthRecordMapping.mainNutrients + HealthRecordMapping.foodOnlyNutrients {
            XCTAssertTrue(HKQuantityType(nutrient.identifier).is(compatibleWith: nutrient.unit), nutrient.field)
        }
    }

    func testNutritionAsksForEveryNutrientButReadsTheMainOnesOnTheirOwn() {
        let main = HealthRecordMapping.mainNutrients.map { HKQuantityType($0.identifier) as HKSampleType }
        XCTAssertEqual(HealthDataType.nutrition.hkSampleTypes, main)
        XCTAssertEqual(HealthDataType.nutrition.deletionSampleTypes, main)
        XCTAssertEqual(HealthDataType.nutrition.hkReadTypes.count, 4 + HealthRecordMapping.foodOnlyNutrients.count)
        XCTAssertTrue(HealthDataType.nutrition.hkReadTypes.contains(HKQuantityType(.dietaryCaffeine)))
    }

    func testTwoFoodsAtTheSameMomentKeepTheirOwnValues() {
        let toastEnergy = nutrient(.dietaryEnergyConsumed, 180, .kilocalorie())
        let toast = food([
            toastEnergy,
            nutrient(.dietaryProtein, 6),
            nutrient(.dietaryCarbohydrates, 30),
            nutrient(.dietaryFatTotal, 3),
            nutrient(.dietarySodium, 0.35),
            nutrient(.dietaryFiber, 4)
        ], name: "Toast")
        let coffeeEnergy = nutrient(.dietaryEnergyConsumed, 5, .kilocalorie())
        let coffee = food([coffeeEnergy, nutrient(.dietaryCaffeine, 95, .gramUnit(with: .milli))], name: "Coffee")

        let records = nutritionRecords([coffee, toast])
        XCTAssertEqual(records.count, 2)
        let byName = Dictionary(uniqueKeysWithValues: records.map { ($0["name"] as? String ?? "", $0) })
        XCTAssertEqual(byName["Toast"]?["calories"] as? Double, 180)
        XCTAssertEqual(byName["Toast"]?["carbs_grams"] as? Double, 30)
        XCTAssertEqual(byName["Toast"]?["sodium_mg"] as? Double ?? 0, 350, accuracy: 0.0001)
        XCTAssertEqual(byName["Toast"]?["dietary_fibre_g"] as? Double, 4)
        XCTAssertNil(byName["Toast"]?["caffeine_mg"])
        XCTAssertEqual(byName["Coffee"]?["caffeine_mg"] as? Double ?? 0, 95, accuracy: 0.0001)
        XCTAssertNil(byName["Coffee"]?["protein_grams"])
        // The energy sample's uuid, as 1.4 sent it, and a deletion target.
        XCTAssertEqual(byName["Toast"]?["uuid"] as? String, toastEnergy.uuid.uuidString)
        XCTAssertEqual(byName["Coffee"]?["uuid"] as? String, coffeeEnergy.uuid.uuidString)
        for record in records {
            XCTAssertTrue(Set(record.keys).isSubset(of: androidNutritionFields))
            XCTAssertEqual(record["start_time"] as? String, "2026-01-01T08:00:00Z")
        }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(records))
    }

    func testAFoodWithoutEnergyIsStillSentButOneWithoutAMainNutrientIsNot() {
        let carbs = nutrient(.dietaryCarbohydrates, 22)
        let records = nutritionRecords([food([carbs, nutrient(.dietaryFatTotal, 1)])])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["carbs_grams"] as? Double, 22)
        XCTAssertNil(records[0]["calories"])
        XCTAssertNil(records[0]["name"])
        XCTAssertEqual(records[0]["uuid"] as? String, carbs.uuid.uuidString)

        // Nothing observes or anchors caffeine, so such a food would go out only by chance.
        XCTAssertTrue(nutritionRecords([food([nutrient(.dietaryCaffeine, 0.08)])]).isEmpty)
    }

    func testLoneNutrientsOfOneEntryBecomeOneRecord() {
        let energy = nutrient(.dietaryEnergyConsumed, 420, .kilocalorie(), name: "Lunch")
        let protein = nutrient(.dietaryProtein, 25, name: "Lunch")
        let laterFat = nutrient(.dietaryFatTotal, 9, at: 1800)
        let records = nutritionRecords([], loose: [protein, laterFat, energy])
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["calories"] as? Double, 420)
        XCTAssertEqual(records[0]["protein_grams"] as? Double, 25)
        XCTAssertEqual(records[0]["name"] as? String, "Lunch")
        XCTAssertEqual(records[0]["uuid"] as? String, energy.uuid.uuidString)
        XCTAssertEqual(records[1]["fat_grams"] as? Double, 9)
        XCTAssertEqual(records[1]["uuid"] as? String, laterFat.uuid.uuidString)
    }

    func testLoneNutrientsThatCannotBeToldApartAreSentOneByOne() {
        // Two energy values at one moment: which protein goes with which is unknown.
        let samples = [
            nutrient(.dietaryEnergyConsumed, 100, .kilocalorie()),
            nutrient(.dietaryEnergyConsumed, 250, .kilocalorie()),
            nutrient(.dietaryProtein, 12)
        ]
        let records = nutritionRecords([], loose: samples)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.compactMap { $0["calories"] as? Double }.reduce(0, +), 350)
        XCTAssertEqual(records.compactMap { $0["protein_grams"] as? Double }, [12])
        XCTAssertEqual(Set(records.compactMap { $0["uuid"] as? String }), Set(samples.map(\.uuid.uuidString)))
    }

    func testAFoodIsSentInTheWindowItStartsIn() {
        let energy = nutrient(.dietaryEnergyConsumed, 300, .kilocalorie(), at: 10)
        let early = food([energy], at: -50)
        XCTAssertTrue(nutritionRecords([early]).isEmpty, "its energy is part of a food, not a lone value")
        XCTAssertEqual(nutritionRecords([early], from: start.addingTimeInterval(-60)).count, 1)
    }

    // MARK: - Workouts

    /// Every HKWorkoutActivityType of the SDK the app builds with: 1 to 84 without 81, which
    /// Apple never used, and 3000 for other. A case added later is named by the compiler, as
    /// `name` switches over every case.
    private let workoutRawValues: [UInt] = Array(1...80) + Array(82...84) + [3000]

    func testEveryWorkoutTypeHasANameOfItsOwn() throws {
        var seen: [String: UInt] = [:]
        for raw in workoutRawValues {
            let type = try XCTUnwrap(HKWorkoutActivityType(rawValue: raw))
            let name = type.name
            XCTAssertTrue(type == .other || name != "other", "\(raw) is sent as other")
            XCTAssertNotNil(name.range(of: "^[a-z]+(_[a-z]+)*$", options: .regularExpression), "\(name) is not snake_case")
            XCTAssertNil(seen[name], "\(raw) and \(seen[name] ?? 0) share \(name)")
            seen[name] = raw
        }
    }

    func testTheWorkoutsThatWereOtherHaveTheirNames() {
        let named: [(HKWorkoutActivityType, String)] = [
            (.downhillSkiing, "downhill_skiing"), (.snowboarding, "snowboarding"), (.crossCountrySkiing, "cross_country_skiing"),
            (.kickboxing, "kickboxing"), (.jumpRope, "jump_rope"), (.taiChi, "tai_chi"), (.pickleball, "pickleball"),
            (.barre, "barre"), (.cardioDance, "cardio_dance"), (.socialDance, "social_dance"), (.mixedCardio, "mixed_cardio"),
            (.stepTraining, "step_training"), (.fitnessGaming, "fitness_gaming"), (.discSports, "disc_sports"),
            (.handCycling, "hand_cycling"), (.swimBikeRun, "swim_bike_run"), (.transition, "transition"),
            (.underwaterDiving, "underwater_diving"), (.wheelchairWalkPace, "wheelchair_walk_pace"),
            (.wheelchairRunPace, "wheelchair_run_pace"), (.stairs, "stairs")
        ]
        for (type, name) in named { XCTAssertEqual(type.name, name) }
        // Names that went out before stay as they were.
        XCTAssertEqual(HKWorkoutActivityType.highIntensityIntervalTraining.name, "hiit")
        XCTAssertEqual(HKWorkoutActivityType.running.name, "running")
        XCTAssertEqual(HKWorkoutActivityType.other.name, "other")
        XCTAssertEqual(HKWorkoutActivityType(rawValue: 81)?.name, "other", "a value HealthKit does not define")
    }

    func testRecordsSerializeAsJSON() {
        let records: [[String: Any]] = [
            HealthRecordMapping.vo2MaxFields(quantitySample(.vo2Max, HKQuantity(unit: HealthRecordMapping.vo2MaxUnit, doubleValue: 40))),
            HealthRecordMapping.basalBodyTemperatureFields(quantitySample(.basalBodyTemperature, HKQuantity(unit: .degreeCelsius(), doubleValue: 36.4))),
            HealthRecordMapping.cervicalMucusFields(categorySample(.cervicalMucusQuality, value: 1)),
            HealthRecordMapping.sexualActivityFields(categorySample(.sexualActivity, value: 0))
        ]
        XCTAssertTrue(JSONSerialization.isValidJSONObject(records))
    }
}
