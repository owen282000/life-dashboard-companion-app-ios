import Foundation

/// The messages the app writes itself into the log, a sync result and the MQTT status.
///
/// They are stored in English, as Android stores them: a CSV or JSON export and a bug report
/// read the same on every phone, and the sync history groups one outage as one line after a
/// language switch. They are translated when shown, through `display(_:)`. Text from a server
/// or from iOS is shown as it was stored.
enum AppDiagnostic: String, CaseIterable {
    case healthLocked = "iPhone is locked, Health data can't be read"
    case deviceLocked = "Device locked - data encrypted"
    case serializeFailed = "Failed to serialize payload"
    case queuedForRetry = "Webhook failed - queued for retry"
    case retryFailed = "Retry failed"
    case invalidURL = "Invalid URL"
    case plainHTTPBlocked = "iOS blocks plain HTTP to this host. Use its IP address or https."
    case noResponse = "No response"
    case testPingNotBuilt = "Could not build the test ping"
    case deliveryFailed = "Delivery failed"
    case brokerInvalidPort = "Invalid broker port"
    case brokerTimeout = "Broker did not respond within 10 seconds"
    case brokerRefused = "Broker refused the connection (check credentials)"
    case brokerCancelled = "Connection cancelled"

    var localized: String {
        switch self {
        case .healthLocked, .deviceLocked: return String(localized: "iPhone is locked, Health data can't be read")
        case .serializeFailed: return String(localized: "Failed to serialize payload")
        case .queuedForRetry: return String(localized: "Webhook failed - queued for retry")
        case .retryFailed: return String(localized: "Retry failed")
        case .invalidURL: return String(localized: "Invalid URL")
        case .plainHTTPBlocked: return String(localized: "iOS blocks plain HTTP to this host. Use its IP address or https.")
        case .noResponse: return String(localized: "No response")
        case .testPingNotBuilt: return String(localized: "Could not build the test ping")
        case .deliveryFailed: return String(localized: "Delivery failed")
        case .brokerInvalidPort: return String(localized: "Invalid broker port")
        case .brokerTimeout: return String(localized: "Broker did not respond within 10 seconds")
        case .brokerRefused: return String(localized: "Broker refused the connection (check credentials)")
        case .brokerCancelled: return String(localized: "Connection cancelled")
        }
    }

    // MARK: - Messages with a value

    static func http(_ status: Int) -> String { "HTTP \(status)" }

    static func unknownAfterAttempts(_ attempts: Int) -> String {
        "Unknown error after \(attempts) attempts"
    }

    /// Takes the type's raw value, so the name is translated when shown.
    static func notReturned(_ typeRawValue: String) -> String {
        "HealthKit did not return \(typeRawValue)"
    }

    /// The text to show for a stored message: translated when the app wrote it, as stored
    /// otherwise.
    static func display(_ stored: String) -> String {
        if let known = AppDiagnostic(rawValue: stored) { return known.localized }
        if let status = number(in: stored, prefix: "HTTP ", suffix: "") {
            return String(localized: "HTTP \(status)")
        }
        if let attempts = number(in: stored, prefix: "Unknown error after ", suffix: " attempts") {
            return String(localized: "Unknown error after \(attempts) attempts")
        }
        if stored.hasPrefix("HealthKit did not return ") {
            let raw = String(stored.dropFirst("HealthKit did not return ".count))
            let name = HealthDataType(rawValue: raw).map { String(localized: $0.displayName) } ?? raw
            return String(localized: "HealthKit did not return \(name)")
        }
        return stored
    }

    private static func number(in text: String, prefix: String, suffix: String) -> Int? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix), text.count > prefix.count + suffix.count else { return nil }
        return Int(text.dropFirst(prefix.count).dropLast(suffix.count))
    }
}

/// The MQTT section's last publish, read from the English line `MqttPublisher` stores, so its
/// colour comes from what happened instead of from the words, and its text is translated.
struct MqttStatus: Equatable {
    let success: Bool
    let sensors: Int?
    let date: Date?
    let detail: String?

    init?(stored: String) {
        guard !stored.isEmpty else { return nil }
        if let match = stored.wholeMatch(of: /OK: (\d+) sensors published at (.+)/) {
            success = true
            sensors = Int(match.1)
            date = ISO8601DateFormatter().date(from: String(match.2))
            detail = nil
        } else if stored.hasPrefix("OK") {
            success = true
            sensors = nil
            date = nil
            detail = nil
        } else {
            success = false
            sensors = nil
            date = nil
            detail = stored.hasPrefix("Error: ") ? String(stored.dropFirst("Error: ".count)) : stored
        }
    }

    static func published(sensors: Int, at date: Date) -> String {
        "OK: \(sensors) sensors published at \(date.iso8601String)"
    }

    static func failed(_ detail: String) -> String { "Error: \(detail)" }

    var text: String {
        if success {
            guard let sensors else { return String(localized: "Published") }
            guard let date else { return String(localized: "\(sensors) sensors published") }
            let time = date.formatted(date: .abbreviated, time: .shortened)
            return String(localized: "\(sensors) sensors published at \(time)")
        }
        return String(localized: "Error: \(AppDiagnostic.display(detail ?? ""))")
    }
}
