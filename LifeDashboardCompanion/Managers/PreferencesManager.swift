import Foundation
import HealthKit

/// @unchecked Sendable: values are backed by UserDefaults and the Keychain (both
/// thread-safe); the @Published properties are only mutated from the main thread (UI).
final class PreferencesManager: ObservableObject, @unchecked Sendable {
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
        static let healthSigningSecret = "health_signing_secret"
        static let webhookLogs = "webhook_logs"
        static let failureNotificationsEnabled = "failure_notifications_enabled"
        static let failureNotificationThreshold = "failure_notification_threshold"
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
                KeychainStore.setData(data, forKey: Keys.healthWebhookHeaders)
            }
        }
    }

    @Published var healthSigningSecret: String {
        didSet { KeychainStore.setString(healthSigningSecret, forKey: Keys.healthSigningSecret) }
    }

    @Published var failureNotificationsEnabled: Bool {
        didSet { defaults.set(failureNotificationsEnabled, forKey: Keys.failureNotificationsEnabled) }
    }

    @Published var failureNotificationThreshold: Int {
        didSet { defaults.set(failureNotificationThreshold, forKey: Keys.failureNotificationThreshold) }
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

        // Secrets live in the Keychain; migrate any values older versions kept in UserDefaults.
        if let data = KeychainStore.data(forKey: Keys.healthWebhookHeaders),
           let headers = try? JSONDecoder().decode([String: String].self, from: data) {
            self.healthWebhookHeaders = headers
        } else if let data = defaults.data(forKey: Keys.healthWebhookHeaders),
                  let headers = try? JSONDecoder().decode([String: String].self, from: data) {
            self.healthWebhookHeaders = headers
            KeychainStore.setData(data, forKey: Keys.healthWebhookHeaders)
            defaults.removeObject(forKey: Keys.healthWebhookHeaders)
        } else {
            self.healthWebhookHeaders = [:]
        }

        self.failureNotificationsEnabled = defaults.object(forKey: Keys.failureNotificationsEnabled) as? Bool ?? true
        self.failureNotificationThreshold = defaults.object(forKey: Keys.failureNotificationThreshold) as? Int ?? 3

        if let secret = KeychainStore.string(forKey: Keys.healthSigningSecret) {
            self.healthSigningSecret = secret
        } else if let secret = defaults.string(forKey: Keys.healthSigningSecret) {
            self.healthSigningSecret = secret
            KeychainStore.setString(secret, forKey: Keys.healthSigningSecret)
            defaults.removeObject(forKey: Keys.healthSigningSecret)
        } else {
            self.healthSigningSecret = ""
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

    // MARK: - Webhook Logs (stored in protected files, see LogStore)

    func getWebhookLogs(filterType: LogType? = nil) -> [WebhookLog] {
        LogStore.shared.load(filterType: filterType)
    }

    func addWebhookLog(_ log: WebhookLog) {
        LogStore.shared.add(log)
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    func clearWebhookLogs(filterType: LogType? = nil) {
        LogStore.shared.clear(filterType: filterType)
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    func deleteWebhookLog(id: String) {
        LogStore.shared.delete(id: id)
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
}
