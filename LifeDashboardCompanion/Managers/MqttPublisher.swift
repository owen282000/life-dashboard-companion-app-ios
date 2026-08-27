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

    func publish(healthPayload: [String: Any]) async {
        let prefs = PreferencesManager.shared
        guard prefs.mqttEnabled, !prefs.mqttHost.isEmpty else { return }

        let sensors = MqttSupport.sensors(from: healthPayload)
        guard !sensors.isEmpty else { return }

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
            prefs.mqttLastStatus = "OK: \(sensors.count) sensors published at \(Date().iso8601String)"
        } catch {
            logger.error("MQTT publish failed: \(error.localizedDescription)")
            prefs.mqttLastStatus = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Connection plumbing

    private enum MqttError: LocalizedError {
        case invalidPort
        case timeout
        case connectionRefused
        case connectionFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPort: return "Invalid broker port"
            case .timeout: return "Broker did not respond within 10 seconds"
            case .connectionRefused: return "Broker refused the connection (check credentials)"
            case .connectionFailed(let detail): return detail
            }
        }
    }

    private func withConnection(
        host: String,
        port: Int,
        useTls: Bool,
        body: @escaping (NWConnection) async throws -> Void
    ) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            throw MqttError.invalidPort
        }
        let parameters: NWParameters = useTls ? .tls : .tcp
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        defer { connection.cancel() }

        try await withTimeout(seconds: 10) {
            try await self.awaitReady(connection)
            try await body(connection)
        }
    }

    private func awaitReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: MqttError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    resumed = true
                    continuation.resume(throwing: MqttError.connectionFailed("Connection cancelled"))
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

    private func withTimeout(seconds: TimeInterval, operation: @escaping () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MqttError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
