import Foundation

struct MqttSensor: Equatable, Codable {
    let key: String
    let name: String
    let state: String
    let unit: String?
    let deviceClass: String?
    let attributes: [String: String]
    /// Home Assistant's state_class: a day total only grows until midnight, so HA's statistics
    /// read a drop as a new day instead of a loss.
    var stateClass = "measurement"
}

/// Pure MQTT/Home Assistant mapping logic over the shared webhook payload dictionary, kept
/// free of networking so it is unit testable. Point-in-time types (heart rate, weight) map to
/// the LATEST record; steps, distance and calories map to TODAY'S TOTAL from `daily_totals`,
/// as in the Android app, since a single steps record is a few dozen steps and means nothing on
/// a dashboard. The device id and default base topic are distinct from the Android app so
/// mixed households never fight over the same Home Assistant entities.
enum MqttSupport {

    static let defaultBaseTopic = "lifedashboard-ios"
    static let defaultDiscoveryPrefix = "homeassistant"
    static let deviceId = "life_dashboard_companion_ios"
    static let deviceName = "Life Dashboard Companion (iOS)"

    /// The phone name as it appears in topics and ids, as the Android app makes it: lower case
    /// letters, digits and underscores, nothing else. Accents are stripped rather than replaced,
    /// so "Zoë" is "zoe". Nil for a blank name, which is the signal that this iPhone has no name
    /// and everything stays exactly as it was before names existed.
    static func phoneSlug(_ name: String?) -> String? {
        guard let name else { return nil }
        let plain = String(String.UnicodeScalarView(
            name.trimmingCharacters(in: .whitespacesAndNewlines).decomposedStringWithCanonicalMapping.unicodeScalars
                .filter { !markCategories.contains($0.properties.generalCategory) }
        )).lowercased()
        // Android's [^a-z0-9_]+ -> "_": a run of other characters becomes one underscore, and
        // an underscore that was typed stays as it is.
        var slug = ""
        var inRun = false
        for scalar in plain.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" {
                slug.unicodeScalars.append(scalar)
                inRun = false
            } else if !inRun {
                slug += "_"
                inRun = true
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let markCategories: Set<Unicode.GeneralCategory> = [.nonspacingMark, .spacingMark, .enclosingMark]

    /// The Home Assistant device id: the fixed one, or with the phone's slug behind it.
    static func deviceId(slug: String?) -> String {
        slug.map { "\(deviceId)_\($0)" } ?? deviceId
    }

    /// The device name Home Assistant shows: with the phone's name in it when it has one.
    static func deviceName(phoneName: String?) -> String {
        let name = phoneName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? deviceName : "Life Dashboard Companion (iOS, \(name))"
    }

    /// Topics carry the phone's slug between the base topic and the sensor key, so two iPhones
    /// on one broker never publish over each other. Without a slug they are the topics every
    /// receiver has been reading.
    static func stateTopic(baseTopic: String, key: String, slug: String? = nil) -> String {
        "\(topicRoot(baseTopic, slug))/\(key)/state"
    }
    static func attributesTopic(baseTopic: String, key: String, slug: String? = nil) -> String {
        "\(topicRoot(baseTopic, slug))/\(key)/attributes"
    }
    static func discoveryTopic(discoveryPrefix: String, key: String, slug: String? = nil) -> String {
        "\(discoveryPrefix)/sensor/\(deviceId(slug: slug))_\(key)/config"
    }

    private static func topicRoot(_ baseTopic: String, _ slug: String?) -> String {
        slug.map { "\(baseTopic)/\($0)" } ?? baseTopic
    }

    /// Every retained topic the sensors with `keys` occupy under `slug`: state and attributes
    /// first, the discovery config last, the order that clears an entity cleanly (an empty
    /// attributes payload on a living entity makes Home Assistant log "Erroneous JSON"; the
    /// config clear removes it).
    static func topicsFor(baseTopic: String, discoveryPrefix: String, keys: [String], slug: String?) -> [String] {
        keys.flatMap { key in
            [
                stateTopic(baseTopic: baseTopic, key: key, slug: slug),
                attributesTopic(baseTopic: baseTopic, key: key, slug: slug),
                discoveryTopic(discoveryPrefix: discoveryPrefix, key: key, slug: slug)
            ]
        }
    }

    /// What to clear before publishing under `currentSlug` when the iPhone last published under
    /// `previousSlug`: nothing while the name is unchanged, otherwise every topic of every
    /// sensor the app can publish under the old slug, so the old device does not live on with
    /// frozen values next to the new one. An iPhone that never recorded a slug published
    /// nameless.
    static func topicsToClearOnRename(
        baseTopic: String,
        discoveryPrefix: String,
        keys: [String],
        previousSlug: String?,
        currentSlug: String?
    ) -> [String] {
        previousSlug == currentSlug ? [] : topicsFor(baseTopic: baseTopic, discoveryPrefix: discoveryPrefix, keys: keys, slug: previousSlug)
    }

    /// Every sensor key `sensors(from:)` can produce. A rename clears all of them under the old
    /// slug, not only the ones in the sensor cache, which starts empty on the update that
    /// brought it and is not in backups.
    static var allSensorKeys: [String] {
        dayTotals.map(\.sensorKey) + mappings.map(\.sensorKey) + ["blood_pressure_systolic", "blood_pressure_diastolic"]
    }

    /// The keys of today's totals, which hold one day and carry it in a `date` attribute.
    static var daySensorKeys: [String] {
        dayTotals.map(\.sensorKey)
    }

    /// Keys that versions up to 1.4.1 published as "(latest record)" sensors, replaced by the
    /// day totals. Their retained discovery configs would keep a stale entity alive in Home
    /// Assistant for good, so every publish empties their topics, as the Android app does.
    static let retiredSensorKeys = ["steps", "distance", "active_calories", "total_calories"]

    /// Today's totals, from the `daily_totals` entry of today, under the Android app's keys,
    /// names and units. The date goes along as an attribute.
    private struct DayTotal {
        let field: String
        let sensorKey: String
        let name: String
        let unit: String
        let deviceClass: String?
    }

    private static let dayTotals: [DayTotal] = [
        DayTotal(field: "steps", sensorKey: "steps_today", name: "Steps Today", unit: "steps", deviceClass: nil),
        DayTotal(field: "distance_meters", sensorKey: "distance_today", name: "Distance Today", unit: "m", deviceClass: "distance"),
        DayTotal(field: "active_calories", sensorKey: "active_calories_today", name: "Active Calories Today", unit: "kcal", deviceClass: nil),
        DayTotal(field: "total_calories", sensorKey: "total_calories_today", name: "Total Calories Today", unit: "kcal", deviceClass: nil)
    ]

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

    // Event-like types (exercise, nutrition, mindfulness, cycle tracking, sexual activity) are
    // not mapped, as in the Android app: they do not fit a single-value sensor, and a retained
    // topic on the broker is no place for reproductive data. They remain webhook-only.
    private static let mappings: [Mapping] = [
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
        Mapping(payloadKey: "basal_body_temperature", sensorKey: "basal_body_temperature", name: "Basal Body Temperature",
                valueField: "celsius", timeField: "time", unit: "°C", deviceClass: "temperature"),
        Mapping(payloadKey: "respiratory_rate", sensorKey: "respiratory_rate", name: "Respiratory Rate",
                valueField: "rate", timeField: "time", unit: "breaths/min", deviceClass: nil),
        Mapping(payloadKey: "hydration", sensorKey: "hydration", name: "Hydration (latest record)",
                valueField: "liters", timeField: "end_time", unit: "L", deviceClass: "volume"),
        Mapping(payloadKey: "body_fat", sensorKey: "body_fat", name: "Body Fat",
                valueField: "percentage", timeField: "time", unit: "%", deviceClass: nil),
        Mapping(payloadKey: "lean_body_mass", sensorKey: "lean_body_mass", name: "Lean Body Mass",
                valueField: "kilograms", timeField: "time", unit: "kg", deviceClass: "weight"),
        Mapping(payloadKey: "vo2_max", sensorKey: "vo2_max", name: "VO2 Max",
                valueField: "vo2_ml_per_min_per_kg", timeField: "time", unit: "mL/min/kg", deviceClass: nil)
    ]

    /// `today` is the `yyyy-MM-dd` whose `daily_totals` entry becomes the day sensors; an entry
    /// for another day is not today's total, and a type without one publishes no day sensor.
    static func sensors(from payload: [String: Any], today: String? = nil) -> [MqttSensor] {
        var sensors: [MqttSensor] = []

        if let today, let entries = payload[DailyTotals.payloadKey] as? [[String: Any]],
           let entry = entries.first(where: { $0["date"] as? String == today }) {
            for total in dayTotals {
                guard let value = numericValue(entry[total.field]), value.isFinite, value.magnitude < 1e15 else { continue }
                sensors.append(MqttSensor(
                    key: total.sensorKey,
                    name: total.name,
                    state: String(Int(value.rounded())),
                    unit: total.unit,
                    deviceClass: total.deviceClass,
                    attributes: ["date": today],
                    stateClass: "total_increasing"
                ))
            }
        }

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

    /// With a `phoneName` the unique ids, the topics and the device all carry it, so a second
    /// iPhone becomes a second device instead of overwriting the first.
    static func discoveryConfigJSON(for sensor: MqttSensor, baseTopic: String, appVersion: String, phoneName: String? = nil) -> Data {
        let slug = phoneSlug(phoneName)
        let device = deviceId(slug: slug)
        var config: [String: Any] = [
            "name": sensor.name,
            "unique_id": "\(device)_\(sensor.key)",
            "state_topic": stateTopic(baseTopic: baseTopic, key: sensor.key, slug: slug),
            "json_attributes_topic": attributesTopic(baseTopic: baseTopic, key: sensor.key, slug: slug),
            "state_class": sensor.stateClass,
            "device": [
                "identifiers": [device],
                "name": deviceName(phoneName: slug == nil ? nil : phoneName),
                "manufacturer": "owen282000",
                "model": "iOS app",
                "sw_version": appVersion
            ] as [String: Any]
        ]
        if let unit = sensor.unit { config["unit_of_measurement"] = unit }
        if let deviceClass = sensor.deviceClass { config["device_class"] = deviceClass }
        // Home Assistant shows a sensor with a convertible device class (distance, weight,
        // duration) with two decimals by default, which turns 5921 m into "5,921.00 m". The
        // state carries the decimals it has, so HA is told to show exactly those.
        if let precision = displayPrecision(sensor.state) { config["suggested_display_precision"] = precision }
        return (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data()
    }

    /// Decimals in a numeric state ("78.2" gives 1, "8002" gives 0), nil for text.
    static func displayPrecision(_ state: String) -> Int? {
        guard Double(state) != nil else { return nil }
        return state.split(separator: ".", maxSplits: 1).dropFirst().first?.count ?? 0
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
