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
