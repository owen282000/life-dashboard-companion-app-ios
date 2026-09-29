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
}
