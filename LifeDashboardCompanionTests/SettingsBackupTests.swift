import Combine
import XCTest
@testable import LifeDashboardCompanion

@MainActor
final class SettingsBackupTests: XCTestCase {
    /// A PreferencesManager on its own defaults suite and secret store, as on a fresh install.
    private func makePrefs() -> PreferencesManager {
        let name = "settings-backup-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return PreferencesManager(defaults: UserDefaults(suiteName: name)!, secrets: InMemorySecretStore())
    }

    /// Differs from a fresh install in every field, so a round trip proves each one travels.
    private let fixture = SettingsSnapshot(
        healthWebhookUrls: ["https://example.com/health", "http://homeassistant.local:8123/api/webhook/abc"],
        healthWebhookHeaders: ["Authorization": "Bearer fixture-token", "X-Api-Key": "fixture-key"],
        healthUrlsWithoutHeaders: ["http://homeassistant.local:8123/api/webhook/abc"],
        healthSigningSecret: "fixture-hmac",
        healthSyncSchedule: SyncSchedule(
            mode: .times,
            intervalMinutes: 30,
            times: [TimeOfDay("07:30")!, TimeOfDay("21:00")!],
            days: [.monday, .tuesday, .wednesday, .thursday, .friday],
            quietWindow: QuietWindow(from: TimeOfDay("22:00")!, to: TimeOfDay("07:00")!)
        ),
        // Includes the six types added for Android parity, so their raw values travel too.
        healthEnabledDataTypes: [
            .steps, .heartRate, .menstruation, .vo2Max, .basalBodyTemperature,
            .intermenstrualBleeding, .ovulationTest, .cervicalMucus, .sexualActivity
        ],
        includeDailyTotals: false,
        failureNotificationsEnabled: false,
        failureNotificationThreshold: 10,
        mqttEnabled: true,
        mqttHost: "mqtt.example.com",
        mqttPort: 8883,
        mqttUseTls: true,
        mqttUsername: "fixture-user",
        mqttPassword: "fixture-pass",
        mqttBaseTopic: "home/iphone"
    )

    private func file(_ json: String) throws -> ConfigBackup {
        try SettingsBackup.decode(Data(json.utf8))
    }

    private func roundTrip(_ settings: SettingsSnapshot, includeSecrets: Bool, into target: SettingsSnapshot) throws -> ImportPlan {
        let data = try SettingsBackup.encode(SettingsBackup.export(settings, includeSecrets: includeSecrets, appVersion: "1.4.0"))
        return try SettingsImport.plan(SettingsBackup.decode(data), current: target)
    }

    // MARK: - Coverage

    /// When this fails after a rebase: a setting was added to PreferencesManager without being
    /// added to the backup. Add it to SettingsSnapshot and the lines listed at the top of
    /// SettingsBackup.swift, or to SettingsBackup.notBackedUp with the reason it stays behind.
    func testEveryPublishedSettingIsBackedUpOrDeliberatelyLeftOut() {
        let published = Set(Mirror(reflecting: makePrefs()).children.compactMap { child -> String? in
            guard let label = child.label, String(describing: type(of: child.value)).hasPrefix("Published<") else { return nil }
            return String(label.dropFirst())
        })
        XCTAssertFalse(published.isEmpty, "Mirror no longer sees the @Published properties")
        let backedUp = Set(Mirror(reflecting: fixture).children.compactMap(\.label))
        let excluded = Set(SettingsBackup.notBackedUp.keys)

        XCTAssertEqual(published.subtracting(backedUp).subtracting(excluded), [], "Not in the backup and not in notBackedUp")
        XCTAssertEqual(backedUp.union(excluded).subtracting(published), [], "Backup names a setting PreferencesManager does not have")
        XCTAssertTrue(backedUp.isDisjoint(with: excluded))
    }

    func testFixtureDiffersFromAFreshInstallInEveryField() {
        let fresh = Mirror(reflecting: makePrefs().backupSnapshot()).children
        for (field, fixtureField) in zip(fresh, Mirror(reflecting: fixture).children) {
            XCTAssertNotEqual(String(describing: field.value), String(describing: fixtureField.value), field.label ?? "")
        }
    }

    /// Through the real PreferencesManager on both ends: every field is exported, imported and
    /// written, including the secrets in the (test) secret store.
    func testRoundTripRestoresEveryFieldOnAnotherDevice() throws {
        let source = makePrefs()
        source.applyBackup(fixture)
        XCTAssertEqual(source.backupSnapshot(), fixture)

        let target = makePrefs()
        let plan = try roundTrip(source.backupSnapshot(), includeSecrets: true, into: target.backupSnapshot())
        target.applyBackup(plan.result)
        XCTAssertEqual(target.backupSnapshot(), fixture)
        XCTAssertTrue(plan.includesSecrets)
    }

    func testRoundTripThroughTheEncryptedFile() throws {
        let plain = try SettingsBackup.encode(SettingsBackup.export(fixture, includeSecrets: true, appVersion: nil))
        let envelope = try SettingsBackupCrypto.encrypt(plain, password: "four random words here")
        guard case .encrypted(let data) = try SettingsBackup.classify(envelope) else {
            return XCTFail("An encrypted export must be recognised as one")
        }
        let decrypted = try SettingsBackup.decode(SettingsBackupCrypto.decrypt(data, password: "four random words here"))
        let target = makePrefs().backupSnapshot()
        XCTAssertEqual(try SettingsImport.plan(decrypted, current: target).result, fixture)
    }

    func testImportingYourOwnExportChangesNothing() throws {
        let plan = try roundTrip(fixture, includeSecrets: true, into: fixture)
        XCTAssertEqual(plan.result, fixture)
        XCTAssertEqual(plan.notes, [])
    }

    // MARK: - What the file looks like to Android

    func testExportFollowsAndroidsFormat() throws {
        let data = try SettingsBackup.encode(SettingsBackup.export(fixture, includeSecrets: true, appVersion: "1.4.0"))
        let text = String(bytes: data, encoding: .utf8) ?? ""
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertNil(json["screen_time"], "iOS has no Screen Time section to write")
        XCTAssertFalse(text.contains("\\/"))
        XCTAssertFalse(text.contains("null"), "Android rejects null for its non-nullable keys")
        XCTAssertTrue(text.contains("\"sync_interval_minutes\" : 30,"), "Integers must not be written as decimals")

        let health = try XCTUnwrap(json["health"] as? [String: Any])
        XCTAssertEqual(health["webhook_urls"] as? [String], fixture.healthWebhookUrls)
        XCTAssertEqual(health["urls_without_headers"] as? [String], ["http://homeassistant.local:8123/api/webhook/abc"])
        XCTAssertEqual(health["sync_mode"] as? String, "TIMES")
        XCTAssertEqual(health["sync_times"] as? String, "07:30,21:00")
        XCTAssertEqual(health["sync_days"] as? String, "MONDAY,TUESDAY,WEDNESDAY,THURSDAY,FRIDAY")
        XCTAssertEqual(health["quiet_from"] as? String, "22:00")
        XCTAssertEqual(health["quiet_to"] as? String, "07:00")
        for key in ["last_run", "last_slot", "changed_at"] {
            XCTAssertFalse(text.contains(key), "\(key) is sync state, not a setting")
        }
        let mqtt = try XCTUnwrap(json["mqtt"] as? [String: Any])
        XCTAssertEqual(mqtt["health_use_shared"] as? Bool, true)
        XCTAssertEqual((mqtt["shared"] as? [String: Any])?["host"] as? String, "mqtt.example.com")
        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(options["enabled_data_types"] as? [String], [
            "BASAL_BODY_TEMPERATURE", "CERVICAL_MUCUS", "HEART_RATE", "INTERMENSTRUAL_BLEEDING", "MENSTRUATION_FLOW",
            "MENSTRUATION_PERIOD", "OVULATION_TEST", "SEXUAL_ACTIVITY", "STEPS", "VO2_MAX"
        ])
        XCTAssertEqual(options["include_daily_totals"] as? Bool, false)
        XCTAssertEqual(options["allow_http_webhooks"] as? Bool, true)
        XCTAssertEqual(options["failure_notifications_enabled"] as? Bool, false)
    }

    func testAllowHttpIsOnlyWrittenForAnHttpUrl() {
        var settings = fixture
        settings.healthWebhookUrls = ["https://example.com/health"]
        XCTAssertEqual(SettingsBackup.export(settings, includeSecrets: false, appVersion: nil).options?.allowHttpWebhooks, false)
    }

    func testExportWithoutSecretsLeavesThemOut() throws {
        let data = try SettingsBackup.encode(SettingsBackup.export(fixture, includeSecrets: false, appVersion: nil))
        let text = String(bytes: data, encoding: .utf8) ?? ""
        for secret in ["fixture-token", "fixture-key", "fixture-hmac", "fixture-user", "fixture-pass", "\"headers\"", "signing_secret", "username", "password"] {
            XCTAssertFalse(text.contains(secret), "\(secret) leaked into an export without secrets")
        }
        XCTAssertTrue(text.contains("https://example.com/health"))
        XCTAssertTrue(text.contains("urls_without_headers"), "Not a secret: Android keeps it in an export without secrets")
    }

    // MARK: - Files from Android

    func testImportsAFileFromTheAndroidApp() throws {
        let plan = try SettingsImport.plan(file(AndroidFixtures.plain), current: makePrefs().backupSnapshot())
        let result = plan.result

        XCTAssertEqual(result.healthWebhookUrls, ["https://example.com/health", "https://ha.example.com/api/webhook/abc"])
        // The headers come along, and so does the list of URLs Android keeps them away from.
        XCTAssertEqual(result.healthWebhookHeaders, ["Authorization": "Bearer token123"])
        XCTAssertEqual(result.healthUrlsWithoutHeaders, ["https://ha.example.com/api/webhook/abc"])
        XCTAssertEqual(result.healthSigningSecret, "hmac-secret")
        XCTAssertEqual(result.healthSyncSchedule.intervalMinutes, 30)
        XCTAssertEqual(result.healthSyncSchedule.mode, .times)
        XCTAssertEqual(result.healthSyncSchedule.times.map(\.text), ["07:30", "21:00"])
        XCTAssertEqual(result.healthSyncSchedule.days, [.monday, .tuesday, .wednesday, .thursday, .friday])
        XCTAssertNil(result.healthSyncSchedule.quietWindow)
        XCTAssertEqual(result.healthEnabledDataTypes, [.steps, .heartRate, .menstruation])
        XCTAssertTrue(result.includeDailyTotals)
        XCTAssertTrue(plan.notes.contains(.unavailableTypes(1)), "BONE_MASS has no iPhone counterpart")
        XCTAssertEqual(result.mqttEnabled, true)
        XCTAssertEqual(result.mqttHost, "mqtt.local")
        XCTAssertEqual(result.mqttPort, 1883)
        XCTAssertEqual(result.mqttUsername, "user")
        XCTAssertEqual(result.mqttPassword, "pass")
        XCTAssertEqual(result.mqttBaseTopic, "lifedashboard-ios")
        XCTAssertTrue(plan.notes.contains(.baseTopicTranslated("lifedashboard-ios")))
        XCTAssertTrue(plan.notes.contains(.screenTimeSkipped))
        XCTAssertEqual(result.failureNotificationThreshold, 3)
        XCTAssertNil(plan.platform)
        XCTAssertEqual(plan.appVersion, "1.21.2")
        XCTAssertNotNil(plan.exportedAt, "Android's fractional seconds must parse")
    }

    func testAndroidOwnBrokerIsTakenWhole() throws {
        let plan = try SettingsImport.plan(file("""
        {"version":1,"mqtt":{
          "shared":{"host":"shared.local","port":1883,"use_tls":false,"username":"shared-user","password":"shared-pass"},
          "health_use_shared":false,
          "health_own_broker":{"host":"own.example.com","port":8883,"use_tls":true,"username":"own-user","password":"own-pass"}
        }}
        """), current: makePrefs().backupSnapshot())
        XCTAssertEqual(plan.result.mqttHost, "own.example.com")
        XCTAssertEqual(plan.result.mqttPort, 8883)
        XCTAssertTrue(plan.result.mqttUseTls)
        XCTAssertEqual(plan.result.mqttUsername, "own-user")
        XCTAssertEqual(plan.result.mqttPassword, "own-pass")
    }

    func testBaseTopicTranslation() throws {
        let current = makePrefs().backupSnapshot()
        let android = try SettingsImport.plan(file(#"{"version":1,"mqtt":{"health_base_topic":"lifedashboard"}}"#), current: current)
        XCTAssertEqual(android.result.mqttBaseTopic, MqttSupport.defaultBaseTopic)

        let custom = try SettingsImport.plan(file(#"{"version":1,"mqtt":{"health_base_topic":"myhome/health"}}"#), current: current)
        XCTAssertEqual(custom.result.mqttBaseTopic, "myhome/health")

        let iPhone = try SettingsImport.plan(
            file(#"{"version":1,"platform":"ios","mqtt":{"health_base_topic":"lifedashboard"}}"#), current: current)
        XCTAssertEqual(iPhone.result.mqttBaseTopic, "lifedashboard")
    }

    func testMenstruationNamesMapBothWays() {
        XCTAssertEqual(SettingsBackup.dataTypeNames([.menstruation]), ["MENSTRUATION_FLOW", "MENSTRUATION_PERIOD"])
        for name in ["MENSTRUATION_FLOW", "MENSTRUATION_PERIOD", "MENSTRUATION"] {
            XCTAssertEqual(SettingsBackup.dataTypes(from: [name]).types, [.menstruation])
        }
        let mixed = SettingsBackup.dataTypes(from: ["STEPS", "BONE_MASS", "SOMETHING_NEWER", "BONE_MASS"])
        XCTAssertEqual(mixed.types, [.steps])
        XCTAssertEqual(mixed.unknown, 2)
    }

    // MARK: - Secrets kept or cleared

    /// Android's urlsWithoutHeadersOnImport: the device's headers stay, for the URLs they were
    /// already sent to. Any other URL in the file gets none of them, also on the same server.
    func testFileWithoutHeadersKeepsThemForTheUrlsTheyWentTo() throws {
        var current = makePrefs().backupSnapshot()
        current.healthWebhookUrls = ["https://example.com/health", "https://ha.example/api/webhook/paired"]
        current.healthWebhookHeaders = ["Authorization": "Bearer mine"]
        current.healthUrlsWithoutHeaders = ["https://ha.example/api/webhook/paired"]

        let plan = try SettingsImport.plan(file("""
        {"version":1,"health":{"webhook_urls":[
          "https://example.com/health","https://example.com/other-path","https://ha.example/api/webhook/paired"
        ]}}
        """), current: current)
        XCTAssertEqual(plan.result.healthWebhookHeaders, ["Authorization": "Bearer mine"])
        XCTAssertEqual(plan.result.healthUrlsWithoutHeaders, [
            "https://example.com/other-path", "https://ha.example/api/webhook/paired"
        ])
        XCTAssertTrue(plan.notes.contains(.headersKept))
    }

    func testFileHeadersComeWithTheFilesOwnList() throws {
        var current = makePrefs().backupSnapshot()
        current.healthWebhookUrls = ["https://example.com/health"]
        current.healthUrlsWithoutHeaders = ["https://example.com/health"]
        let plan = try SettingsImport.plan(file("""
        {"version":1,"health":{"webhook_urls":["https://example.com/health","https://ha.example/hook"],
          "headers":{"X-Token":"theirs"},"urls_without_headers":["https://ha.example/hook"]}}
        """), current: current)
        XCTAssertEqual(plan.result.healthWebhookHeaders, ["X-Token": "theirs"])
        XCTAssertEqual(plan.result.healthUrlsWithoutHeaders, ["https://ha.example/hook"])
    }

    func testFileWithoutUrlsLeavesTheMarksAlone() throws {
        var current = makePrefs().backupSnapshot()
        current.healthWebhookUrls = ["https://example.com/health", "https://ha.example/hook"]
        current.healthUrlsWithoutHeaders = ["https://ha.example/hook"]
        let plan = try SettingsImport.plan(file(#"{"version":1,"health":{"headers":{"X-Token":"theirs"}}}"#), current: current)
        XCTAssertEqual(plan.result.healthUrlsWithoutHeaders, ["https://ha.example/hook"])
    }

    /// Keychain items outlive a deleted app, UserDefaults do not: after a reinstall the headers
    /// are there without the URLs they were for, and a URL from the file gets none of them.
    func testStaleHeadersWithoutUrlsGoNowhere() throws {
        var current = makePrefs().backupSnapshot()
        current.healthWebhookHeaders = ["Authorization": "Bearer old"]
        let plan = try SettingsImport.plan(
            file(#"{"version":1,"health":{"webhook_urls":["https://new.example/hook"]}}"#), current: current)
        XCTAssertEqual(plan.result.healthUrlsWithoutHeaders, ["https://new.example/hook"])
    }

    func testFileHeadersReplaceTheDevicesAndSigningSecretIsKeptWhenAbsent() throws {
        var current = makePrefs().backupSnapshot()
        current.healthWebhookHeaders = ["Authorization": "Bearer mine"]
        current.healthSigningSecret = "device-secret"
        let plan = try SettingsImport.plan(
            file(#"{"version":1,"health":{"headers":{"X-Token":"theirs"},"signing_secret":null}}"#), current: current)
        XCTAssertEqual(plan.result.healthWebhookHeaders, ["X-Token": "theirs"])
        XCTAssertEqual(plan.result.healthSigningSecret, "device-secret")
        XCTAssertTrue(plan.notes.contains(.signingSecretKept))
    }

    func testBrokerCredentialsStayOnlyWithTheSameBroker() throws {
        var current = makePrefs().backupSnapshot()
        current.mqttHost = "Broker.Local"
        current.mqttPort = 1883
        current.mqttUseTls = true
        current.mqttUsername = "me"
        current.mqttPassword = "secret"

        func plan(host: String = "broker.local", port: Int = 1883, tls: Bool = true, extra: String = "") throws -> SettingsSnapshot {
            try SettingsImport.plan(file("""
            {"version":1,\(extra)"mqtt":{"shared":{"host":" \(host) ","port":\(port),"use_tls":\(tls)}}}
            """), current: current).result
        }

        XCTAssertEqual(try plan().mqttPassword, "secret", "Same broker, host differing only in case")
        XCTAssertEqual(try plan(host: "other.local").mqttPassword, "")
        XCTAssertEqual(try plan(port: 1884).mqttPassword, "")
        XCTAssertEqual(try plan(tls: false).mqttUsername, "", "Never out in plain text where it had TLS")
        // Android judges "has secrets" over the whole file: a Screen Time header alone means
        // the file carries credentials, and then its (empty) broker credentials apply.
        XCTAssertEqual(try plan(extra: #""screen_time":{"headers":{"A":"b"}},"#).mqttPassword, "")

        current.mqttHost = ""
        XCTAssertEqual(try plan().mqttPassword, "", "A device without a broker has nothing to keep")
    }

    // MARK: - Validation

    func testAbsentKeysLeaveEverythingAlone() throws {
        let plan = try SettingsImport.plan(file(#"{"version":1,"some_future_section":{"x":1}}"#), current: fixture)
        XCTAssertEqual(plan.result, fixture)
        XCTAssertEqual(plan.notes, [])
    }

    func testWrongTypeRejectsTheWholeFile() {
        let cases: [(String, String)] = [
            (#"{"version":1,"mqtt":{"shared":{"port":"1883"}}}"#, "mqtt.shared.port"),
            (#"{"version":1,"mqtt":{"health_enabled":1}}"#, "mqtt.health_enabled"),
            (#"{"version":1,"health":{"webhook_urls":"https://example.com"}}"#, "health.webhook_urls")
        ]
        for (json, path) in cases {
            XCTAssertThrowsError(try file(json)) {
                XCTAssertEqual($0 as? SettingsBackupError, .notASettingsFile(path))
            }
        }
    }

    func testRejectsWhatIsNotASettingsFile() {
        for text in ["{}", "[1,2]", "not json", #"{"version":"1"}"#, #"[{"id":"a"}]"#] {
            XCTAssertThrowsError(try SettingsBackup.classify(Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try SettingsBackup.classify(Data())) {
            XCTAssertEqual($0 as? SettingsBackupError, .unreadable)
        }
        let huge = Data(#"{"version":1,"padding":""#.utf8) + Data(repeating: 0x61, count: SettingsBackup.maxFileBytes) + Data(#""}"#.utf8)
        XCTAssertThrowsError(try SettingsBackup.classify(huge)) {
            XCTAssertEqual($0 as? SettingsBackupError, .unreadable)
        }
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        XCTAssertThrowsError(try SettingsBackup.classify(Data(#"{"version":1,"x":\#(deep)}"#.utf8)))
    }

    func testNewerVersionStillImportsWhatItKnows() throws {
        let plan = try SettingsImport.plan(file(#"{"version":2,"options":{"failure_notifications_enabled":false}}"#), current: fixture)
        XCTAssertTrue(plan.notes.contains(.newerVersion))
        XCTAssertFalse(plan.result.failureNotificationsEnabled)
    }

    func testWebhookUrlRule() throws {
        let allowed = ["https://example.com/h", "http://192.168.1.5:8123/api", "http://homeassistant.local/x",
                       "http://100.100.1.1/x", "http://nas/hook", "http://[fd00::1]:8080/x"]
        let refused = ["http://example.com/h", "http://8.8.8.8/x", "file:///etc/passwd", "ftp://example.com",
                       "javascript:alert(1)", "https://", "example.com/h"]
        for url in allowed { XCTAssertTrue(SettingsBackup.isAllowedWebhookURL(url), url) }
        for url in refused { XCTAssertFalse(SettingsBackup.isAllowedWebhookURL(url), url) }

        let plan = try SettingsImport.plan(
            file(#"{"version":1,"health":{"webhook_urls":["https://ok.example/h","http://public.example/h"]}}"#),
            current: makePrefs().backupSnapshot())
        XCTAssertEqual(plan.result.healthWebhookUrls, ["https://ok.example/h"])
        XCTAssertTrue(plan.notes.contains(.skippedUrl("public.example")))
    }

    func testUnsafeValuesRejectTheFile() {
        let tooManyUrls = (0...SettingsImport.maxWebhookUrls).map { "\"https://example.com/\($0)\"" }.joined(separator: ",")
        let cases = [
            #"{"version":1,"health":{"headers":{"X-Token":"a\r\nX-Other: b"}}}"#,
            #"{"version":1,"health":{"headers":{"Bad Name":"a"}}}"#,
            #"{"version":1,"mqtt":{"shared":{"host":"mqtt://broker.local"}}}"#,
            #"{"version":1,"mqtt":{"shared":{"port":0}}}"#,
            #"{"version":1,"mqtt":{"shared":{"port":70000}}}"#,
            #"{"version":1,"mqtt":{"health_base_topic":"home/#"}}"#,
            #"{"version":1,"health":{"webhook_urls":[\#(tooManyUrls)]}}"#
        ]
        for json in cases {
            XCTAssertThrowsError(try SettingsImport.plan(file(json), current: fixture), json)
        }
    }

    func testIntervalAndThresholdAreBroughtIntoRange() throws {
        let plan = try SettingsImport.plan(
            file(#"{"version":1,"health":{"sync_interval_minutes":5},"options":{"failure_notification_threshold":7}}"#),
            current: fixture)
        XCTAssertEqual(plan.result.healthSyncSchedule.intervalMinutes, 15)
        XCTAssertEqual(plan.result.failureNotificationThreshold, 5)
        XCTAssertTrue(plan.notes.contains(.intervalAdjusted(15)))
        XCTAssertTrue(plan.notes.contains(.thresholdAdjusted(from: 7, to: 5)))
        XCTAssertEqual(try SettingsImport.plan(
            file(#"{"version":1,"options":{"failure_notification_threshold":4}}"#), current: fixture
        ).result.failureNotificationThreshold, 3, "A tie goes to the lower value")
    }

    // MARK: - Schedule

    /// Android's restoreSchedule: a file from before the schedule moves only the interval.
    func testFileWithoutScheduleFieldsLeavesTheScheduleAlone() throws {
        let plan = try SettingsImport.plan(file(#"{"version":1,"health":{"sync_interval_minutes":45}}"#), current: fixture)
        var expected = fixture.healthSyncSchedule
        expected.intervalMinutes = 45
        XCTAssertEqual(plan.result.healthSyncSchedule, expected)
    }

    func testScheduleFieldsReplaceTheDevicesAndQuietHoursNeedBothEnds() throws {
        let plan = try SettingsImport.plan(file("""
        {"version":1,"health":{"sync_mode":"SOMETHING_NEWER","sync_days":"SATURDAY,SUNDAY","quiet_from":"23:00","quiet_to":null}}
        """), current: fixture)
        let schedule = plan.result.healthSyncSchedule
        XCTAssertEqual(schedule.mode, .times, "A mode this build does not know keeps the device's")
        XCTAssertEqual(schedule.times, fixture.healthSyncSchedule.times)
        XCTAssertEqual(schedule.days, [.saturday, .sunday])
        XCTAssertNil(schedule.quietWindow)
    }

    func testImportedScheduleIsStampedAsAChange() {
        let prefs = makePrefs()
        prefs.healthScheduleState = ScheduleState(lastRun: nil, lastSlot: nil, changedAt: .distantPast)
        var next = prefs.backupSnapshot()
        next.healthSyncSchedule = fixture.healthSyncSchedule
        prefs.applyBackup(next)
        XCTAssertEqual(prefs.healthSyncSchedule, fixture.healthSyncSchedule)
        XCTAssertNotEqual(prefs.healthScheduleState.changedAt, .distantPast, "Times earlier today must not run after an import")
    }

    // MARK: - Applying

    /// A sync on another thread must never see a new broker with the old password, or a new
    /// URL with old headers: those secrets are blanked before the endpoints change.
    func testSecretsAreBlankedBeforeEndpointsChange() {
        let prefs = makePrefs()
        prefs.applyBackup(fixture)

        var events: [String] = []
        var subscriptions: Set<AnyCancellable> = []
        prefs.$mqttHost.dropFirst().sink { events.append("host=\($0)") }.store(in: &subscriptions)
        prefs.$mqttPassword.dropFirst().sink { events.append("password=\($0)") }.store(in: &subscriptions)
        prefs.$mqttEnabled.dropFirst().sink { events.append("enabled=\($0)") }.store(in: &subscriptions)
        prefs.$healthWebhookUrls.dropFirst().sink { _ in events.append("urls") }.store(in: &subscriptions)
        prefs.$healthWebhookHeaders.dropFirst().sink { events.append("headers=\($0.count)") }.store(in: &subscriptions)

        var next = fixture
        next.mqttHost = "other.example.com"
        next.mqttPassword = "other-pass"
        next.healthWebhookUrls = ["https://other.example/hook"]
        next.healthUrlsWithoutHeaders = []
        next.healthWebhookHeaders = ["X-Other": "value"]
        prefs.applyBackup(next)

        XCTAssertEqual(events, [
            "headers=0", "password=", "enabled=false",
            "urls", "host=other.example.com",
            "headers=1", "password=other-pass", "enabled=true"
        ])
        XCTAssertEqual(prefs.backupSnapshot(), next)
    }

    func testApplyingTheSameSettingsWritesNothing() {
        let prefs = makePrefs()
        prefs.applyBackup(fixture)
        var writes = 0
        let subscription = prefs.objectWillChange.sink { writes += 1 }
        prefs.applyBackup(fixture)
        subscription.cancel()
        XCTAssertEqual(writes, 0)
    }
}
