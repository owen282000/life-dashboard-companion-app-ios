import Foundation

struct MqttSensor: Equatable {
    let key: String
    let name: String
    let state: String
    let unit: String?
    let deviceClass: String?
    let attributes: [String: String]
}

/// Pure MQTT/Home Assistant mapping logic over the shared webhook payload dictionary, kept
/// free of networking so it is unit testable. Sensors represent the LATEST record per data
/// type. The device id and default base topic are distinct from the Android app so mixed
/// households never fight over the same Home Assistant entities.
enum MqttSupport {

    static let defaultBaseTopic = "lifedashboard-ios"
    static let defaultDiscoveryPrefix = "homeassistant"
    static let deviceId = "life_dashboard_companion_ios"

    static func stateTopic(baseTopic: String, key: String) -> String { "\(baseTopic)/\(key)/state" }
    static func attributesTopic(baseTopic: String, key: String) -> String { "\(baseTopic)/\(key)/attributes" }
    static func discoveryTopic(discoveryPrefix: String, key: String) -> String {
        "\(discoveryPrefix)/sensor/\(deviceId)_\(key)/config"
    }

    private struct Mapping {
        let payloadKey: String
        let sensorKey: String
        let name: String
        let valueField: String
        let timeField: String
        let unit: String?
        let deviceClass: String?
        var scale: Double = 1
    }

    private static let mappings: [Mapping] = [
        Mapping(payloadKey: "steps", sensorKey: "steps", name: "Steps (latest record)",
                valueField: "count", timeField: "end_time", unit: "steps", deviceClass: nil),
        Mapping(payloadKey: "heart_rate", sensorKey: "heart_rate", name: "Heart Rate",
                valueField: "bpm", timeField: "time", unit: "bpm", deviceClass: nil),
        Mapping(payloadKey: "resting_heart_rate", sensorKey: "resting_heart_rate", name: "Resting Heart Rate",
                valueField: "bpm", timeField: "time", unit: "bpm", deviceClass: nil),
        Mapping(payloadKey: "heart_rate_variability", sensorKey: "heart_rate_variability", name: "Heart Rate Variability",
                valueField: "heart_rate_variability_millis", timeField: "time", unit: "ms", deviceClass: nil),
        Mapping(payloadKey: "sleep", sensorKey: "sleep_duration", name: "Last Sleep Duration",
                valueField: "duration_seconds", timeField: "session_end_time", unit: "min", deviceClass: "duration", scale: 1.0 / 60.0),
        Mapping(payloadKey: "weight", sensorKey: "weight", name: "Weight",
                valueField: "kilograms", timeField: "time", unit: "kg", deviceClass: "weight"),
        Mapping(payloadKey: "height", sensorKey: "height", name: "Height",
                valueField: "meters", timeField: "time", unit: "m", deviceClass: "distance"),
        Mapping(payloadKey: "blood_glucose", sensorKey: "blood_glucose", name: "Blood Glucose",
                valueField: "mmol_per_liter", timeField: "time", unit: "mmol/L", deviceClass: nil),
        Mapping(payloadKey: "oxygen_saturation", sensorKey: "oxygen_saturation", name: "Oxygen Saturation",
                valueField: "percentage", timeField: "time", unit: "%", deviceClass: nil),
        Mapping(payloadKey: "body_temperature", sensorKey: "body_temperature", name: "Body Temperature",
                valueField: "celsius", timeField: "time", unit: "°C", deviceClass: "temperature"),
        Mapping(payloadKey: "respiratory_rate", sensorKey: "respiratory_rate", name: "Respiratory Rate",
                valueField: "rate", timeField: "time", unit: "breaths/min", deviceClass: nil),
        Mapping(payloadKey: "distance", sensorKey: "distance", name: "Distance (latest record)",
                valueField: "meters", timeField: "end_time", unit: "m", deviceClass: "distance"),
        Mapping(payloadKey: "active_calories", sensorKey: "active_calories", name: "Active Calories (latest record)",
                valueField: "calories", timeField: "end_time", unit: "kcal", deviceClass: nil),
        Mapping(payloadKey: "total_calories", sensorKey: "total_calories", name: "Total Calories (latest record)",
                valueField: "calories", timeField: "end_time", unit: "kcal", deviceClass: nil),
        Mapping(payloadKey: "hydration", sensorKey: "hydration", name: "Hydration (latest record)",
                valueField: "liters", timeField: "end_time", unit: "L", deviceClass: "volume"),
        Mapping(payloadKey: "body_fat", sensorKey: "body_fat", name: "Body Fat",
                valueField: "percentage", timeField: "time", unit: "%", deviceClass: nil),
        Mapping(payloadKey: "lean_body_mass", sensorKey: "lean_body_mass", name: "Lean Body Mass",
                valueField: "kilograms", timeField: "time", unit: "kg", deviceClass: "weight")
    ]

    static func sensors(from payload: [String: Any]) -> [MqttSensor] {
        var sensors: [MqttSensor] = []

        for mapping in mappings {
            guard let records = payload[mapping.payloadKey] as? [[String: Any]],
                  let latest = latestRecord(records, timeField: mapping.timeField),
                  let value = numericValue(latest[mapping.valueField]) else { continue }
            sensors.append(MqttSensor(
                key: mapping.sensorKey,
                name: mapping.name,
                state: format(value * mapping.scale),
                unit: mapping.unit,
                deviceClass: mapping.deviceClass,
                attributes: attributes(from: latest, timeField: mapping.timeField)
            ))
        }

        // Blood pressure carries two values in one record and becomes two sensors.
        if let records = payload["blood_pressure"] as? [[String: Any]],
           let latest = latestRecord(records, timeField: "time") {
            let attrs = attributes(from: latest, timeField: "time")
            if let systolic = numericValue(latest["systolic"]) {
                sensors.append(MqttSensor(key: "blood_pressure_systolic", name: "Blood Pressure Systolic",
                                          state: format(systolic), unit: "mmHg", deviceClass: nil, attributes: attrs))
            }
            if let diastolic = numericValue(latest["diastolic"]) {
                sensors.append(MqttSensor(key: "blood_pressure_diastolic", name: "Blood Pressure Diastolic",
                                          state: format(diastolic), unit: "mmHg", deviceClass: nil, attributes: attrs))
            }
        }
        return sensors
    }

    static func discoveryConfigJSON(for sensor: MqttSensor, baseTopic: String, appVersion: String) -> Data {
        var config: [String: Any] = [
            "name": sensor.name,
            "unique_id": "\(deviceId)_\(sensor.key)",
            "state_topic": stateTopic(baseTopic: baseTopic, key: sensor.key),
            "json_attributes_topic": attributesTopic(baseTopic: baseTopic, key: sensor.key),
            "state_class": "measurement",
            "device": [
                "identifiers": [deviceId],
                "name": "Life Dashboard Companion (iOS)",
                "manufacturer": "owen282000",
                "model": "iOS app",
                "sw_version": appVersion
            ] as [String: Any]
        ]
        if let unit = sensor.unit { config["unit_of_measurement"] = unit }
        if let deviceClass = sensor.deviceClass { config["device_class"] = deviceClass }
        return (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data()
    }

    static func attributesJSON(for sensor: MqttSensor) -> Data {
        (try? JSONSerialization.data(withJSONObject: sensor.attributes, options: [.sortedKeys])) ?? Data()
    }

    // MARK: - Private helpers

    private static func latestRecord(_ records: [[String: Any]], timeField: String) -> [String: Any]? {
        records.max { lhs, rhs in
            (lhs[timeField] as? String ?? "") < (rhs[timeField] as? String ?? "")
        }
    }

    private static func numericValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value && abs(value) < 1_000_000_000 {
            return String(Int(value))
        }
        return String((value * 100).rounded() / 100)
    }

    private static func attributes(from record: [String: Any], timeField: String) -> [String: String] {
        var attrs: [String: String] = [:]
        if let time = record[timeField] as? String { attrs["measured_at"] = time }
        if let source = record["source"] as? String { attrs["source"] = source }
        if let uuid = record["uuid"] as? String { attrs["uuid"] = uuid }
        return attrs
    }
}
