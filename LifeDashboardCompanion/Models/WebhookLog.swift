import Foundation

struct WebhookLog: Codable, Identifiable {
    let id: String
    let timestamp: Date
    let url: String
    let statusCode: Int?
    let success: Bool
    let errorMessage: String?
    let dataType: String?
    let recordCount: Int?
    var rawPayload: String?
    let logType: LogType
    /// "WEBHOOK" or "MQTT", the values Android writes. Stored as a plain optional string so
    /// rows from 1.3.0 and earlier, which have no destination and are all webhooks, and rows
    /// from a newer build with a value this one does not know still decode.
    let destination: String?

    init(
        url: String,
        statusCode: Int? = nil,
        success: Bool,
        errorMessage: String? = nil,
        dataType: String? = nil,
        recordCount: Int? = nil,
        rawPayload: String? = nil,
        logType: LogType,
        destination: LogDestination = .webhook,
        id: String = UUID().uuidString,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.timestamp = timestamp
        self.url = url
        self.statusCode = statusCode
        self.success = success
        self.errorMessage = errorMessage
        self.dataType = dataType
        self.recordCount = recordCount
        self.rawPayload = rawPayload
        self.logType = logType
        self.destination = destination.rawValue
    }

    /// dataType of the row written when reading Apple Health failed before anything was sent.
    static let readFailureDataType = "health_read"

    /// dataType of the one row a backfill run writes. Its chunks are logged only when they
    /// fail, per URL, with the dataType of the backfill payload.
    static let backfillRunDataType = "health_connect_backfill_run"

    var isMqtt: Bool { syncKind == .mqtt }

    var syncKind: SyncRowKind {
        // Rows from before the marker are recognised by their missing record count: every
        // webhook row carries one, only the read failure did not.
        if dataType == WebhookLog.readFailureDataType || (destination == nil && !success && recordCount == nil) {
            return .readFailure
        }
        if dataType == WebhookLog.backfillRunDataType {
            // Stands for the chunks that went through. When a chunk failed, its own row per
            // URL is the failed delivery, so the run's row does not count a second one.
            return success ? .webhook : .other
        }
        switch destination {
        case nil, LogDestination.webhook.rawValue: return .webhook
        case LogDestination.mqtt.rawValue: return .mqtt
        default: return .other
        }
    }

    /// Only a delivered webhook row feeds the lifetime counters, as on Android: an MQTT
    /// publish counts sensors, not records.
    var countsTowardLifetime: Bool { success && syncKind == .webhook }
}

/// What a row stands for in the sync figures. A read failure sent nothing; `other` is a
/// destination from a newer build and counts nowhere.
enum SyncRowKind {
    case webhook
    case mqtt
    case readFailure
    case other
}

/// Where a row was sent, with Android's raw values.
enum LogDestination: String {
    case webhook = "WEBHOOK"
    case mqtt = "MQTT"
}

enum LogType: String, Codable {
    case healthConnect = "HEALTH_CONNECT"
}
