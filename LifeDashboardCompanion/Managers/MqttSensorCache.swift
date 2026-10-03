import Foundation

/// The newest value of every sensor MQTT has mapped, as the Android app keeps it, so each
/// publish sends the whole device and not only the types a sync carries: a new broker, a
/// renamed iPhone or a broker that missed a publish gets every sensor at once, instead of each
/// one with the next record of its type. With MQTT alone the anchors move as soon as the read
/// is done, so without this a weight missed by a failed publish waited for the next weigh-in.
struct MqttSensorCache: Codable, Equatable {
    var sensors: [MqttSensor] = []
    /// Where the set last arrived in full (`MqttSensorCache.target`); nil after a publish that
    /// failed or was cut off. A sync with nothing new publishes the set again while this is
    /// not where the settings point.
    var publishedTo: String?
    /// The last failed or interrupted publish, so a broker out of reach, such as one at home
    /// while the iPhone is out, is not dialled again by every sync with nothing new.
    var failedTarget: String?
    var failedAt: Date?

    /// How long a sync with nothing new leaves a target alone after a publish to it failed.
    static let retryPause: TimeInterval = 30 * 60

    /// The broker, base topic and phone slug a publish goes to. The username and password are
    /// left out: they change who publishes, not where the sensors end up.
    static func target(host: String, port: Int, useTls: Bool, baseTopic: String, slug: String?) -> String {
        "\(useTls ? "mqtts" : "mqtt")://\(host.trimmingCharacters(in: .whitespaces)):\(port)/\(baseTopic)/\(slug ?? "")"
    }

    /// Whether the set should be published again without anything new: it has sensors and has
    /// not reached `target` since its last change of broker, topic or name, or since a failure.
    func isPending(for target: String) -> Bool {
        !sensors.isEmpty && publishedTo != target
    }

    /// Whether a sync with nothing new should publish now: the set is owed, and not to a
    /// target that failed within `retryPause`. A changed broker, topic or name goes at once.
    func shouldRepublish(to target: String, now: Date) -> Bool {
        guard isPending(for: target) else { return false }
        guard failedTarget == target, let failedAt else { return true }
        return now.timeIntervalSince(failedAt) >= MqttSensorCache.retryPause
    }

    mutating func recordPublish(to target: String, success: Bool, at now: Date) {
        publishedTo = success ? target : nil
        failedTarget = success ? nil : target
        failedAt = success ? nil : now
    }

    /// The set to publish: the cached sensors with the fresh values on top, as Android's
    /// mergeSensors does, with two rules Android leaves out. A fresh value older than the cached
    /// one does not replace it, so a back-dated entry never sets a sensor back. A day total from
    /// another day than `today` is dropped, since it is not today's total. Retired keys and keys
    /// this version does not publish are dropped.
    ///
    /// With `freshIsNewest`, for Sync Now, which reads each type's newest records, a fresh value
    /// replaces the cached one whatever its time, so a value deleted in Apple Health leaves the
    /// sensor. A cached value timed after `now`, from an app that dated it in the future, never
    /// holds back a fresh one.
    static func merged(
        cached: [MqttSensor],
        fresh: [MqttSensor],
        today: String,
        freshIsNewest: Bool = false,
        now: Date = Date()
    ) -> [MqttSensor] {
        let known = Set(MqttSupport.allSensorKeys)
        let days = Set(MqttSupport.daySensorKeys)
        var byKey: [String: MqttSensor] = [:]
        var order: [String] = []

        func keep(_ sensor: MqttSensor) {
            if byKey[sensor.key] == nil { order.append(sensor.key) }
            byKey[sensor.key] = sensor
        }

        for sensor in cached where known.contains(sensor.key) {
            if days.contains(sensor.key) && sensor.attributes["date"] != today { continue }
            keep(sensor)
        }
        for sensor in fresh where known.contains(sensor.key) {
            if !freshIsNewest, let kept = byKey[sensor.key],
               isNewer(kept, than: sensor, daySensor: days.contains(sensor.key), now: now) { continue }
            keep(sensor)
        }
        return order.compactMap { byKey[$0] }
    }

    /// A value that has no time to compare by is replaced.
    private static func isNewer(_ kept: MqttSensor, than fresh: MqttSensor, daySensor: Bool, now: Date) -> Bool {
        let field = daySensor ? "date" : "measured_at"
        guard let keptTime = kept.attributes[field], let freshTime = fresh.attributes[field] else { return false }
        if daySensor { return keptTime > freshTime }
        guard let keptDate = parse(keptTime), let freshDate = parse(freshTime) else { return keptTime > freshTime }
        return keptDate > freshDate && keptDate <= now
    }

    // ISO8601DateFormatter is documented as thread-safe.
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parse(_ text: String) -> Date? {
        plain.date(from: text) ?? fractional.date(from: text)
    }
}

/// The sensor cache on disk: one small JSON file, out of backups and encrypted at rest like the
/// retry queue, since it holds the latest health values. Each change is one read-modify-write
/// under a lock.
final class MqttSensorStore: @unchecked Sendable {
    static let shared = MqttSensorStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mqtt_sensors", isDirectory: true)
    )

    private let directory: URL
    private let fileURL: URL
    private let lock = NSLock()
    private let fileManager = FileManager.default

    init(directory: URL) {
        self.directory = directory
        fileURL = directory.appendingPathComponent("sensors.json")
    }

    /// The cache, empty when there is none or it is damaged; nil while the file exists but
    /// cannot be read, as before the first unlock after a restart, so nothing overwrites it.
    func load() -> MqttSensorCache? {
        lock.withLock { read() }
    }

    /// Changes the cache and writes it back; nil, with nothing written, while it cannot be read.
    @discardableResult
    func update<T>(_ change: (inout MqttSensorCache) -> T) -> T? {
        lock.withLock {
            guard let before = read() else { return nil }
            var cache = before
            let result = change(&cache)
            if cache != before { write(cache) }
            return result
        }
    }

    /// Removes the file, when MQTT is switched off: the values have no use without a broker.
    func clear() {
        lock.withLock { _ = try? fileManager.removeItem(at: fileURL) }
    }

    private func read() -> MqttSensorCache? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return MqttSensorCache() }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (try? JSONDecoder().decode(MqttSensorCache.self, from: data)) ?? MqttSensorCache()
    }

    private func write(_ cache: MqttSensorCache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // The flag on the directory keeps the file out; set again in case the directory was
        // made by something else.
        BackupExclusion.exclude(directory)
    }
}
