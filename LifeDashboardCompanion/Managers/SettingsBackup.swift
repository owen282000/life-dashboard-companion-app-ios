import Foundation

// Settings backup: the file format, the device snapshot and the import rules.
//
// Adding a setting to the backup: give it a property in SettingsSnapshot (same name as on
// PreferencesManager), a field with Android's key in the file model below, one line in
// SettingsBackup.export, one in SettingsImport.plan, and one each in backupSnapshot() and
// applyBackup(_:). The memberwise init and SettingsBackupTests fail until all of them are there.
// A setting that should not travel goes into SettingsBackup.notBackedUp with a reason.
// Settings belong in PreferencesManager: the coverage test cannot see anything stored elsewhere.

// MARK: - File model (Android's ConfigBackup.kt, key for key)

/// The settings file, shaped like the Android app's ConfigBackup so a file moves between the
/// two apps. Every field is optional: on import an absent key leaves the setting alone, and on
/// export a nil field is left out rather than written as null, which Android's decoder rejects
/// for its non-nullable keys.
struct ConfigBackup: Codable, Equatable {
    var version: Int?
    /// "ios" in files from this app. Android writes none, so absent means Android.
    var platform: String?
    /// Kept as text: Android writes fractional seconds, which iOS 17's .iso8601 decoding rejects.
    var exportedAt: String?
    var appVersion: String?
    var health: SectionConfig?
    /// Android's Screen Time section. Never applied or written, only read to tell whether the
    /// file carries secrets, the way Android's containsSecrets() does.
    var screenTime: SectionConfig?
    var mqtt: MqttConfig?
    var options: OptionsConfig?

    enum CodingKeys: String, CodingKey {
        case version, platform, health, mqtt, options
        case exportedAt = "exported_at"
        case appVersion = "app_version"
        case screenTime = "screen_time"
    }
}

struct SectionConfig: Codable, Equatable {
    var webhookUrls: [String]?
    var headers: [String: String]?
    var signingSecret: String?
    var syncIntervalMinutes: Int?
    /// The rest of the schedule in Android's text formats: "INTERVAL" or "TIMES", "07:30,21:00",
    /// "MONDAY,FRIDAY" and "22:00". Absent in a file from before Android 1.14.0.
    var syncMode: String?
    var syncTimes: String?
    var syncDays: String?
    var quietFrom: String?
    var quietTo: String?
    /// URLs that get none of the headers: the ones QR pairing added, on either app. Not a
    /// secret, so it stays in an export without secrets, as on Android.
    var urlsWithoutHeaders: [String]?

    enum CodingKeys: String, CodingKey {
        case headers
        case webhookUrls = "webhook_urls"
        case signingSecret = "signing_secret"
        case syncIntervalMinutes = "sync_interval_minutes"
        case syncMode = "sync_mode"
        case syncTimes = "sync_times"
        case syncDays = "sync_days"
        case quietFrom = "quiet_from"
        case quietTo = "quiet_to"
        case urlsWithoutHeaders = "urls_without_headers"
    }

    var containsSecrets: Bool {
        !(headers ?? [:]).isEmpty || !(signingSecret ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct BrokerConfig: Codable, Equatable {
    var host: String?
    var port: Int?
    var useTls: Bool?
    var username: String?
    var password: String?

    enum CodingKeys: String, CodingKey {
        case host, port, username, password
        case useTls = "use_tls"
    }

    var containsSecrets: Bool {
        !(username ?? "").isEmpty || !(password ?? "").isEmpty
    }
}

/// iOS has one broker, which is Android's shared one. Android's own brokers are read for the
/// secrets check and, when the health section does not use the shared broker, as the broker.
struct MqttConfig: Codable, Equatable {
    var shared: BrokerConfig?
    var healthEnabled: Bool?
    var healthUseShared: Bool?
    var healthBaseTopic: String?
    var healthOwnBroker: BrokerConfig?
    var screenTimeOwnBroker: BrokerConfig?

    enum CodingKeys: String, CodingKey {
        case shared
        case healthEnabled = "health_enabled"
        case healthUseShared = "health_use_shared"
        case healthBaseTopic = "health_base_topic"
        case healthOwnBroker = "health_own_broker"
        case screenTimeOwnBroker = "screen_time_own_broker"
    }
}

struct OptionsConfig: Codable, Equatable {
    var enabledDataTypes: [String]?
    var includeDailyTotals: Bool?
    /// Written for Android only; iOS lets App Transport Security decide.
    var allowHttpWebhooks: Bool?
    var failureNotificationThreshold: Int?
    /// iOS-only, under the name Android uses for the same preference (not in its backup yet).
    var failureNotificationsEnabled: Bool?
    /// The phone's name for MQTT (Android 1.20.0). An export writes an empty string for a phone
    /// without one, as Android does; absent, it leaves the name alone.
    var phoneName: String?

    enum CodingKeys: String, CodingKey {
        case enabledDataTypes = "enabled_data_types"
        case includeDailyTotals = "include_daily_totals"
        case allowHttpWebhooks = "allow_http_webhooks"
        case failureNotificationThreshold = "failure_notification_threshold"
        case failureNotificationsEnabled = "failure_notifications_enabled"
        case phoneName = "phone_name"
    }
}

extension ConfigBackup {
    /// Android's rule, over the whole file: an import that carries any secret replaces the
    /// broker credentials instead of keeping the ones on the device.
    var containsSecrets: Bool {
        (health?.containsSecrets ?? false) ||
            (screenTime?.containsSecrets ?? false) ||
            (mqtt?.shared?.containsSecrets ?? false) ||
            (mqtt?.healthOwnBroker?.containsSecrets ?? false) ||
            (mqtt?.screenTimeOwnBroker?.containsSecrets ?? false)
    }
}

// MARK: - Device snapshot

/// Every setting the backup carries, under the same names as on PreferencesManager. No default
/// values, so a new property breaks every place that builds one until it is filled in.
struct SettingsSnapshot: Equatable, Sendable {
    var healthWebhookUrls: [String]
    var healthWebhookHeaders: [String: String]
    var healthUrlsWithoutHeaders: Set<String>
    var healthSigningSecret: String
    var healthSyncSchedule: SyncSchedule
    var healthEnabledDataTypes: Set<HealthDataType>
    var includeDailyTotals: Bool
    var failureNotificationsEnabled: Bool
    var failureNotificationThreshold: Int
    var mqttEnabled: Bool
    var mqttHost: String
    var mqttPort: Int
    var mqttUseTls: Bool
    var mqttUsername: String
    var mqttPassword: String
    var mqttBaseTopic: String
    var phoneName: String
}

// MARK: - Export and file handling

enum SettingsBackupError: Error, Equatable {
    /// Unreadable, empty or larger than a settings file can be.
    case unreadable
    /// Not a settings file; the key path of the first bad value, when there is one.
    case notASettingsFile(String?)
}

enum SettingsBackup {
    static let currentVersion = 1
    static let platformName = "ios"
    static let plainFilename = "life-dashboard-config.json"
    static let encryptedFilename = "life-dashboard-config.encrypted.json"
    /// A real file is a few KB; the cap keeps a stray large file from being read into memory.
    static let maxFileBytes = 1_048_576

    /// Published on PreferencesManager but deliberately not carried by the backup.
    static let notBackedUp: [String: String] = [
        "mqttLastStatus": "the result of the last publish on this device",
        "clientCertificate": "the private key never leaves this iPhone's Keychain, and its name means nothing on another phone"
    ]

    /// Android splits cycle tracking into two record types where iOS has one toggle. Written
    /// under both names, since Android drops a name it does not know; read from any of them.
    private static let androidNames: [HealthDataType: [String]] = [
        .menstruation: ["MENSTRUATION_FLOW", "MENSTRUATION_PERIOD"]
    ]

    static func export(
        _ settings: SettingsSnapshot,
        includeSecrets: Bool,
        appVersion: String?,
        now: Date = Date()
    ) -> ConfigBackup {
        func secret(_ value: String) -> String? { includeSecrets && !value.isEmpty ? value : nil }
        // Android reads an absent list as empty, so an empty one is left out.
        let marked = settings.healthWebhookUrls.filter { settings.healthUrlsWithoutHeaders.contains($0) }

        return ConfigBackup(
            version: currentVersion,
            platform: platformName,
            exportedAt: ISO8601DateFormatter().string(from: now),
            appVersion: appVersion,
            health: SectionConfig(
                webhookUrls: settings.healthWebhookUrls,
                headers: includeSecrets ? settings.healthWebhookHeaders : nil,
                signingSecret: secret(settings.healthSigningSecret),
                syncIntervalMinutes: settings.healthSyncSchedule.intervalMinutes,
                syncMode: settings.healthSyncSchedule.mode.rawValue,
                syncTimes: SyncSchedule.formatTimes(settings.healthSyncSchedule.times),
                syncDays: SyncSchedule.formatDays(settings.healthSyncSchedule.days),
                quietFrom: settings.healthSyncSchedule.quietWindow?.from.text,
                quietTo: settings.healthSyncSchedule.quietWindow?.to.text,
                urlsWithoutHeaders: marked.isEmpty ? nil : marked
            ),
            mqtt: MqttConfig(
                shared: BrokerConfig(
                    host: settings.mqttHost,
                    port: settings.mqttPort,
                    useTls: settings.mqttUseTls,
                    username: secret(settings.mqttUsername),
                    password: secret(settings.mqttPassword)
                ),
                healthEnabled: settings.mqttEnabled,
                healthUseShared: true,
                healthBaseTopic: settings.mqttBaseTopic
            ),
            options: OptionsConfig(
                enabledDataTypes: dataTypeNames(settings.healthEnabledDataTypes),
                includeDailyTotals: settings.includeDailyTotals,
                // Android blocks plain HTTP unless this is on; an iPhone setup with an http://
                // URL (a local host, as ATS allows nothing else) would otherwise stop there.
                allowHttpWebhooks: settings.healthWebhookUrls.contains { $0.lowercased().hasPrefix("http://") },
                failureNotificationThreshold: settings.failureNotificationThreshold,
                failureNotificationsEnabled: settings.failureNotificationsEnabled,
                phoneName: settings.phoneName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }

    static func encode(_ backup: ConfigBackup) throws -> Data {
        let encoder = JSONEncoder()
        // Unescaped slashes keep the file readable and identical to what Android writes.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(backup)
    }

    /// A settings file: a JSON object with a whole-number version. A known key with a value of
    /// the wrong type rejects the file, unknown keys are ignored.
    static func decode(_ data: Data) throws -> ConfigBackup {
        let backup: ConfigBackup
        do {
            backup = try JSONDecoder().decode(ConfigBackup.self, from: data)
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            throw SettingsBackupError.notASettingsFile(keyPath(context.codingPath))
        } catch {
            throw SettingsBackupError.notASettingsFile(nil)
        }
        // Stricter than Android, whose decoder takes {} as an empty backup and wipes the setup.
        guard backup.version != nil else { throw SettingsBackupError.notASettingsFile(nil) }
        return backup
    }

    enum FileContents {
        case plain(ConfigBackup)
        case encrypted(Data)
    }

    static func classify(_ data: Data) throws -> FileContents {
        guard !data.isEmpty, data.count <= maxFileBytes else { throw SettingsBackupError.unreadable }
        if SettingsBackupCrypto.isEnvelope(data) { return .encrypted(data) }
        return .plain(try decode(data))
    }

    /// Reads a file picked in the document picker, capped at maxFileBytes. Coordinated, so a
    /// file in iCloud Drive that is not downloaded yet is fetched first. Blocks: call it off
    /// the main actor.
    static func readPickedFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var coordinatorError: NSError?
        var result: Result<Data, Error> = .failure(SettingsBackupError.unreadable)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            result = Result {
                let handle = try FileHandle(forReadingFrom: readURL)
                defer { try? handle.close() }
                return try handle.read(upToCount: maxFileBytes + 1) ?? Data()
            }
        }
        guard coordinatorError == nil, let data = try? result.get(), data.count <= maxFileBytes else {
            throw SettingsBackupError.unreadable
        }
        return data
    }

    private static func keyPath(_ path: [CodingKey]) -> String? {
        let keys = path.map { $0.intValue.map(String.init) ?? $0.stringValue }
        return keys.isEmpty ? nil : keys.joined(separator: ".")
    }

    // MARK: Data types

    static func dataTypeNames(_ types: Set<HealthDataType>) -> [String] {
        types.flatMap { androidNames[$0] ?? [$0.rawValue] }.sorted()
    }

    /// The types behind the names, and how many names this build does not know (dropped, as on
    /// Android, so a file from a newer version still imports).
    static func dataTypes(from names: [String]) -> (types: Set<HealthDataType>, unknown: Int) {
        var aliases: [String: HealthDataType] = ["MENSTRUATION": .menstruation]
        for (type, names) in androidNames {
            for name in names { aliases[name] = type }
        }
        var types = Set<HealthDataType>()
        var unknown = Set<String>()
        for name in names {
            if let type = HealthDataType(rawValue: name) ?? aliases[name] {
                types.insert(type)
            } else {
                unknown.insert(name)
            }
        }
        return (types, unknown.count)
    }

    // MARK: Hosts

    /// Android's MqttSupport.isPrivateHost: a LAN, loopback, link-local or Tailscale address, or a
    /// name without a dot or with a local suffix. By name only, no DNS lookup.
    static func isPrivateHost(_ host: String) -> Bool {
        var name = host.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasPrefix("[") && name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.hasSuffix(".") { name = String(name.dropLast()) }
        if name.isEmpty || name == "localhost" { return true }
        if name.contains(":") {
            return name == "::1" || name.hasPrefix("fc") || name.hasPrefix("fd") ||
                ["fe8", "fe9", "fea", "feb"].contains { name.hasPrefix($0) }
        }
        let octets = name.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        if octets.count == 4, octets.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 256) <= 255 }) {
            let first = octets[0] ?? 0, second = octets[1] ?? 0
            return first == 10 || first == 127 || (first == 172 && (16...31).contains(second)) ||
                (first == 192 && second == 168) || (first == 169 && second == 254) ||
                (first == 100 && (64...127).contains(second))
        }
        if !name.contains(".") { return true }
        return [".local", ".lan", ".home", ".internal", ".home.arpa", ".localdomain", ".ts.net"]
            .contains { name.hasSuffix($0) }
    }

    /// HTTPS anywhere, plain HTTP only inside the network. Everything else is not a webhook.
    static func isAllowedWebhookURL(_ text: String) -> Bool {
        guard let components = URLComponents(string: text),
              let host = components.host, !host.isEmpty else { return false }
        switch components.scheme?.lowercased() {
        case "https": return true
        case "http": return isPrivateHost(host)
        default: return false
        }
    }
}

// MARK: - Import

/// Something the import preview tells the user about what happens beyond a plain copy.
enum ImportNote: Equatable, Sendable {
    case newerVersion
    case skippedUrl(String)
    case headersKept
    case signingSecretKept
    case brokerCredentialsKept
    case brokerCredentialsCleared
    case baseTopicTranslated(String)
    case unavailableTypes(Int)
    case intervalAdjusted(Int)
    case thresholdAdjusted(from: Int, to: Int)
    case screenTimeSkipped
    case plainMqttToPublicHost

    var text: String {
        switch self {
        case .newerVersion:
            return String(localized: "Made with a newer version. Settings this version does not know are skipped.")
        case .skippedUrl(let url):
            return String(localized: "Skipped \(url): iPhone only sends plain HTTP inside your network.")
        case .headersKept:
            return String(localized: "This file has no custom headers. The ones on this iPhone are kept, for the addresses they were already sent to.")
        case .signingSecretKept:
            return String(localized: "The signing secret on this iPhone is kept.")
        case .brokerCredentialsKept:
            return String(localized: "The MQTT username and password on this iPhone are kept.")
        case .brokerCredentialsCleared:
            return String(localized: "The MQTT username and password are cleared, because the broker is different.")
        case .baseTopicTranslated(let topic):
            return String(localized: "MQTT topic becomes \(topic), so this iPhone and the Android phone do not share sensors.")
        case .unavailableTypes(let count):
            return String(localized: "\(count) data types in this file are not available on iPhone.")
        case .intervalAdjusted(let minutes):
            return String(localized: "Sync interval set to \(minutes) min, the nearest this app allows.")
        case .thresholdAdjusted(let from, let to):
            return String(localized: "Failure alert after \(from) failed syncs becomes \(to) (iPhone offers 3, 5 or 10).")
        case .screenTimeSkipped:
            return String(localized: "Screen Time settings are skipped.")
        case .plainMqttToPublicHost:
            return String(localized: "Without TLS your data and broker password cross the internet unencrypted.")
        }
    }
}

struct ImportPlan: Equatable, Sendable {
    /// The device settings after the import.
    let result: SettingsSnapshot
    let notes: [ImportNote]
    let includesSecrets: Bool
    /// "ios", or nil for a file from the Android app.
    let platform: String?
    let appVersion: String?
    let exportedAt: Date?
}

enum SettingsImport {
    static let maxWebhookUrls = 20
    static let maxUrlLength = 2048
    static let maxHeaders = 32
    static let maxHeaderValueLength = 8192
    static let maxSecretLength = 1024
    static let intervalRange = 15...1440
    static let thresholdChoices = [3, 5, 10]
    static let maxPhoneNameLength = 64

    /// The device settings after importing `file`, and what the preview should say. Pure: it
    /// validates the whole file and writes nothing, so a file with one bad value changes nothing.
    static func plan(_ file: ConfigBackup, current: SettingsSnapshot) throws -> ImportPlan {
        guard let version = file.version else { throw SettingsBackupError.notASettingsFile(nil) }
        var result = current
        var notes: [ImportNote] = []
        if version > SettingsBackup.currentVersion { notes.append(.newerVersion) }
        let fromIPhone = file.platform == SettingsBackup.platformName

        if let health = file.health {
            try planHealth(health, current: current, result: &result, notes: &notes)
        }
        if !fromIPhone, !(file.screenTime?.webhookUrls ?? []).isEmpty {
            notes.append(.screenTimeSkipped)
        }
        if let mqtt = file.mqtt {
            try planMqtt(mqtt, fileHasSecrets: file.containsSecrets, fromIPhone: fromIPhone,
                         current: current, result: &result, notes: &notes)
        }
        if let options = file.options {
            planOptions(options, fromIPhone: fromIPhone, result: &result, notes: &notes)
        }

        return ImportPlan(
            result: result,
            notes: notes,
            includesSecrets: file.containsSecrets,
            platform: file.platform,
            appVersion: file.appVersion.map { String($0.prefix(64)) },
            exportedAt: file.exportedAt.flatMap(parseDate)
        )
    }

    private static func planHealth(
        _ health: SectionConfig,
        current: SettingsSnapshot,
        result: inout SettingsSnapshot,
        notes: inout [ImportNote]
    ) throws {
        if let urls = health.webhookUrls {
            guard urls.count <= maxWebhookUrls else { throw invalid("health.webhook_urls") }
            var accepted: [String] = []
            for raw in urls {
                let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard url.count <= maxUrlLength else { throw invalid("health.webhook_urls") }
                if SettingsBackup.isAllowedWebhookURL(url) {
                    if !accepted.contains(url) { accepted.append(url) }
                } else {
                    notes.append(.skippedUrl(URLComponents(string: url)?.host ?? url))
                }
            }
            result.healthWebhookUrls = accepted
        }

        let headers = health.headers ?? [:]
        try validateHeaders(headers)
        let keepsDeviceHeaders = headers.isEmpty && !current.healthWebhookHeaders.isEmpty
        if !headers.isEmpty {
            result.healthWebhookHeaders = headers
        } else if keepsDeviceHeaders {
            notes.append(.headersKept)
        }
        result.healthUrlsWithoutHeaders = urlsWithoutHeaders(
            health, keepsDeviceHeaders: keepsDeviceHeaders, current: current, urls: result.healthWebhookUrls
        )

        let secret = (health.signingSecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            guard secret.count <= maxSecretLength else { throw invalid("health.signing_secret") }
            result.healthSigningSecret = secret
        } else if !current.healthSigningSecret.isEmpty {
            notes.append(.signingSecretKept)
        }

        if let minutes = health.syncIntervalMinutes {
            let clamped = min(max(minutes, intervalRange.lowerBound), intervalRange.upperBound)
            if clamped != minutes { notes.append(.intervalAdjusted(clamped)) }
            result.healthSyncSchedule.intervalMinutes = clamped
        }
        restoreSchedule(health, into: &result.healthSyncSchedule)
    }

    /// Android's ConfigBackupManager.restoreSchedule. A file from before the schedule carries
    /// none of its fields and leaves it alone, the interval aside. Otherwise a field the file has
    /// replaces the device's, a mode this build does not know keeps the device's, and the quiet
    /// hours are the file's: none unless it has both ends.
    private static func restoreSchedule(_ health: SectionConfig, into schedule: inout SyncSchedule) {
        guard health.syncMode != nil || health.syncTimes != nil || health.syncDays != nil ||
            health.quietFrom != nil || health.quietTo != nil else { return }
        if let mode = health.syncMode.flatMap(SyncMode.init(rawValue:)) { schedule.mode = mode }
        if let times = health.syncTimes { schedule.times = SyncSchedule.parseTimes(times) }
        if let days = health.syncDays { schedule.days = SyncSchedule.parseDays(days) }
        if let from = health.quietFrom.flatMap(TimeOfDay.init), let to = health.quietTo.flatMap(TimeOfDay.init) {
            schedule.quietWindow = QuietWindow(from: from, to: to)
        } else {
            schedule.quietWindow = nil
        }
    }

    /// Android's SectionConfig.urlsWithoutHeadersOnImport. Headers in the file were set for its
    /// own URLs, so its own list holds. A file without headers keeps the ones on the device,
    /// which were set for the device's URLs: an imported URL they did not go to before gets none
    /// of them now either. A file without URLs leaves the device's URLs, and their marks, alone.
    private static func urlsWithoutHeaders(
        _ health: SectionConfig,
        keepsDeviceHeaders: Bool,
        current: SettingsSnapshot,
        urls: [String]
    ) -> Set<String> {
        let listed = Set((health.urlsWithoutHeaders ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard health.webhookUrls != nil else {
            return current.healthUrlsWithoutHeaders.union(listed).intersection(urls)
        }
        return Set(urls.filter { url in
            listed.contains(url) ||
                (keepsDeviceHeaders &&
                    (!current.healthWebhookUrls.contains(url) || current.healthUrlsWithoutHeaders.contains(url)))
        })
    }

    private static func planMqtt(
        _ mqtt: MqttConfig,
        fileHasSecrets: Bool,
        fromIPhone: Bool,
        current: SettingsSnapshot,
        result: inout SettingsSnapshot,
        notes: inout [ImportNote]
    ) throws {
        if let enabled = mqtt.healthEnabled { result.mqttEnabled = enabled }

        // Host, port, TLS and credentials always come from the same broker.
        let brokerKey = (mqtt.healthUseShared ?? true) ? "shared" : "health_own_broker"
        if let broker = (mqtt.healthUseShared ?? true) ? mqtt.shared : mqtt.healthOwnBroker {
            if let host = broker.host?.trimmingCharacters(in: .whitespaces) {
                guard isValidBrokerHost(host) else { throw invalid("mqtt.\(brokerKey).host") }
                result.mqttHost = host
            }
            if let port = broker.port {
                guard (1...65_535).contains(port) else { throw invalid("mqtt.\(brokerKey).port") }
                result.mqttPort = port
            }
            if let useTls = broker.useTls { result.mqttUseTls = useTls }

            // Android's rule: credentials stay only for the same broker, and never go out in
            // plain text where they had TLS.
            let sameBroker = !current.mqttHost.isEmpty &&
                current.mqttHost.trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(result.mqttHost) == .orderedSame &&
                current.mqttPort == result.mqttPort && current.mqttUseTls == result.mqttUseTls
            let hadCredentials = !current.mqttUsername.isEmpty || !current.mqttPassword.isEmpty
            if !fileHasSecrets && sameBroker {
                if hadCredentials { notes.append(.brokerCredentialsKept) }
            } else {
                result.mqttUsername = broker.username ?? ""
                result.mqttPassword = broker.password ?? ""
                if hadCredentials && !broker.containsSecrets { notes.append(.brokerCredentialsCleared) }
            }
        }

        if let topic = mqtt.healthBaseTopic?.trimmingCharacters(in: .whitespaces), !topic.isEmpty {
            guard topic.count <= 256, !topic.contains(where: { $0 == "+" || $0 == "#" || $0 == "\0" }) else {
                throw invalid("mqtt.health_base_topic")
            }
            // Android's default topic would put both phones' sensors on the same state topics.
            if !fromIPhone && topic == "lifedashboard" {
                result.mqttBaseTopic = MqttSupport.defaultBaseTopic
                notes.append(.baseTopicTranslated(MqttSupport.defaultBaseTopic))
            } else {
                result.mqttBaseTopic = topic
            }
        }

        if result.mqttEnabled && !result.mqttUseTls && !result.mqttHost.isEmpty &&
            !SettingsBackup.isPrivateHost(result.mqttHost) {
            notes.append(.plainMqttToPublicHost)
        }
    }

    private static func planOptions(_ options: OptionsConfig, fromIPhone: Bool, result: inout SettingsSnapshot, notes: inout [ImportNote]) {
        if let names = options.enabledDataTypes {
            let (types, unknown) = SettingsBackup.dataTypes(from: names)
            result.healthEnabledDataTypes = types
            if unknown > 0 { notes.append(.unavailableTypes(unknown)) }
        }
        if let include = options.includeDailyTotals { result.includeDailyTotals = include }
        if let threshold = options.failureNotificationThreshold {
            // The picker offers 3, 5 and 10; the nearest, the lower one on a tie.
            let snapped = thresholdChoices.min { abs($0 - threshold) < abs($1 - threshold) } ?? 3
            if snapped != threshold { notes.append(.thresholdAdjusted(from: threshold, to: snapped)) }
            result.failureNotificationThreshold = snapped
        }
        if let enabled = options.failureNotificationsEnabled { result.failureNotificationsEnabled = enabled }
        // An Android phone's name names that phone. On the iPhone it would publish a device
        // called after it, next to the Android phone's own, so only a file from an iPhone
        // brings a name.
        if fromIPhone, let name = options.phoneName {
            result.phoneName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxPhoneNameLength))
        }
    }

    /// Header names are HTTP tokens and values carry no line breaks: a header from a file must
    /// not be able to smuggle a second header into a request.
    private static func validateHeaders(_ headers: [String: String]) throws {
        guard headers.count <= maxHeaders else { throw invalid("health.headers") }
        let tokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$%&'*+-.^_`|~"))
        for (name, value) in headers {
            let nameIsToken = !name.isEmpty && name.count <= 256 && name.unicodeScalars.allSatisfy {
                $0.isASCII && tokenCharacters.contains($0)
            }
            let valueIsClean = value.count <= maxHeaderValueLength && !value.unicodeScalars.contains {
                $0 == "\r" || $0 == "\n" || $0 == "\0"
            }
            guard nameIsToken, valueIsClean else { throw invalid("health.headers") }
        }
    }

    private static func isValidBrokerHost(_ host: String) -> Bool {
        host.count <= 253 && !host.contains("/") && !host.contains(where: \.isWhitespace)
    }

    private static func invalid(_ path: String) -> SettingsBackupError {
        .notASettingsFile(path)
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - Reading and writing the device

extension PreferencesManager {
    func backupSnapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            healthWebhookUrls: healthWebhookUrls,
            healthWebhookHeaders: healthWebhookHeaders,
            healthUrlsWithoutHeaders: healthUrlsWithoutHeaders,
            healthSigningSecret: healthSigningSecret,
            healthSyncSchedule: healthSyncSchedule,
            healthEnabledDataTypes: healthEnabledDataTypes,
            includeDailyTotals: includeDailyTotals,
            failureNotificationsEnabled: failureNotificationsEnabled,
            failureNotificationThreshold: failureNotificationThreshold,
            mqttEnabled: mqttEnabled,
            mqttHost: mqttHost,
            mqttPort: mqttPort,
            mqttUseTls: mqttUseTls,
            mqttUsername: mqttUsername,
            mqttPassword: mqttPassword,
            mqttBaseTopic: mqttBaseTopic,
            phoneName: phoneName
        )
    }

    /// Writes an imported snapshot in one synchronous pass. Secrets that change are blanked
    /// first and written last, and MQTT is off while its broker changes, so a sync running on
    /// another thread meanwhile never pairs a new host or URL with the old credentials. The
    /// addresses that get no headers are written before the URLs, as pairing writes them, so
    /// a new URL never gets headers it should not have.
    @MainActor
    func applyBackup(_ new: SettingsSnapshot) {
        let old = backupSnapshot()
        let mqttChanges = new.mqttHost != old.mqttHost || new.mqttPort != old.mqttPort ||
            new.mqttUseTls != old.mqttUseTls || new.mqttUsername != old.mqttUsername ||
            new.mqttPassword != old.mqttPassword || new.mqttBaseTopic != old.mqttBaseTopic

        if new.healthWebhookHeaders != old.healthWebhookHeaders { healthWebhookHeaders = [:] }
        if new.healthSigningSecret != old.healthSigningSecret { healthSigningSecret = "" }
        if new.mqttUsername != old.mqttUsername { mqttUsername = "" }
        if new.mqttPassword != old.mqttPassword { mqttPassword = "" }
        if mqttChanges && mqttEnabled { mqttEnabled = false }

        if new.healthUrlsWithoutHeaders != old.healthUrlsWithoutHeaders { healthUrlsWithoutHeaders = new.healthUrlsWithoutHeaders }
        if new.healthWebhookUrls != old.healthWebhookUrls { healthWebhookUrls = new.healthWebhookUrls }
        // Through the property that stamps the change and re-aims the background tasks.
        if new.healthSyncSchedule != old.healthSyncSchedule { healthSyncSchedule = new.healthSyncSchedule }
        if new.healthEnabledDataTypes != old.healthEnabledDataTypes { healthEnabledDataTypes = new.healthEnabledDataTypes }
        if new.includeDailyTotals != old.includeDailyTotals { includeDailyTotals = new.includeDailyTotals }
        if new.failureNotificationsEnabled != old.failureNotificationsEnabled { failureNotificationsEnabled = new.failureNotificationsEnabled }
        if new.failureNotificationThreshold != old.failureNotificationThreshold { failureNotificationThreshold = new.failureNotificationThreshold }
        if new.mqttHost != old.mqttHost { mqttHost = new.mqttHost }
        if new.mqttPort != old.mqttPort { mqttPort = new.mqttPort }
        if new.mqttUseTls != old.mqttUseTls { mqttUseTls = new.mqttUseTls }
        if new.mqttBaseTopic != old.mqttBaseTopic { mqttBaseTopic = new.mqttBaseTopic }
        if new.phoneName != old.phoneName { phoneName = new.phoneName }

        if new.healthWebhookHeaders != healthWebhookHeaders { healthWebhookHeaders = new.healthWebhookHeaders }
        if new.healthSigningSecret != healthSigningSecret { healthSigningSecret = new.healthSigningSecret }
        if new.mqttUsername != mqttUsername { mqttUsername = new.mqttUsername }
        if new.mqttPassword != mqttPassword { mqttPassword = new.mqttPassword }
        if new.mqttEnabled != mqttEnabled { mqttEnabled = new.mqttEnabled }
        if mqttChanges { mqttLastStatus = "" }
    }
}
