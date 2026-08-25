import Foundation
import HealthKit

class PreferencesManager: ObservableObject {
    static let shared = PreferencesManager()

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Keys

    private enum Keys {
        static let healthSyncInterval = "health_sync_interval_minutes"
        static let healthWebhookUrls = "health_webhook_urls"
        static let healthEnabledDataTypes = "health_enabled_data_types"
        static let healthWebhookHeaders = "health_webhook_headers"
        static let webhookLogs = "webhook_logs"
    }

    // MARK: - Constants

    static let defaultSyncIntervalMinutes = 60
    static let maxLogs = 100

    // MARK: - Health Connect Settings

    @Published var healthSyncIntervalMinutes: Int {
        didSet { defaults.set(healthSyncIntervalMinutes, forKey: Keys.healthSyncInterval) }
    }

    @Published var healthWebhookUrls: [String] {
        didSet {
            if let data = try? encoder.encode(healthWebhookUrls) {
                defaults.set(data, forKey: Keys.healthWebhookUrls)
            }
        }
    }

    @Published var healthEnabledDataTypes: Set<HealthDataType> {
        didSet {
            let rawValues = healthEnabledDataTypes.map { $0.rawValue }
            if let data = try? encoder.encode(rawValues) {
                defaults.set(data, forKey: Keys.healthEnabledDataTypes)
            }
        }
    }

    @Published var healthWebhookHeaders: [String: String] {
        didSet {
            if let data = try? encoder.encode(healthWebhookHeaders) {
                defaults.set(data, forKey: Keys.healthWebhookHeaders)
            }
        }
    }

    // MARK: - Init

    private init() {
        self.healthSyncIntervalMinutes = defaults.object(forKey: Keys.healthSyncInterval) as? Int
            ?? PreferencesManager.defaultSyncIntervalMinutes

        if let data = defaults.data(forKey: Keys.healthWebhookUrls),
           let urls = try? JSONDecoder().decode([String].self, from: data) {
            self.healthWebhookUrls = urls
        } else {
            self.healthWebhookUrls = []
        }

        if let data = defaults.data(forKey: Keys.healthEnabledDataTypes),
           let rawValues = try? JSONDecoder().decode([String].self, from: data) {
            self.healthEnabledDataTypes = Set(rawValues.compactMap { HealthDataType(rawValue: $0) })
        } else {
            self.healthEnabledDataTypes = []
        }

        if let data = defaults.data(forKey: Keys.healthWebhookHeaders),
           let headers = try? JSONDecoder().decode([String: String].self, from: data) {
            self.healthWebhookHeaders = headers
        } else {
            self.healthWebhookHeaders = [:]
        }

    }

    // MARK: - HKQueryAnchor Persistence

    func saveAnchor(_ anchor: HKQueryAnchor, for type: HealthDataType) {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        defaults.set(data, forKey: "hk_anchor_\(type.rawValue)")
    }

    func loadAnchor(for type: HealthDataType) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: "hk_anchor_\(type.rawValue)") else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    func clearAllAnchors() {
        for type in HealthDataType.allCases {
            defaults.removeObject(forKey: "hk_anchor_\(type.rawValue)")
        }
    }

    // MARK: - Webhook Logs

    func getWebhookLogs(filterType: LogType? = nil) -> [WebhookLog] {
        guard let data = defaults.data(forKey: Keys.webhookLogs),
              var logs = try? decoder.decode([WebhookLog].self, from: data) else {
            return []
        }
        if let filterType = filterType {
            logs = logs.filter { $0.logType == filterType }
        }
        return logs
    }

    func addWebhookLog(_ log: WebhookLog) {
        var logs = getWebhookLogs()
        logs.insert(log, at: 0)
        if logs.count > PreferencesManager.maxLogs {
            logs = Array(logs.prefix(PreferencesManager.maxLogs))
        }
        if let data = try? encoder.encode(logs) {
            defaults.set(data, forKey: Keys.webhookLogs)
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    func clearWebhookLogs(filterType: LogType? = nil) {
        if let filterType = filterType {
            var logs = getWebhookLogs()
            logs.removeAll { $0.logType == filterType }
            if let data = try? encoder.encode(logs) {
                defaults.set(data, forKey: Keys.webhookLogs)
            }
        } else {
            defaults.removeObject(forKey: Keys.webhookLogs)
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    func deleteWebhookLog(id: String) {
        var logs = getWebhookLogs()
        logs.removeAll { $0.id == id }
        if let data = try? encoder.encode(logs) {
            defaults.set(data, forKey: Keys.webhookLogs)
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
}
