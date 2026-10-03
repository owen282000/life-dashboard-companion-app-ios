import Foundation
import HealthKit

/// @unchecked Sendable: values are backed by UserDefaults and the Keychain (both
/// thread-safe); the @Published properties are only mutated from the main thread (UI).
final class PreferencesManager: ObservableObject, @unchecked Sendable {
    static let shared = PreferencesManager()

    private let defaults: UserDefaults
    private let secrets: any SecretStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Keys

    private enum Keys {
        static let healthSyncInterval = "health_sync_interval_minutes"
        // The Android app's keys for the rest of the schedule, same text formats
        static let healthScheduleMode = "health_schedule_mode"
        static let healthScheduleTimes = "health_schedule_times"
        static let healthScheduleDays = "health_schedule_days"
        static let healthScheduleQuietFrom = "health_schedule_quiet_from"
        static let healthScheduleQuietTo = "health_schedule_quiet_to"
        static let healthScheduleLastRun = "health_schedule_last_run"
        // iOS only, sync state rather than settings
        static let healthScheduleLastSlot = "health_schedule_last_slot"
        static let healthScheduleChangedAt = "health_schedule_changed_at"
        static let healthWebhookUrls = "health_webhook_urls"
        static let healthUrlsWithoutHeaders = "health_webhook_urls_without_headers"
        static let healthEnabledDataTypes = "health_enabled_data_types"
        static let healthWebhookHeaders = "health_webhook_headers"
        static let healthSigningSecret = "health_signing_secret"
        static let includeDailyTotals = "include_daily_totals"
        static let healthSeriesResolutions = "health_series_resolutions"
        static let webhookLogs = "webhook_logs"
        static let failureNotificationsEnabled = "failure_notifications_enabled"
        static let failureNotificationThreshold = "failure_notification_threshold"
        static let mqttEnabled = "mqtt_enabled"
        static let mqttHost = "mqtt_host"
        static let mqttPort = "mqtt_port"
        static let mqttUseTls = "mqtt_use_tls"
        static let mqttUsername = "mqtt_username"
        static let mqttPassword = "mqtt_password"
        static let mqttBaseTopic = "mqtt_base_topic"
        static let mqttLastStatus = "mqtt_last_status"
        static let phoneName = "phone_name"
        static let mqttPublishedSlug = "mqtt_published_slug"
        static let clientCertificate = "client_certificate"
    }

    // MARK: - Constants

    static let defaultSyncIntervalMinutes = SyncSchedule.defaultIntervalMinutes
    static let maxLogs = 100

    // MARK: - Health Connect Settings

    /// When background syncs may run. The interval keeps its long-standing key, so an install
    /// that never opens the schedule syncs exactly as before.
    ///
    /// A real change (not the same schedule written again) stamps `changedAt`, so times earlier
    /// today do not run, and tells the background sync manager to aim its requests anew.
    @Published var healthSyncSchedule: SyncSchedule {
        didSet {
            storeSchedule(healthSyncSchedule)
            guard healthSyncSchedule.normalized != oldValue.normalized else { return }
            defaults.set(Date(), forKey: Keys.healthScheduleChangedAt)
            NotificationCenter.default.post(name: .healthSyncScheduleDidChange, object: nil)
        }
    }

    var healthSyncIntervalMinutes: Int {
        get { healthSyncSchedule.intervalMinutes }
        set { healthSyncSchedule.intervalMinutes = newValue }
    }

    /// What the schedule gate remembers: when the last scheduled sync started, the configured
    /// time it ran for, and when the schedule last changed. Written by SyncCoordinator only.
    var healthScheduleState: ScheduleState {
        get {
            ScheduleState(
                lastRun: defaults.object(forKey: Keys.healthScheduleLastRun) as? Date,
                lastSlot: (defaults.object(forKey: Keys.healthScheduleLastSlot) as? Int)
                    .map { LocalDateTime(day: 0, second: $0) },
                changedAt: defaults.object(forKey: Keys.healthScheduleChangedAt) as? Date
            )
        }
        set {
            defaults.set(newValue.lastRun, forKey: Keys.healthScheduleLastRun)
            defaults.set(newValue.lastSlot.map { $0.day * 86_400 + $0.second }, forKey: Keys.healthScheduleLastSlot)
            defaults.set(newValue.changedAt, forKey: Keys.healthScheduleChangedAt)
        }
    }

    @Published var healthWebhookUrls: [String] {
        didSet {
            if let data = try? encoder.encode(healthWebhookUrls) {
                defaults.set(data, forKey: Keys.healthWebhookUrls)
            }
            pruneUrlsWithoutHeaders()
            if healthWebhookUrls != oldValue { destinationsDidChange() }
        }
    }

    /// URLs that get none of the custom headers: the ones QR pairing added. Android's key and
    /// format, so a settings backup carries the same field on both platforms.
    @Published var healthUrlsWithoutHeaders: Set<String> {
        didSet {
            if healthUrlsWithoutHeaders.isEmpty {
                defaults.removeObject(forKey: Keys.healthUrlsWithoutHeaders)
            } else if let data = try? encoder.encode(healthUrlsWithoutHeaders.sorted()) {
                defaults.set(data, forKey: Keys.healthUrlsWithoutHeaders)
            }
        }
    }

    /// The same list read back from UserDefaults, which is thread-safe. WebhookManager reads it
    /// off the main actor at every send, while pairing or an import may be writing it.
    var storedUrlsWithoutHeaders: Set<String> {
        PreferencesManager.decodeUrls(defaults.data(forKey: Keys.healthUrlsWithoutHeaders))
    }

    private static func decodeUrls(_ data: Data?) -> Set<String> {
        guard let data, let urls = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(urls)
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
                secrets.setData(data, forKey: Keys.healthWebhookHeaders)
            }
        }
    }

    @Published var healthSigningSecret: String {
        didSet { secrets.setString(healthSigningSecret, forKey: Keys.healthSigningSecret) }
    }

    /// Same key and default as the Android app, so a settings backup maps it one to one.
    @Published var includeDailyTotals: Bool {
        didSet { defaults.set(includeDailyTotals, forKey: Keys.includeDailyTotals) }
    }

    /// Data resolution per type, stored as Android stores it: "HEART_RATE=ONE_MINUTE" pairs,
    /// only for the types not at raw, so a type that is absent sends every record.
    @Published var seriesResolutions: [HealthDataType: SeriesResolution] {
        didSet { defaults.set(PreferencesManager.formatResolutions(seriesResolutions), forKey: Keys.healthSeriesResolutions) }
    }

    /// The same setting read back from UserDefaults, which is thread-safe, for the sync and the
    /// backfill, which read it off the main actor while the screen may be writing it.
    var storedSeriesResolutions: [HealthDataType: SeriesResolution] {
        PreferencesManager.parseResolutions(defaults.string(forKey: Keys.healthSeriesResolutions))
    }

    static func formatResolutions(_ resolutions: [HealthDataType: SeriesResolution]) -> String {
        resolutions.filter { $0.value != SeriesResolution.defaultResolution }
            .map { "\($0.key.rawValue)=\($0.value.rawValue)" }
            .sorted()
            .joined(separator: ",")
    }

    /// Unknown types and anything unparseable are left out, so they read as raw.
    static func parseResolutions(_ stored: String?) -> [HealthDataType: SeriesResolution] {
        var resolutions: [HealthDataType: SeriesResolution] = [:]
        for pair in (stored ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2, let type = HealthDataType(rawValue: String(parts[0])) else { continue }
            let resolution = SeriesResolution.from(String(parts[1]))
            if resolution != .raw { resolutions[type] = resolution }
        }
        return resolutions
    }

    @Published var failureNotificationsEnabled: Bool {
        didSet { defaults.set(failureNotificationsEnabled, forKey: Keys.failureNotificationsEnabled) }
    }

    @Published var failureNotificationThreshold: Int {
        didSet { defaults.set(failureNotificationThreshold, forKey: Keys.failureNotificationThreshold) }
    }

    // MARK: - MQTT (Home Assistant Discovery); credentials live in the Keychain

    @Published var mqttEnabled: Bool {
        didSet {
            defaults.set(mqttEnabled, forKey: Keys.mqttEnabled)
            if mqttEnabled != oldValue { destinationsDidChange() }
        }
    }

    @Published var mqttHost: String {
        didSet {
            defaults.set(mqttHost, forKey: Keys.mqttHost)
            if mqttHost != oldValue { destinationsDidChange() }
        }
    }

    // MARK: - Destinations

    /// The broker counts once it is switched on and has a host, as on Android.
    var mqttConfigured: Bool {
        mqttEnabled && !mqttHost.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A webhook URL or the MQTT broker: MQTT alone is a destination of its own, as it is on
    /// Android, so a phone set up with only a broker syncs too.
    var hasHealthDestination: Bool {
        !healthWebhookUrls.isEmpty || mqttConfigured
    }

    /// Whether a sync has anywhere to go and anything to read. Sync Now, the observers at
    /// launch, the background tasks and every automatic sync ask this one question.
    var healthSyncConfigured: Bool {
        hasHealthDestination && !healthEnabledDataTypes.isEmpty
    }

    /// Lets the background sync manager start the observers and aim the background tasks when
    /// the first destination is added while the app runs, without a relaunch.
    private func destinationsDidChange() {
        NotificationCenter.default.post(name: .healthDestinationsDidChange, object: self)
    }

    @Published var mqttPort: Int {
        didSet { defaults.set(mqttPort, forKey: Keys.mqttPort) }
    }

    @Published var mqttUseTls: Bool {
        didSet { defaults.set(mqttUseTls, forKey: Keys.mqttUseTls) }
    }

    @Published var mqttUsername: String {
        didSet { secrets.setString(mqttUsername, forKey: Keys.mqttUsername) }
    }

    @Published var mqttPassword: String {
        didSet { secrets.setString(mqttPassword, forKey: Keys.mqttPassword) }
    }

    @Published var mqttBaseTopic: String {
        didSet { defaults.set(mqttBaseTopic, forKey: Keys.mqttBaseTopic) }
    }

    @Published var mqttLastStatus: String {
        didSet { defaults.set(mqttLastStatus, forKey: Keys.mqttLastStatus) }
    }

    /// The Android app's phone name: empty keeps the MQTT device and topics as they were, a name
    /// gives this iPhone its own (MqttSupport.phoneSlug).
    @Published var phoneName: String {
        didSet { defaults.set(phoneName, forKey: Keys.phoneName) }
    }

    /// The slug of the last publish that reached the broker, nil for a nameless one. Sync
    /// state, not a setting: it tells the next publish which old device to clear after a rename.
    var mqttPublishedSlug: String? {
        get { defaults.string(forKey: Keys.mqttPublishedSlug).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue ?? "", forKey: Keys.mqttPublishedSlug) }
    }

    /// Whether this iPhone has published under the slug above. Without a record it clears no
    /// old device: a second iPhone set up with a name would otherwise empty the first iPhone's
    /// nameless topics. An install from before the record published nameless when it has an
    /// MQTT status line.
    var mqttHasPublished: Bool {
        defaults.object(forKey: Keys.mqttPublishedSlug) != nil || !mqttLastStatus.isEmpty
    }

    // MARK: - Client certificate (mTLS)

    /// The imported client certificate, nil for none. Only its summary lives here; the identity
    /// is in the Keychain (ClientCertificateStore). A summary whose identity is gone, as after
    /// moving to a new iPhone through a backup, makes every webhook fail with a clear message
    /// instead of sending without the certificate.
    @Published var clientCertificate: ClientCertificateInfo? {
        didSet {
            if let clientCertificate, let data = try? encoder.encode(clientCertificate) {
                defaults.set(data, forKey: Keys.clientCertificate)
            } else {
                defaults.removeObject(forKey: Keys.clientCertificate)
            }
        }
    }

    /// The same, read from UserDefaults for WebhookManager off the main actor.
    var clientCertificateConfigured: Bool {
        defaults.data(forKey: Keys.clientCertificate) != nil
    }

    // MARK: - Init

    /// The app uses `shared`; tests pass an isolated defaults suite and an in-memory secret store.
    init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets

        self.healthSyncSchedule = PreferencesManager.loadSchedule(from: defaults)
        // An install from before the schedule counts its fixed times from its first launch with it
        if defaults.object(forKey: Keys.healthScheduleChangedAt) == nil {
            defaults.set(Date(), forKey: Keys.healthScheduleChangedAt)
        }

        if let data = defaults.data(forKey: Keys.healthWebhookUrls),
           let urls = try? JSONDecoder().decode([String].self, from: data) {
            self.healthWebhookUrls = urls
        } else {
            self.healthWebhookUrls = []
        }
        self.healthUrlsWithoutHeaders = PreferencesManager.decodeUrls(defaults.data(forKey: Keys.healthUrlsWithoutHeaders))

        if let data = defaults.data(forKey: Keys.healthEnabledDataTypes),
           let rawValues = try? JSONDecoder().decode([String].self, from: data) {
            self.healthEnabledDataTypes = Set(rawValues.compactMap { HealthDataType(rawValue: $0) })
        } else {
            self.healthEnabledDataTypes = []
        }

        // Secrets live in the Keychain; migrate any values older versions kept in UserDefaults.
        if let data = secrets.data(forKey: Keys.healthWebhookHeaders),
           let headers = try? JSONDecoder().decode([String: String].self, from: data) {
            self.healthWebhookHeaders = headers
        } else if let data = defaults.data(forKey: Keys.healthWebhookHeaders),
                  let headers = try? JSONDecoder().decode([String: String].self, from: data) {
            self.healthWebhookHeaders = headers
            secrets.setData(data, forKey: Keys.healthWebhookHeaders)
            defaults.removeObject(forKey: Keys.healthWebhookHeaders)
        } else {
            self.healthWebhookHeaders = [:]
        }

        self.failureNotificationsEnabled = defaults.object(forKey: Keys.failureNotificationsEnabled) as? Bool ?? true
        self.failureNotificationThreshold = defaults.object(forKey: Keys.failureNotificationThreshold) as? Int ?? 3

        if let secret = secrets.string(forKey: Keys.healthSigningSecret) {
            self.healthSigningSecret = secret
        } else if let secret = defaults.string(forKey: Keys.healthSigningSecret) {
            self.healthSigningSecret = secret
            secrets.setString(secret, forKey: Keys.healthSigningSecret)
            defaults.removeObject(forKey: Keys.healthSigningSecret)
        } else {
            self.healthSigningSecret = ""
        }
        self.includeDailyTotals = defaults.object(forKey: Keys.includeDailyTotals) as? Bool ?? true
        self.seriesResolutions = PreferencesManager.parseResolutions(defaults.string(forKey: Keys.healthSeriesResolutions))

        self.mqttEnabled = defaults.object(forKey: Keys.mqttEnabled) as? Bool ?? false
        self.mqttHost = defaults.string(forKey: Keys.mqttHost) ?? ""
        self.mqttPort = defaults.object(forKey: Keys.mqttPort) as? Int ?? 1883
        self.mqttUseTls = defaults.object(forKey: Keys.mqttUseTls) as? Bool ?? false
        self.mqttUsername = secrets.string(forKey: Keys.mqttUsername) ?? ""
        self.mqttPassword = secrets.string(forKey: Keys.mqttPassword) ?? ""
        self.mqttBaseTopic = defaults.string(forKey: Keys.mqttBaseTopic) ?? MqttSupport.defaultBaseTopic
        self.mqttLastStatus = defaults.string(forKey: Keys.mqttLastStatus) ?? ""
        self.phoneName = defaults.string(forKey: Keys.phoneName) ?? ""
        self.clientCertificate = defaults.data(forKey: Keys.clientCertificate)
            .flatMap { try? JSONDecoder().decode(ClientCertificateInfo.self, from: $0) }
    }

    // MARK: - Sync schedule

    private static func loadSchedule(from defaults: UserDefaults) -> SyncSchedule {
        var schedule = SyncSchedule()
        schedule.intervalMinutes = defaults.object(forKey: Keys.healthSyncInterval) as? Int
            ?? PreferencesManager.defaultSyncIntervalMinutes
        schedule.mode = defaults.string(forKey: Keys.healthScheduleMode).flatMap(SyncMode.init(rawValue:)) ?? .interval
        schedule.times = SyncSchedule.parseTimes(defaults.string(forKey: Keys.healthScheduleTimes) ?? "")
        schedule.days = SyncSchedule.parseDays(defaults.string(forKey: Keys.healthScheduleDays))
        if let from = defaults.string(forKey: Keys.healthScheduleQuietFrom).flatMap(TimeOfDay.init),
           let to = defaults.string(forKey: Keys.healthScheduleQuietTo).flatMap(TimeOfDay.init) {
            schedule.quietWindow = QuietWindow(from: from, to: to)
        }
        return schedule
    }

    private func storeSchedule(_ schedule: SyncSchedule) {
        defaults.set(schedule.intervalMinutes, forKey: Keys.healthSyncInterval)
        defaults.set(schedule.mode.rawValue, forKey: Keys.healthScheduleMode)
        defaults.set(SyncSchedule.formatTimes(schedule.times), forKey: Keys.healthScheduleTimes)
        defaults.set(SyncSchedule.formatDays(schedule.days), forKey: Keys.healthScheduleDays)
        defaults.set(schedule.quietWindow?.from.text, forKey: Keys.healthScheduleQuietFrom)
        defaults.set(schedule.quietWindow?.to.text, forKey: Keys.healthScheduleQuietTo)
    }

    // MARK: - HKQueryAnchor Persistence

    /// One anchor per HealthKit sample type: types such as total calories or blood pressure
    /// read several, and an anchor from one sample type skips the other's samples. Versions
    /// up to 1.3.0 kept one per payload type, which is still read until the first save.
    func saveAnchor(_ anchor: HKQueryAnchor, for type: HealthDataType, sampleType: HKSampleType) {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        defaults.set(data, forKey: anchorKey(type, sampleType))
    }

    func loadAnchor(for type: HealthDataType, sampleType: HKSampleType) -> HKQueryAnchor? {
        guard let data = defaults.data(forKey: anchorKey(type, sampleType))
            ?? defaults.data(forKey: "hk_anchor_\(type.rawValue)") else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func anchorKey(_ type: HealthDataType, _ sampleType: HKSampleType) -> String {
        "hk_anchor_\(type.rawValue)_\(sampleType.identifier)"
    }

    /// Where an incremental read of a type has to continue because the previous one stopped
    /// at the per-type cap. Nil when everything up to the last sync was read.
    func saveCatchUpCursor(_ date: Date?, for type: HealthDataType) {
        defaults.set(date, forKey: "hk_catchup_\(type.rawValue)")
    }

    func loadCatchUpCursor(for type: HealthDataType) -> Date? {
        defaults.object(forKey: "hk_catchup_\(type.rawValue)") as? Date
    }

    func clearAllAnchors() {
        for type in HealthDataType.allCases {
            defaults.removeObject(forKey: "hk_anchor_\(type.rawValue)")
            defaults.removeObject(forKey: "hk_catchup_\(type.rawValue)")
            for sampleType in type.hkSampleTypes {
                defaults.removeObject(forKey: anchorKey(type, sampleType))
            }
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

extension Notification.Name {
    /// Posted when the health sync schedule really changed, so background work is re-aimed.
    static let healthSyncScheduleDidChange = Notification.Name("healthSyncScheduleDidChange")
    /// Posted when a webhook URL or the MQTT broker was added, changed or removed.
    static let healthDestinationsDidChange = Notification.Name("healthDestinationsDidChange")
}
