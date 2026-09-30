import XCTest
@testable import LifeDashboardCompanion

final class MqttSupportTests: XCTestCase {

    func testEmptyPayloadYieldsNoSensors() {
        XCTAssertEqual(MqttSupport.sensors(from: [:]), [])
    }

    func testLatestRecordWinsPerType() {
        let payload: [String: Any] = [
            "heart_rate": [
                ["bpm": 70, "time": "2026-01-01T08:00:00Z", "source": "com.app.a"],
                ["bpm": 85, "time": "2026-01-01T09:00:00Z", "source": "com.app.b"]
            ]
        ]
        let sensors = MqttSupport.sensors(from: payload)
        XCTAssertEqual(sensors.count, 1)
        XCTAssertEqual(sensors[0].key, "heart_rate")
        XCTAssertEqual(sensors[0].state, "85")
        XCTAssertEqual(sensors[0].attributes["source"], "com.app.b")
        XCTAssertEqual(sensors[0].attributes["measured_at"], "2026-01-01T09:00:00Z")
    }

    func testBloodPressureYieldsTwoSensors() {
        let payload: [String: Any] = [
            "blood_pressure": [["systolic": 121.0, "diastolic": 79.0, "time": "2026-01-01T08:00:00Z"]]
        ]
        let keys = MqttSupport.sensors(from: payload).map(\.key).sorted()
        XCTAssertEqual(keys, ["blood_pressure_diastolic", "blood_pressure_systolic"])
    }

    func testSleepSensorConvertsSecondsToMinutes() {
        let payload: [String: Any] = [
            "sleep": [["duration_seconds": 27000, "session_end_time": "2026-01-01T07:00:00Z"]]
        ]
        let sensor = MqttSupport.sensors(from: payload)[0]
        XCTAssertEqual(sensor.key, "sleep_duration")
        XCTAssertEqual(sensor.state, "450")
    }

    func testBasalBodyTemperatureAndVo2MaxMatchAndroidSensors() {
        let payload: [String: Any] = [
            "basal_body_temperature": [["celsius": 36.45, "time": "2026-01-01T06:30:00Z"]],
            "vo2_max": [["vo2_ml_per_min_per_kg": 42.5, "time": "2026-01-01T09:00:00Z"]]
        ]
        let sensors = Dictionary(uniqueKeysWithValues: MqttSupport.sensors(from: payload).map { ($0.key, $0) })
        XCTAssertEqual(sensors.count, 2)

        let temperature = sensors["basal_body_temperature"]
        XCTAssertEqual(temperature?.name, "Basal Body Temperature")
        XCTAssertEqual(temperature?.state, "36.45")
        XCTAssertEqual(temperature?.unit, "°C")
        XCTAssertEqual(temperature?.deviceClass, "temperature")

        let vo2Max = sensors["vo2_max"]
        XCTAssertEqual(vo2Max?.name, "VO2 Max")
        XCTAssertEqual(vo2Max?.state, "42.5")
        XCTAssertEqual(vo2Max?.unit, "mL/min/kg")
        XCTAssertNil(vo2Max?.deviceClass)
    }

    func testCycleTrackingStaysWebhookOnly() {
        let payload: [String: Any] = [
            "menstruation_flow": [["flow": "light", "time": "2026-01-01T00:00:00Z"]],
            "intermenstrual_bleeding": [["time": "2026-01-02T00:00:00Z"]],
            "ovulation_test": [["result": "positive", "time": "2026-01-03T08:00:00Z"]],
            "cervical_mucus": [["appearance": "egg_white", "sensation": "unknown", "time": "2026-01-03T08:00:00Z"]],
            "sexual_activity": [["protection_used": "unknown", "time": "2026-01-03T22:00:00Z"]]
        ]
        XCTAssertEqual(MqttSupport.sensors(from: payload), [])
    }

    func testTopicsFollowTheExpectedShape() {
        XCTAssertEqual(MqttSupport.stateTopic(baseTopic: "lifedashboard-ios", key: "weight"),
                       "lifedashboard-ios/weight/state")
        XCTAssertEqual(MqttSupport.attributesTopic(baseTopic: "lifedashboard-ios", key: "weight"),
                       "lifedashboard-ios/weight/attributes")
        XCTAssertEqual(MqttSupport.discoveryTopic(discoveryPrefix: "homeassistant", key: "weight"),
                       "homeassistant/sensor/life_dashboard_companion_ios_weight/config")
    }

    func testDiscoveryConfigContainsRequiredHomeAssistantFields() {
        let sensor = MqttSensor(key: "weight", name: "Weight", state: "80.5",
                                unit: "kg", deviceClass: "weight",
                                attributes: ["measured_at": "2026-01-01T08:00:00Z"])
        let json = String(data: MqttSupport.discoveryConfigJSON(for: sensor, baseTopic: "lifedashboard-ios", appVersion: "1.3.0"), encoding: .utf8) ?? ""
        for expected in [
            "\"unique_id\":\"life_dashboard_companion_ios_weight\"",
            "\"state_topic\":\"lifedashboard-ios\\/weight\\/state\"",
            "\"unit_of_measurement\":\"kg\"",
            "\"device_class\":\"weight\"",
            "\"sw_version\":\"1.3.0\"",
            "\"identifiers\":[\"life_dashboard_companion_ios\"]"
        ] {
            XCTAssertTrue(json.contains(expected), "missing \(expected) in \(json)")
        }
    }
    // MARK: - Phone name

    /// Android's MqttSupportTest vectors, so a name gives the same slug on both apps.
    func testPhoneSlugFollowsTheAndroidApp() {
        XCTAssertNil(MqttSupport.phoneSlug(nil))
        XCTAssertNil(MqttSupport.phoneSlug("   "))
        XCTAssertEqual(MqttSupport.phoneSlug("Pixel 8"), "pixel_8")
        XCTAssertEqual(MqttSupport.phoneSlug("  Zoë's phone  "), "zoe_s_phone")
        XCTAssertEqual(MqttSupport.phoneSlug("Owen--Phone!"), "owen_phone")
        XCTAssertEqual(MqttSupport.phoneSlug("a_b"), "a_b")
        XCTAssertNil(MqttSupport.phoneSlug("!!!"), "a name with nothing usable in it is no name")
        XCTAssertEqual(MqttSupport.phoneSlug("Åse’s iPhone 15"), "ase_s_iphone_15")
    }

    func testWithoutANameTheTopicsAndIdsStayAsTheyWere() {
        XCTAssertEqual(MqttSupport.stateTopic(baseTopic: "lifedashboard-ios", key: "weight", slug: nil), "lifedashboard-ios/weight/state")
        XCTAssertEqual(MqttSupport.deviceId(slug: nil), "life_dashboard_companion_ios")
        XCTAssertEqual(MqttSupport.deviceName(phoneName: nil), "Life Dashboard Companion (iOS)")
        XCTAssertEqual(MqttSupport.deviceName(phoneName: " "), "Life Dashboard Companion (iOS)")

        let sensor = MqttSensor(key: "weight", name: "Weight", state: "80.5", unit: "kg", deviceClass: "weight", attributes: [:])
        XCTAssertEqual(
            MqttSupport.discoveryConfigJSON(for: sensor, baseTopic: "lifedashboard-ios", appVersion: "1.4.1", phoneName: ""),
            MqttSupport.discoveryConfigJSON(for: sensor, baseTopic: "lifedashboard-ios", appVersion: "1.4.1"),
            "an empty name is no name"
        )
        XCTAssertEqual(
            MqttSupport.discoveryConfigJSON(for: sensor, baseTopic: "lifedashboard-ios", appVersion: "1.4.1", phoneName: "!!!"),
            MqttSupport.discoveryConfigJSON(for: sensor, baseTopic: "lifedashboard-ios", appVersion: "1.4.1"),
            "a name without a slug publishes nameless, device name included"
        )
    }

    func testANamedIPhoneGetsItsOwnDeviceAndTopics() throws {
        let slug = MqttSupport.phoneSlug("Owen's iPhone")
        XCTAssertEqual(MqttSupport.stateTopic(baseTopic: "lifedashboard-ios", key: "weight", slug: slug),
                       "lifedashboard-ios/owen_s_iphone/weight/state")
        XCTAssertEqual(MqttSupport.attributesTopic(baseTopic: "lifedashboard-ios", key: "weight", slug: slug),
                       "lifedashboard-ios/owen_s_iphone/weight/attributes")
        XCTAssertEqual(MqttSupport.discoveryTopic(discoveryPrefix: "homeassistant", key: "weight", slug: slug),
                       "homeassistant/sensor/life_dashboard_companion_ios_owen_s_iphone_weight/config")

        let sensor = MqttSensor(key: "weight", name: "Weight", state: "80.5", unit: "kg", deviceClass: "weight", attributes: [:])
        let data = MqttSupport.discoveryConfigJSON(for: sensor, baseTopic: "lifedashboard-ios", appVersion: "1.4.1", phoneName: "Owen's iPhone")
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(config["unique_id"] as? String, "life_dashboard_companion_ios_owen_s_iphone_weight")
        XCTAssertEqual(config["state_topic"] as? String, "lifedashboard-ios/owen_s_iphone/weight/state")
        XCTAssertEqual(config["json_attributes_topic"] as? String, "lifedashboard-ios/owen_s_iphone/weight/attributes")
        let device = try XCTUnwrap(config["device"] as? [String: Any])
        XCTAssertEqual(device["identifiers"] as? [String], ["life_dashboard_companion_ios_owen_s_iphone"])
        XCTAssertEqual(device["name"] as? String, "Life Dashboard Companion (iOS, Owen's iPhone)")
    }

    func testARenameClearsTheOldDeviceOnce() {
        let keys = ["weight", "heart_rate"]
        func clear(_ previous: String?, _ current: String?) -> [String] {
            MqttSupport.topicsToClearOnRename(baseTopic: "lifedashboard-ios", discoveryPrefix: "homeassistant",
                                              keys: keys, previousSlug: previous, currentSlug: current)
        }
        XCTAssertEqual(clear(nil, nil), [], "an iPhone that never had a name changes nothing")
        XCTAssertEqual(clear("owen", "owen"), [])

        // Nameless until now, then named: the nameless device goes, state and attributes first.
        XCTAssertEqual(clear(nil, "owen"), [
            "lifedashboard-ios/weight/state",
            "lifedashboard-ios/weight/attributes",
            "homeassistant/sensor/life_dashboard_companion_ios_weight/config",
            "lifedashboard-ios/heart_rate/state",
            "lifedashboard-ios/heart_rate/attributes",
            "homeassistant/sensor/life_dashboard_companion_ios_heart_rate/config"
        ])
        // Renamed again: the previous name's device goes, the nameless topics are left alone.
        XCTAssertEqual(clear("owen", "zoe").first, "lifedashboard-ios/owen/weight/state")
        // Name removed: back to nameless, the named device goes.
        XCTAssertEqual(clear("zoe", nil).last, "homeassistant/sensor/life_dashboard_companion_ios_zoe_heart_rate/config")
    }

    /// A rename clears every key the iPhone can publish, since it keeps no list of what it did.
    func testAllSensorKeysCoverEverySensor() {
        let payload: [String: Any] = [
            "steps": [["count": 10, "end_time": "2026-01-01T08:00:00Z"]],
            "heart_rate": [["bpm": 60, "time": "2026-01-01T08:00:00Z"]],
            "resting_heart_rate": [["bpm": 50, "time": "2026-01-01T08:00:00Z"]],
            "heart_rate_variability": [["heart_rate_variability_millis": 40, "time": "2026-01-01T08:00:00Z"]],
            "sleep": [["duration_seconds": 3600, "session_end_time": "2026-01-01T08:00:00Z"]],
            "weight": [["kilograms": 80, "time": "2026-01-01T08:00:00Z"]],
            "height": [["meters": 1.8, "time": "2026-01-01T08:00:00Z"]],
            "blood_glucose": [["mmol_per_liter": 5.5, "time": "2026-01-01T08:00:00Z"]],
            "oxygen_saturation": [["percentage": 98, "time": "2026-01-01T08:00:00Z"]],
            "body_temperature": [["celsius": 36.8, "time": "2026-01-01T08:00:00Z"]],
            "basal_body_temperature": [["celsius": 36.4, "time": "2026-01-01T08:00:00Z"]],
            "respiratory_rate": [["rate": 14, "time": "2026-01-01T08:00:00Z"]],
            "distance": [["meters": 100, "end_time": "2026-01-01T08:00:00Z"]],
            "active_calories": [["calories": 10, "end_time": "2026-01-01T08:00:00Z"]],
            "total_calories": [["calories": 20, "end_time": "2026-01-01T08:00:00Z"]],
            "hydration": [["liters": 0.25, "end_time": "2026-01-01T08:00:00Z"]],
            "body_fat": [["percentage": 20, "time": "2026-01-01T08:00:00Z"]],
            "lean_body_mass": [["kilograms": 60, "time": "2026-01-01T08:00:00Z"]],
            "vo2_max": [["vo2_ml_per_min_per_kg": 42, "time": "2026-01-01T08:00:00Z"]],
            "blood_pressure": [["systolic": 120, "diastolic": 80, "time": "2026-01-01T08:00:00Z"]],
            "daily_totals": [["date": "2026-01-01", "steps": 10, "distance_meters": 100, "active_calories": 10, "total_calories": 20]]
        ]
        let published = Set(MqttSupport.sensors(from: payload, today: "2026-01-01").map(\.key))
        XCTAssertTrue(published.isDisjoint(with: MqttSupport.retiredSensorKeys))
        XCTAssertFalse(published.isEmpty)
        XCTAssertTrue(published.isSubset(of: Set(MqttSupport.allSensorKeys)), "missing \(published.subtracting(MqttSupport.allSensorKeys))")
    }
    // MARK: - Today's totals

    private let totals: [String: Any] = [
        "steps": [["count": 40, "start_time": "2026-09-30T08:00:00Z", "end_time": "2026-09-30T08:10:00Z"]],
        "distance": [["meters": 31.5, "start_time": "2026-09-30T08:00:00Z", "end_time": "2026-09-30T08:10:00Z"]],
        "daily_totals": [
            ["date": "2026-09-29", "steps": 12_000, "distance_meters": 9000.0, "active_calories": 600.0, "total_calories": 2400.0],
            ["date": "2026-09-30", "steps": 8002, "distance_meters": 5920.6, "active_calories": 312.4, "total_calories": 1890.5]
        ]
    ]

    /// Android's four day sensors, from today's entry, and no latest-record sensor for the raw
    /// steps and distance records.
    func testTodaysTotalsBecomeTheAndroidAppsDaySensors() throws {
        let sensors = Dictionary(uniqueKeysWithValues: MqttSupport.sensors(from: totals, today: "2026-09-30").map { ($0.key, $0) })
        XCTAssertEqual(Set(sensors.keys), ["steps_today", "distance_today", "active_calories_today", "total_calories_today"])

        let steps = try XCTUnwrap(sensors["steps_today"])
        XCTAssertEqual(steps.name, "Steps Today")
        XCTAssertEqual(steps.state, "8002")
        XCTAssertEqual(steps.unit, "steps")
        XCTAssertNil(steps.deviceClass)
        XCTAssertEqual(steps.stateClass, "total_increasing")
        XCTAssertEqual(steps.attributes, ["date": "2026-09-30"])

        let distance = try XCTUnwrap(sensors["distance_today"])
        XCTAssertEqual(distance.name, "Distance Today")
        XCTAssertEqual(distance.state, "5921")
        XCTAssertEqual(distance.unit, "m")
        XCTAssertEqual(distance.deviceClass, "distance")

        XCTAssertEqual(sensors["active_calories_today"]?.name, "Active Calories Today")
        XCTAssertEqual(sensors["active_calories_today"]?.state, "312")
        XCTAssertEqual(sensors["active_calories_today"]?.unit, "kcal")
        XCTAssertEqual(sensors["total_calories_today"]?.name, "Total Calories Today")
        XCTAssertEqual(sensors["total_calories_today"]?.state, "1891")
    }

    /// Yesterday's entry is not today's total: shortly after midnight it would pass for one.
    func testNoEntryForTodayPublishesNoDaySensors() {
        XCTAssertEqual(MqttSupport.sensors(from: totals, today: "2026-10-01"), [])
        XCTAssertEqual(MqttSupport.sensors(from: totals), [])
    }

    /// A day without distance has no distance field, and gets no sensor rather than a 0.
    func testAMissingFieldGivesNoSensor() {
        let payload: [String: Any] = ["daily_totals": [["date": "2026-09-30", "steps": 120]]]
        XCTAssertEqual(MqttSupport.sensors(from: payload, today: "2026-09-30").map(\.key), ["steps_today"])
    }

    func testTheRetiredKeysAreTheOnesAndroidRetired() {
        XCTAssertEqual(MqttSupport.retiredSensorKeys, ["steps", "distance", "active_calories", "total_calories"])
        XCTAssertTrue(Set(MqttSupport.allSensorKeys).isDisjoint(with: MqttSupport.retiredSensorKeys))
    }

    func testDiscoveryConfigCarriesStateClassAndDisplayPrecision() throws {
        func config(_ sensor: MqttSensor) throws -> [String: Any] {
            let data = MqttSupport.discoveryConfigJSON(for: sensor, baseTopic: "lifedashboard-ios", appVersion: "1.4.1")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let distance = try config(MqttSensor(key: "distance_today", name: "Distance Today", state: "5921", unit: "m",
                                             deviceClass: "distance", attributes: ["date": "2026-09-30"], stateClass: "total_increasing"))
        XCTAssertEqual(distance["state_class"] as? String, "total_increasing")
        XCTAssertEqual(distance["suggested_display_precision"] as? Int, 0)

        let weight = try config(MqttSensor(key: "weight", name: "Weight", state: "78.2", unit: "kg", deviceClass: "weight", attributes: [:]))
        XCTAssertEqual(weight["state_class"] as? String, "measurement")
        XCTAssertEqual(weight["suggested_display_precision"] as? Int, 1)
    }

    func testDisplayPrecisionCountsTheStatesDecimals() {
        XCTAssertEqual(MqttSupport.displayPrecision("5921"), 0)
        XCTAssertEqual(MqttSupport.displayPrecision("78.2"), 1)
        XCTAssertEqual(MqttSupport.displayPrecision("5.55"), 2)
        XCTAssertNil(MqttSupport.displayPrecision("Life Dashboard"))
    }
}
