import XCTest
@testable import LifeDashboardCompanion

final class MqttSensorCacheTests: XCTestCase {

    private func weight(_ kilograms: String, at time: String) -> MqttSensor {
        MqttSensor(key: "weight", name: "Weight", state: kilograms, unit: "kg", deviceClass: "weight",
                   attributes: ["measured_at": time, "source": "Scale"])
    }

    private func steps(_ count: String, on date: String) -> MqttSensor {
        MqttSensor(key: "steps_today", name: "Steps Today", state: count, unit: "steps", deviceClass: nil,
                   attributes: ["date": date], stateClass: "total_increasing")
    }

    private func heartRate(_ bpm: String, at time: String) -> MqttSensor {
        MqttSensor(key: "heart_rate", name: "Heart Rate", state: bpm, unit: "bpm", deviceClass: nil,
                   attributes: ["measured_at": time])
    }

    // MARK: - Merge

    func testEveryCachedSensorGoesOutWithTheFreshOnes() {
        let merged = MqttSensorCache.merged(
            cached: [weight("80.5", at: "2026-10-01T07:00:00Z")],
            fresh: [heartRate("62", at: "2026-10-03T09:00:00Z")],
            today: "2026-10-03"
        )
        XCTAssertEqual(merged.map(\.key), ["weight", "heart_rate"], "a sync with only heart rate still sends the weight")
    }

    func testANewerValueReplacesTheCachedOne() {
        let merged = MqttSensorCache.merged(
            cached: [weight("80.5", at: "2026-10-01T07:00:00Z")],
            fresh: [weight("80.1", at: "2026-10-03T07:00:00Z")],
            today: "2026-10-03"
        )
        XCTAssertEqual(merged.map(\.state), ["80.1"])
    }

    func testAnOlderValueNeverOverwritesANewerCachedOne() {
        let merged = MqttSensorCache.merged(
            cached: [weight("80.1", at: "2026-10-03T07:00:00Z")],
            fresh: [weight("82.0", at: "2025-10-03T07:00:00Z")],
            today: "2026-10-03"
        )
        XCTAssertEqual(merged.map(\.state), ["80.1"], "a weight entered for last year is not the current one")
    }

    func testTimesAreComparedAsInstantsNotAsText() {
        // 09:30 in Amsterdam is 07:30 UTC, later than 07:00 UTC though it sorts first as text.
        let merged = MqttSensorCache.merged(
            cached: [weight("80.1", at: "2026-10-03T07:00:00Z")],
            fresh: [weight("79.9", at: "2026-10-03T09:30:00+02:00")],
            today: "2026-10-03"
        )
        XCTAssertEqual(merged.map(\.state), ["79.9"])
        let older = MqttSensorCache.merged(
            cached: [weight("80.1", at: "2026-10-03T07:00:00.500Z")],
            fresh: [weight("79.9", at: "2026-10-03T08:30:00+02:00")],
            today: "2026-10-03"
        )
        XCTAssertEqual(older.map(\.state), ["80.1"])
    }

    func testTheSameRecordAgainReplacesTheCachedOne() {
        let merged = MqttSensorCache.merged(
            cached: [weight("80.10", at: "2026-10-03T07:00:00Z")],
            fresh: [weight("80.1", at: "2026-10-03T07:00:00Z")],
            today: "2026-10-03"
        )
        XCTAssertEqual(merged.map(\.state), ["80.1"])
    }

    func testAValueWithoutATimeIsReplaced() {
        let untimed = MqttSensor(key: "weight", name: "Weight", state: "81", unit: "kg", deviceClass: "weight", attributes: [:])
        let merged = MqttSensorCache.merged(cached: [untimed], fresh: [weight("80.1", at: "2026-10-03T07:00:00Z")], today: "2026-10-03")
        XCTAssertEqual(merged.map(\.state), ["80.1"])
    }

    func testTodaysTotalGrowsAndYesterdaysIsDropped() {
        XCTAssertEqual(
            MqttSensorCache.merged(cached: [steps("4000", on: "2026-10-03")], fresh: [steps("5200", on: "2026-10-03")], today: "2026-10-03")
                .map(\.state),
            ["5200"]
        )
        XCTAssertEqual(
            MqttSensorCache.merged(cached: [steps("12000", on: "2026-10-02")], fresh: [], today: "2026-10-03"),
            [],
            "yesterday's total is not today's"
        )
    }

    func testRetiredAndUnknownKeysLeaveTheCache() {
        let retired = MqttSensor(key: "steps", name: "Steps (latest record)", state: "40", unit: "steps", deviceClass: nil, attributes: [:])
        let unknown = MqttSensor(key: "screen_time_today", name: "Screen Time Today", state: "90", unit: "min", deviceClass: nil, attributes: [:])
        let merged = MqttSensorCache.merged(cached: [retired, unknown, weight("80.1", at: "2026-10-03T07:00:00Z")], fresh: [retired], today: "2026-10-03")
        XCTAssertEqual(merged.map(\.key), ["weight"])
    }

    func testAValueDatedInTheFutureDoesNotHoldBackARealOne() {
        let now = ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z")!
        let merged = MqttSensorCache.merged(
            cached: [weight("150", at: "2027-01-01T07:00:00Z")],
            fresh: [weight("80.1", at: "2026-10-03T07:00:00Z")],
            today: "2026-10-03",
            now: now
        )
        XCTAssertEqual(merged.map(\.state), ["80.1"])
    }

    func testSyncNowReplacesANewerCachedValue() {
        // A weight deleted in Apple Health: Sync Now reads the newest one left, which is older.
        let merged = MqttSensorCache.merged(
            cached: [weight("150", at: "2026-10-03T07:00:00Z")],
            fresh: [weight("80.1", at: "2026-10-01T07:00:00Z")],
            today: "2026-10-03",
            freshIsNewest: true
        )
        XCTAssertEqual(merged.map(\.state), ["80.1"])
    }

    func testATimeThatDoesNotParseIsComparedAsText() {
        let merged = MqttSensorCache.merged(
            cached: [weight("80.1", at: "2026-10-03 07:00")],
            fresh: [weight("82.0", at: "2026-10-01T07:00:00Z")],
            today: "2026-10-03"
        )
        XCTAssertEqual(merged.map(\.state), ["80.1"])
    }

    func testTheDaySensorsAreTheDayTotals() {
        XCTAssertEqual(MqttSupport.daySensorKeys, ["steps_today", "distance_today", "active_calories_today", "total_calories_today"])
        XCTAssertTrue(Set(MqttSupport.daySensorKeys).isSubset(of: Set(MqttSupport.allSensorKeys)))
    }

    // MARK: - Pending

    func testTheSetIsOwedAfterAFailureAndOnANewBrokerTopicOrName() {
        let home = MqttSensorCache.target(host: "homeassistant.local", port: 1883, useTls: false, baseTopic: "lifedashboard-ios", slug: nil)
        var cache = MqttSensorCache(sensors: [weight("80.1", at: "2026-10-03T07:00:00Z")], publishedTo: home)
        XCTAssertFalse(cache.isPending(for: home))
        XCTAssertTrue(cache.isPending(for: MqttSensorCache.target(host: "10.0.0.2", port: 1883, useTls: false, baseTopic: "lifedashboard-ios", slug: nil)))
        XCTAssertTrue(cache.isPending(for: MqttSensorCache.target(host: "homeassistant.local", port: 8883, useTls: true, baseTopic: "lifedashboard-ios", slug: nil)))
        XCTAssertTrue(cache.isPending(for: MqttSensorCache.target(host: "homeassistant.local", port: 1883, useTls: false, baseTopic: "health", slug: nil)))
        XCTAssertTrue(cache.isPending(for: MqttSensorCache.target(host: "homeassistant.local", port: 1883, useTls: false, baseTopic: "lifedashboard-ios", slug: "owen")))
        cache.publishedTo = nil
        XCTAssertTrue(cache.isPending(for: home), "a failed or interrupted publish is owed")
        XCTAssertFalse(MqttSensorCache().isPending(for: home), "an empty cache owes nothing")
    }

    func testABrokerThatFailedIsTriedAgainAfterAPauseAndANewOneAtOnce() {
        let home = MqttSensorCache.target(host: "192.168.1.10", port: 1883, useTls: false, baseTopic: "lifedashboard-ios", slug: nil)
        let other = MqttSensorCache.target(host: "broker.example.com", port: 8883, useTls: true, baseTopic: "lifedashboard-ios", slug: nil)
        let now = Date()
        var cache = MqttSensorCache(sensors: [weight("80.1", at: "2026-10-03T07:00:00Z")])
        XCTAssertTrue(cache.shouldRepublish(to: home, now: now), "never published")

        cache.recordPublish(to: home, success: false, at: now)
        XCTAssertNil(cache.publishedTo)
        XCTAssertFalse(cache.shouldRepublish(to: home, now: now.addingTimeInterval(60)), "not by every wakeup")
        XCTAssertTrue(cache.shouldRepublish(to: home, now: now.addingTimeInterval(MqttSensorCache.retryPause)))
        XCTAssertTrue(cache.shouldRepublish(to: other, now: now.addingTimeInterval(60)), "a new broker goes at once")

        cache.recordPublish(to: home, success: true, at: now)
        XCTAssertEqual(cache.publishedTo, home)
        XCTAssertNil(cache.failedAt)
        XCTAssertFalse(cache.shouldRepublish(to: home, now: now))
        XCTAssertTrue(cache.shouldRepublish(to: other, now: now))
    }

    // MARK: - Store

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mqtt-cache-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheCacheIsKeptOnDiskOutOfBackupsAndEncrypted() throws {
        let directory = temporaryDirectory()
        let store = MqttSensorStore(directory: directory)
        XCTAssertEqual(store.load(), MqttSensorCache(), "no file is an empty cache")

        let sensors = [steps("5200", on: "2026-10-03"), weight("80.1", at: "2026-10-03T07:00:00Z")]
        store.update { $0.sensors = sensors; $0.publishedTo = "mqtt://broker:1883/lifedashboard-ios/" }
        let again = MqttSensorStore(directory: directory).load()
        XCTAssertEqual(again?.sensors, sensors)
        XCTAssertEqual(again?.sensors.first?.stateClass, "total_increasing")
        XCTAssertEqual(again?.publishedTo, "mqtt://broker:1883/lifedashboard-ios/")

        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let file = directory.appendingPathComponent("sensors.json")
        // The simulator keeps no protection class, so this checks only on a device.
        if let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        }
    }

    func testACacheThatCannotBeReadIsNeitherReplacedNorRemoved() throws {
        let directory = temporaryDirectory()
        // A directory where the file should be reads as an unreadable file.
        let file = directory.appendingPathComponent("sensors.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let store = MqttSensorStore(directory: directory)
        XCTAssertNil(store.load())
        XCTAssertNil(store.update { $0.sensors = [self.weight("80.1", at: "2026-10-03T07:00:00Z")] })
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    func testSwitchingMqttOffRemovesTheValues() {
        let directory = temporaryDirectory()
        let store = MqttSensorStore(directory: directory)
        store.update { $0.sensors = [self.weight("80.1", at: "2026-10-03T07:00:00Z")] }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sensors.json").path))
        store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sensors.json").path))
        XCTAssertEqual(store.load(), MqttSensorCache())
    }

    func testADamagedCacheStartsOver() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("sensors.json"))
        let store = MqttSensorStore(directory: directory)
        XCTAssertEqual(store.load(), MqttSensorCache())
        store.update { $0.sensors = [self.weight("80.1", at: "2026-10-03T07:00:00Z")] }
        XCTAssertEqual(store.load()?.sensors.count, 1)
    }
}
