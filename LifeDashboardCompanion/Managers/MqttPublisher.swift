import Foundation
import Network
import OSLog

/// Publishes the latest synced values to the user's MQTT broker with Home Assistant Discovery,
/// using the in-process MQTT 3.1.1 encoder over Network.framework (no third-party
/// dependencies). Connect-publish-disconnect per sync; all messages are retained so Home
/// Assistant keeps the last values across restarts. Every publish sends the whole sensor cache
/// (`MqttSensorCache`), as the Android app does. Failures never block the webhook sync; the
/// outcome is stored for display in the MQTT settings section.
final class MqttPublisher: @unchecked Sendable {
    static let shared = MqttPublisher()
    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "Mqtt")
    private let queue = DispatchQueue(label: "com.owen282000.lifedashboard.mqtt")
    private let store = MqttSensorStore.shared

    private init() {}

    /// Returns the error when the broker could not be reached, nil when the sensors went out or
    /// there was nothing to publish. The fresh values join the cache, and the whole cache goes
    /// out; a payload without a sensor publishes only when the cache is owed to the broker.
    /// `freshIsNewest` is for Sync Now, whose payload holds each type's newest records: its
    /// values replace the cached ones even when they are older (`MqttSensorCache.merged`).
    @discardableResult
    func publish(healthPayload: [String: Any], freshIsNewest: Bool = false) async -> String? {
        let prefs = PreferencesManager.shared
        guard prefs.mqttConfigured else {
            store.clear()
            return nil
        }

        let today = today()
        let fresh = await MqttSupport.sensors(from: withTodaysTotals(healthPayload, prefs: prefs), today: today)
        let target = target(prefs)
        // A cache that cannot be read yet, which takes an iPhone not unlocked since a restart and
        // so a HealthKit that cannot be read either, is left as it is: the fresh values go out
        // alone, and once it reads again a publish may send an older cached value until the
        // next record of its type.
        let planned: (sensors: [MqttSensor], pending: Bool) = store.update { cache in
            let pending = cache.shouldRepublish(to: target, now: Date())
            cache.sensors = MqttSensorCache.merged(cached: cache.sensors, fresh: fresh, today: today, freshIsNewest: freshIsNewest)
            return (cache.sensors, pending)
        } ?? (fresh, false)
        guard !fresh.isEmpty || planned.pending, !planned.sensors.isEmpty else { return nil }
        return await send(planned.sensors, target: target, prefs: prefs)
    }

    /// For a sync with nothing new: publishes the cache again when the last publish failed or
    /// was cut off, or the broker, port, TLS, base topic or phone name changed since, so the
    /// broker does not wait for the next record of each type. A broker that failed is tried
    /// again after `MqttSensorCache.retryPause`, not by every wakeup. Nil when nothing was
    /// owed or it went out.
    @discardableResult
    func republishIfPending() async -> String? {
        let prefs = PreferencesManager.shared
        guard prefs.mqttConfigured else {
            store.clear()
            return nil
        }
        guard !Task.isCancelled,
              store.load()?.shouldRepublish(to: target(prefs), now: Date()) == true else { return nil }
        return await publish(healthPayload: [:])
    }

    private func target(_ prefs: PreferencesManager) -> String {
        MqttSensorCache.target(
            host: prefs.mqttHost, port: prefs.mqttPort, useTls: prefs.mqttUseTls,
            baseTopic: baseTopic(prefs), slug: MqttSupport.phoneSlug(prefs.phoneName)
        )
    }

    private func baseTopic(_ prefs: PreferencesManager) -> String {
        prefs.mqttBaseTopic.isEmpty ? MqttSupport.defaultBaseTopic : prefs.mqttBaseTopic
    }

    private func send(_ sensors: [MqttSensor], target: String, prefs: PreferencesManager) async -> String? {
        let baseTopic = baseTopic(prefs)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let prefix = MqttSupport.defaultDiscoveryPrefix
        let phoneName = prefs.phoneName
        let slug = MqttSupport.phoneSlug(phoneName)
        // The topics are retained, so a renamed iPhone would leave its old device on the broker
        // with frozen values. The first publish after a rename clears it, and the slug is
        // recorded once a publish went through. An iPhone with no publish on record clears
        // nothing, since the nameless topics may be another iPhone's. The sensors 1.4.1 and
        // earlier published for
        // the latest steps, distance and calories record are cleared on every publish, as Android
        // does, so Home Assistant drops them wherever they were left.
        let renamed = !prefs.mqttHasPublished ? [] : MqttSupport.topicsToClearOnRename(
            baseTopic: baseTopic,
            discoveryPrefix: prefix,
            keys: MqttSupport.allSensorKeys + MqttSupport.retiredSensorKeys,
            previousSlug: prefs.mqttPublishedSlug,
            currentSlug: slug
        )
        let clearFirst = renamed + MqttSupport.topicsFor(baseTopic: baseTopic, discoveryPrefix: prefix, keys: MqttSupport.retiredSensorKeys, slug: slug)

        do {
            try await withConnection(host: prefs.mqttHost, port: prefs.mqttPort, useTls: prefs.mqttUseTls) { connection in
                try await self.send(MqttPacket.connect(
                    clientId: "lifedashboard-ios-\(UUID().uuidString.prefix(8))",
                    username: prefs.mqttUsername.isEmpty ? nil : prefs.mqttUsername,
                    password: prefs.mqttPassword.isEmpty ? nil : prefs.mqttPassword
                ), over: connection)
                guard try await self.awaitConnack(over: connection) else {
                    throw MqttError.connectionRefused
                }
                // An empty retained payload removes a retained topic, and on a discovery topic
                // the entity with it.
                for topic in clearFirst {
                    try await self.send(MqttPacket.publish(topic: topic, payload: Data()), over: connection)
                }
                for sensor in sensors {
                    try await self.send(MqttPacket.publish(
                        topic: MqttSupport.discoveryTopic(discoveryPrefix: prefix, key: sensor.key, slug: slug),
                        payload: MqttSupport.discoveryConfigJSON(for: sensor, baseTopic: baseTopic, appVersion: appVersion, phoneName: phoneName)
                    ), over: connection)
                    try await self.send(MqttPacket.publish(
                        topic: MqttSupport.stateTopic(baseTopic: baseTopic, key: sensor.key, slug: slug),
                        payload: Data(sensor.state.utf8)
                    ), over: connection)
                    try await self.send(MqttPacket.publish(
                        topic: MqttSupport.attributesTopic(baseTopic: baseTopic, key: sensor.key, slug: slug),
                        payload: MqttSupport.attributesJSON(for: sensor)
                    ), over: connection)
                }
                try await self.send(MqttPacket.disconnect(), over: connection)
            }
            prefs.mqttLastStatus = MqttStatus.published(sensors: sensors.count, at: Date())
            prefs.mqttPublishedSlug = slug
            store.update { $0.recordPublish(to: target, success: true, at: Date()) }
            logPublish(prefs: prefs, baseTopic: baseTopic, sensors: sensors.count, error: nil)
            return nil
        } catch where Task.isCancelled || WebhookManager.isInterruption(error, taskCancelled: false) {
            // Cancelled with the sync, as when iOS ends a background task: the broker did
            // nothing wrong, so the MQTT status keeps its last publish.
            let message = AppDiagnostic.interrupted.rawValue
            logger.info("MQTT publish interrupted")
            store.update { $0.recordPublish(to: target, success: false, at: Date()) }
            logPublish(prefs: prefs, baseTopic: baseTopic, sensors: sensors.count, error: message)
            return message
        } catch {
            let message = error.localizedDescription
            logger.error("MQTT publish failed: \(message)")
            prefs.mqttLastStatus = MqttStatus.failed(message)
            store.update { $0.recordPublish(to: target, success: false, at: Date()) }
            logPublish(prefs: prefs, baseTopic: baseTopic, sensors: sensors.count, error: message)
            return message
        }
    }

    /// The syncs hand MQTT the records alone, without the payload's daily totals (and with Daily
    /// totals in payload switched off there are none), so today's totals are read here: one
    /// statistics query per enabled type, for today only. A payload that carries
    /// `daily_totals` is used as it is.
    private func withTodaysTotals(_ payload: [String: Any], prefs: PreferencesManager) async -> [String: Any] {
        guard payload[DailyTotals.payloadKey] == nil else { return payload }
        let calendar = DailyTotals.calendar()
        let totals = await HealthKitManager.shared.readDailyTotals(
            in: DailyTotals.window(days: 0, calendar: calendar),
            enabledTypes: prefs.healthEnabledDataTypes,
            calendar: calendar
        )
        var copy = payload
        if !totals.isEmpty { copy[DailyTotals.payloadKey] = totals }
        return copy
    }

    private func today() -> String {
        DailyTotals.dateString(Date(), calendar: DailyTotals.calendar())
    }

    /// One Logs tab row per publish, shaped like Android's: the broker and topic as the URL,
    /// the sensor count as the record count, no payload.
    private func logPublish(prefs: PreferencesManager, baseTopic: String, sensors: Int, error: String?) {
        prefs.addWebhookLog(WebhookLog(
            url: "mqtt://\(prefs.mqttHost):\(prefs.mqttPort)/\(baseTopic)",
            success: error == nil,
            errorMessage: error,
            dataType: "mqtt",
            recordCount: sensors,
            logType: .healthConnect,
            destination: .mqtt
        ))
    }

    // MARK: - Connection plumbing

    private enum MqttError: LocalizedError {
        case invalidPort
        case timeout
        case connectionRefused
        case connectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPort: return AppDiagnostic.brokerInvalidPort.rawValue
            case .timeout: return AppDiagnostic.brokerTimeout.rawValue
            case .connectionRefused: return AppDiagnostic.brokerRefused.rawValue
            case .connectionFailed(let detail): return detail
            }
        }
    }

    private func withConnection(
        host: String,
        port: Int,
        useTls: Bool,
        body: @escaping @Sendable (NWConnection) async throws -> Void
    ) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            throw MqttError.invalidPort
        }
        let parameters: NWParameters = useTls ? .tls : .tcp
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        defer { connection.cancel() }

        // The waits below ignore task cancellation; cancelling the connection is what ends them,
        // with an error. Without it a broker that never answers, or a LAN address dialled from
        // outside the LAN, would hold the sync, and every sync queued behind it, for good.
        try await withTaskCancellationHandler {
            try await withTimeout(seconds: 10, onTimeout: { connection.cancel() }, operation: {
                try await self.awaitReady(connection)
                try await body(connection)
            })
        } onCancel: {
            connection.cancel()
        }
    }

    /// Ensures the ready-continuation resumes exactly once even though NWConnection may fire
    /// multiple state updates; safe to touch from concurrent contexts (Swift 6 clean).
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func tryResume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    private func awaitReady(_ connection: NWConnection) async throws {
        let guardFlag = ResumeGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guardFlag.tryResume() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    // Waiting is how a refused connection or an unknown host shows: the
                    // connection would retry only once the network changes.
                    if guardFlag.tryResume() {
                        continuation.resume(throwing: MqttError.connectionFailed(error.localizedDescription))
                    }
                case .cancelled:
                    if guardFlag.tryResume() {
                        continuation.resume(throwing: MqttError.connectionFailed(AppDiagnostic.brokerCancelled.rawValue))
                    }
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MqttError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func awaitConnack(over connection: NWConnection) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: MqttError.connectionFailed(error.localizedDescription))
                } else if let data, let accepted = MqttPacket.parseConnack(data) {
                    continuation.resume(returning: accepted)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// `onTimeout` has to make the operation return: the group waits for it before it throws.
    private func withTimeout(
        seconds: TimeInterval,
        onTimeout: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                onTimeout()
                throw MqttError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
