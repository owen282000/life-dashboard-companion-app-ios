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

    init(
        url: String,
        statusCode: Int? = nil,
        success: Bool,
        errorMessage: String? = nil,
        dataType: String? = nil,
        recordCount: Int? = nil,
        rawPayload: String? = nil,
        logType: LogType
    ) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.url = url
        self.statusCode = statusCode
        self.success = success
        self.errorMessage = errorMessage
        self.dataType = dataType
        self.recordCount = recordCount
        self.rawPayload = rawPayload
        self.logType = logType
    }
}

enum LogType: String, Codable {
    case healthConnect = "HEALTH_CONNECT"

    var displayName: String {
        switch self {
        case .healthConnect: return "Health"
        }
    }
}
