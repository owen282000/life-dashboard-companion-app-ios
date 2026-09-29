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
