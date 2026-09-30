import Foundation
import Network
import OSLog

/// Publishes the latest synced values to the user's MQTT broker with Home Assistant
/// Discovery, using the in-process MQTT 3.1.1 encoder over Network.framework (no third-party
/// dependencies). Connect-publish-disconnect per sync; all messages are retained so Home
/// Assistant keeps the last values across restarts. Failures never block the webhook sync;
/// the outcome is stored for display in the MQTT settings section.
final class MqttPublisher: @unchecked Sendable {
    static let shared = MqttPublisher()
    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "Mqtt")
    private let queue = DispatchQueue(label: "com.owen282000.lifedashboard.mqtt")

    private init() {}

    /// Returns the error when the broker could not be reached, nil when the sensors went out or
    /// there was nothing to publish.
    @discardableResult
    func publish(healthPayload: [String: Any]) async -> String? {
        let prefs = PreferencesManager.shared
        guard prefs.mqttConfigured else { return nil }

        let sensors = MqttSupport.sensors(from: healthPayload)
        guard !sensors.isEmpty else { return nil }

        let baseTopic = prefs.mqttBaseTopic.isEmpty ? MqttSupport.defaultBaseTopic : prefs.mqttBaseTopic
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

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
                for sensor in sensors {
                    try await self.send(MqttPacket.publish(
                        topic: MqttSupport.discoveryTopic(discoveryPrefix: MqttSupport.defaultDiscoveryPrefix, key: sensor.key),
                        payload: MqttSupport.discoveryConfigJSON(for: sensor, baseTopic: baseTopic, appVersion: appVersion)
                    ), over: connection)
                    try await self.send(MqttPacket.publish(
                        topic: MqttSupport.stateTopic(baseTopic: baseTopic, key: sensor.key),
                        payload: Data(sensor.state.utf8)
                    ), over: connection)
                    try await self.send(MqttPacket.publish(
                        topic: MqttSupport.attributesTopic(baseTopic: baseTopic, key: sensor.key),
                        payload: MqttSupport.attributesJSON(for: sensor)
                    ), over: connection)
                }
                try await self.send(MqttPacket.disconnect(), over: connection)
            }
            prefs.mqttLastStatus = MqttStatus.published(sensors: sensors.count, at: Date())
            logPublish(prefs: prefs, baseTopic: baseTopic, sensors: sensors.count, error: nil)
            return nil
        } catch {
            let message = error is CancellationError ? AppDiagnostic.brokerCancelled.rawValue : error.localizedDescription
            logger.error("MQTT publish failed: \(message)")
            prefs.mqttLastStatus = MqttStatus.failed(message)
            logPublish(prefs: prefs, baseTopic: baseTopic, sensors: sensors.count, error: message)
            return message
        }
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
