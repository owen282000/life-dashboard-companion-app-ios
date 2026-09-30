import XCTest
@testable import LifeDashboardCompanion

/// What the catalogs cannot show on their own: the Dutch and German the app actually resolves at
/// run time, and the English it stores. Every test names its language, so the suite passes in
/// any test language; CI runs it in English and again in German.
final class LocalizationTests: XCTestCase {

    private func resolve(_ resource: LocalizedStringResource, _ language: String) -> String {
        var resource = resource
        resource.locale = Locale(identifier: language)
        return String(localized: resource)
    }

    // MARK: - The bundle

    func testTheAppShipsDutchAndGerman() {
        XCTAssertTrue(Bundle.main.localizations.contains("nl"))
        XCTAssertTrue(Bundle.main.localizations.contains("de"))
    }

    func testButtonsResolveInEachLanguage() {
        XCTAssertEqual(resolve("Sync Now", "nl"), "Nu synchroniseren")
        XCTAssertEqual(resolve("Sync Now", "de"), "Jetzt synchronisieren")
        XCTAssertEqual(resolve("Sync Now", "en"), "Sync Now")
    }

    func testEveryDataTypeHasADutchAndGermanName() {
        // Apple's own names, which are the English ones in these two cases.
        let sameAsEnglish: [String: Set<HealthDataType>] = ["nl": [.mindfulness], "de": [.menstruation]]
        for language in ["nl", "de"] {
            for type in HealthDataType.allCases where !sameAsEnglish[language, default: []].contains(type) {
                XCTAssertNotEqual(resolve(type.displayName, language), resolve(type.displayName, "en"),
                                  "\(type) has no \(language) name")
            }
        }
        XCTAssertEqual(resolve(HealthDataType.restingHeartRate.displayName, "nl"), "Hartslag in rust")
        XCTAssertEqual(resolve(HealthDataType.activeCalories.displayName, "de"), "Aktivitätsenergie")
    }

    func testCountsVaryByPlural() {
        XCTAssertEqual(resolve("\(1) pending syncs", "de"), "1 Sync in der Warteschlange")
        XCTAssertEqual(resolve("\(3) pending syncs", "de"), "3 Syncs in der Warteschlange")
        XCTAssertEqual(resolve("\(1) pending syncs", "en"), "1 pending sync")
        XCTAssertEqual(resolve("On, after \(1) failed syncs", "de"), "An, nach 1 fehlgeschlagener Synchronisierung")
    }

    func testAPluralNextToAnotherArgumentUsesItsOwnCount() {
        XCTAssertEqual(resolve("\("Every 60 min") to \(1) webhooks", "nl"), "Every 60 min naar 1 webhook")
        XCTAssertEqual(resolve("\("Every 60 min") to \(2) webhooks", "de"), "Every 60 min an 2 Webhooks")
        XCTAssertEqual(resolve("\(2) of \(10) windows, \(1) records sent", "nl"), "2 van 10 blokken, 1 record verstuurd")
    }

    // MARK: - Stored in English, shown translated

    func testEveryStoredMessageIsRecognized() {
        for diagnostic in AppDiagnostic.allCases {
            XCTAssertEqual(AppDiagnostic(rawValue: diagnostic.rawValue), diagnostic)
            XCTAssertEqual(AppDiagnostic.display(diagnostic.rawValue), diagnostic.localized)
        }
    }

    func testMessagesWithAValueAreStoredInEnglishAndReadBack() {
        XCTAssertEqual(AppDiagnostic.http(502), "HTTP 502")
        XCTAssertEqual(AppDiagnostic.display(AppDiagnostic.http(502)), String(localized: "HTTP \(502)"))
        XCTAssertEqual(AppDiagnostic.unknownAfterAttempts(3), "Unknown error after 3 attempts")
        XCTAssertEqual(AppDiagnostic.display(AppDiagnostic.unknownAfterAttempts(3)),
                       String(localized: "Unknown error after \(3) attempts"))
        XCTAssertEqual(AppDiagnostic.notReturned("WEIGHT"), "HealthKit did not return WEIGHT")
        let weight = String(localized: HealthDataType.weight.displayName)
        XCTAssertEqual(AppDiagnostic.display(AppDiagnostic.notReturned("WEIGHT")),
                       String(localized: "HealthKit did not return \(weight)"))
    }

    func testTextFromAServerOrFromIOSIsShownAsStored() {
        XCTAssertEqual(AppDiagnostic.display("The request timed out."), "The request timed out.")
        XCTAssertEqual(AppDiagnostic.display("HTTP 5xx"), "HTTP 5xx")
        // A job from an older version stored the display name; it is shown as it was.
        XCTAssertEqual(AppDiagnostic.display("HealthKit did not return Steps"),
                       String(localized: "HealthKit did not return \("Steps")"))
    }

    // MARK: - MQTT status

    func testMqttStatusColourComesFromWhatHappened() throws {
        let published = try XCTUnwrap(MqttStatus(stored: MqttStatus.published(sensors: 4, at: Date(timeIntervalSince1970: 0))))
        XCTAssertTrue(published.success)
        XCTAssertEqual(published.sensors, 4)
        XCTAssertEqual(published.date, Date(timeIntervalSince1970: 0))

        let failed = try XCTUnwrap(MqttStatus(stored: MqttStatus.failed(AppDiagnostic.brokerRefused.rawValue)))
        XCTAssertFalse(failed.success)
        XCTAssertEqual(failed.detail, AppDiagnostic.brokerRefused.rawValue)

        XCTAssertNil(MqttStatus(stored: ""))
    }

    func testMqttStatusFromAnOlderVersionStillReads() throws {
        let old = try XCTUnwrap(MqttStatus(stored: "OK: 12 sensors published at 2026-09-01T10:00:00Z"))
        XCTAssertTrue(old.success)
        XCTAssertEqual(old.sensors, 12)
        let error = try XCTUnwrap(MqttStatus(stored: "Error: The operation couldn't be completed."))
        XCTAssertFalse(error.success)
        XCTAssertEqual(error.detail, "The operation couldn't be completed.")
    }

    // MARK: - Exports stay the same in every language

    func testCsvTimestampIgnoresThePhoneLanguage() {
        let formatter = ExportManager.fixedFormatter("yyyy-MM-dd HH:mm:ss")
        formatter.timeZone = TimeZone(identifier: "UTC")
        XCTAssertEqual(formatter.string(from: Date(timeIntervalSince1970: 1_790_000_000)), "2026-09-21 14:13:20")
    }
}
