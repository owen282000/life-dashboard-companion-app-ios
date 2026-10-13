import XCTest
@testable import LifeDashboardCompanion

final class SettingsValidationTests: XCTestCase {

    // MARK: - Custom headers

    func testHeaderNamesAreHTTPTokens() {
        for name in ["Authorization", "X-Api-Key", "x_token", "X.Custom", "A!#$%&'*+-.^_`|~9"] {
            XCTAssertTrue(SettingsValidation.isValidHeaderName(name), name)
        }
        for name in ["Bad Header", "X:Token", "X-Tökén", "X(1)", "X/Y", "X\tY", "X\r\nY", "\"X\"", "X@Y", "",
                     String(repeating: "a", count: SettingsValidation.maxHeaderNameLength + 1)] {
            XCTAssertFalse(SettingsValidation.isValidHeaderName(name), name.debugDescription)
        }
    }

    /// Android's rule, what OkHttp sends: printable ASCII and tabs, so a header one app takes
    /// the other takes too.
    func testHeaderValuesArePrintableAsciiAndTabs() {
        let printable = String((0x20...0x7E).map { Character(UnicodeScalar(UInt8($0))) })
        for value in ["Bearer abc.def", "a\tb", "", "x=1; y=\"2\"", printable,
                      String(repeating: "a", count: SettingsValidation.maxHeaderValueLength)] {
            XCTAssertTrue(SettingsValidation.isValidHeaderValue(value), value.debugDescription)
        }
        for value in ["a\r\nX-Other: b", "a\nb", "a\rb", "a\u{0}b", "a\u{1}b", "a\u{7F}b", "a\u{85}b", "a\u{2028}b", "a\u{2029}b",
                      "é", "Zoë", "日本", "a\u{A0}b", "\u{1F600}",
                      String(repeating: "a", count: SettingsValidation.maxHeaderValueLength + 1)] {
            XCTAssertFalse(SettingsValidation.isValidHeaderValue(value), value.debugDescription)
        }
    }

    func testAHeaderTypedOnTheHealthTabSaysWhatIsWrong() {
        XCTAssertNil(SettingsValidation.headerProblem(name: "X-Api-Key", value: "secret"))
        XCTAssertEqual(SettingsValidation.headerProblem(name: "", value: "secret"), .emptyName)
        XCTAssertEqual(SettingsValidation.headerProblem(name: "Bad Header", value: "secret"), .invalidName)
        XCTAssertEqual(SettingsValidation.headerProblem(name: "X-Api-Key", value: ""), .emptyValue)
        XCTAssertEqual(SettingsValidation.headerProblem(name: "X-Api-Key", value: "a\u{1}b"), .invalidValue)
        XCTAssertEqual(SettingsValidation.headerProblem(name: "X-Api-Key", value: "Zoë"), .invalidValue)
        XCTAssertEqual(
            SettingsValidation.headerProblem(name: "X-Api-Key", value: String(repeating: "a", count: SettingsValidation.maxHeaderValueLength + 1)),
            .valueTooLong
        )

        let full = Dictionary(uniqueKeysWithValues: (0..<SettingsValidation.maxHeaders).map { ("X-\($0)", "v") })
        XCTAssertEqual(SettingsValidation.headerProblem(name: "X-New", value: "v", existing: full), .tooMany)
        XCTAssertNil(SettingsValidation.headerProblem(name: "X-0", value: "w", existing: full), "replacing one is not one more")

        for problem in [SettingsValidation.HeaderProblem.emptyName, .invalidName, .emptyValue, .invalidValue, .valueTooLong, .tooMany] {
            XCTAssertFalse(problem.message.isEmpty)
        }
    }

    func testTheFirstInvalidHeaderIsNamed() {
        XCTAssertNil(SettingsValidation.firstInvalidHeader([:]))
        XCTAssertNil(SettingsValidation.firstInvalidHeader(["Authorization": "Bearer a", "X-Signature": "sha256=00"]))
        XCTAssertEqual(SettingsValidation.firstInvalidHeader(["Authorization": "Bearer a", "Bad Header": "x"]), "Bad Header")
        XCTAssertEqual(SettingsValidation.firstInvalidHeader(["B": "a\nb", "A": "ok"]), "B")
    }

    /// A header iOS would leave out names itself in the log, not the server: the line is
    /// recognised again when shown, and a name that could break the line is made safe first.
    func testAnInvalidHeaderLineNamesTheHeader() {
        let line = AppDiagnostic.invalidHeader("Bad Header")
        XCTAssertEqual(line, "Custom header \"Bad Header\" is not valid, so nothing was sent. Remove it under Webhook and add it again.")
        // The tests run in English, so a recognised line reads the same as it was stored.
        XCTAssertEqual(AppDiagnostic.display(line), line)

        let broken = AppDiagnostic.invalidHeader("X\r\n\"Evil\"\u{2028}")
        XCTAssertFalse(broken.contains("\n"))
        XCTAssertTrue(broken.hasPrefix("Custom header \"X???Evil??\" is not valid"))
        XCTAssertEqual(AppDiagnostic.display(broken), broken)
        XCTAssertLessThan(AppDiagnostic.invalidHeader(String(repeating: "a", count: 300)).count, 200)
    }

    // MARK: - MQTT broker

    func testABrokerHostIsANameOrAnAddress() {
        let accepted = [
            "192.168.1.10", "homeassistant.local", "mqtt", "broker.example.com", "broker.example.com.",
            "mosquitto_broker", "a-b.c-d", "10.0.0.1", "fd00::1", "::1", "2001:db8::8a2e:370:7334",
            "[fd00::1]", "fe80::1%en0", "  192.168.1.10  "
        ]
        for host in accepted {
            XCTAssertNil(SettingsValidation.brokerHostProblem(host), host)
        }
    }

    func testABadBrokerHostSaysWhatIsWrong() {
        XCTAssertEqual(SettingsValidation.brokerHostProblem(""), .emptyHost)
        XCTAssertEqual(SettingsValidation.brokerHostProblem("   "), .emptyHost)
        XCTAssertEqual(SettingsValidation.brokerHostProblem("my broker"), .whitespace)
        XCTAssertEqual(SettingsValidation.brokerHostProblem("192.168.1.10\t1883"), .whitespace)
        XCTAssertEqual(SettingsValidation.brokerHostProblem("mqtt://broker.local"), .scheme)
        XCTAssertEqual(SettingsValidation.brokerHostProblem("broker.local:1883"), .portInHost)
        XCTAssertEqual(SettingsValidation.brokerHostProblem("192.168.1.10:1883"), .portInHost)
        for host in ["192.168.1", "256.1.1.1", "1.2.3.4.5", "-broker.local", "broker-.local", "broker..local",
                     "broker/path", "bröker.local", "fd00::g", "[fd00::1", "fe80::1%", "fe80::1%en 0",
                     String(repeating: "a", count: 64) + ".local", String(repeating: "a.", count: 127) + "a"] {
            XCTAssertEqual(SettingsValidation.brokerHostProblem(host), host.contains(" ") ? .whitespace : .invalidHost, host)
        }
    }

    func testTheHostIsSavedTrimmedAndWithoutBrackets() {
        XCTAssertEqual(SettingsValidation.normalizedBrokerHost("  broker.local "), "broker.local")
        XCTAssertEqual(SettingsValidation.normalizedBrokerHost("[fd00::1]"), "fd00::1")
        XCTAssertEqual(SettingsValidation.normalizedBrokerHost("[]"), "[]")
        XCTAssertEqual(SettingsValidation.normalizedBrokerHost(""), "")
    }

    func testThePortIsOneTo65535() {
        for text in ["1", "1883", "8883", "65535", " 1883 "] {
            XCTAssertNil(SettingsValidation.brokerPortProblem(text), text)
        }
        for text in ["", "0", "65536", "70000", "-1", "18 83", "1883a", "+1883", "99999999999999999999", "١٨٨٣"] {
            XCTAssertEqual(SettingsValidation.brokerPortProblem(text), .invalidPort, text)
        }
    }

    // MARK: - Settings import

    private func plan(_ json: String) throws -> ImportPlan {
        let name = "settings-validation-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let prefs = PreferencesManager(defaults: UserDefaults(suiteName: name)!, secrets: InMemorySecretStore())
        let file = try SettingsBackup.decode(Data(json.utf8))
        return try SettingsImport.plan(file, current: prefs.backupSnapshot())
    }

    /// A file carries the Health tab's rules too: a header iOS would drop, or a broker host
    /// the tab refuses, makes the whole file invalid instead of breaking delivery later.
    func testTheImportRefusesWhatTheHealthTabRefuses() {
        let refused = [
            #"{"version":1,"health":{"headers":{"Bad Header":"a"}}}"#,
            #"{"version":1,"health":{"headers":{"X-Token":"a\u0001b"}}}"#,
            #"{"version":1,"health":{"headers":{"X-Token":"a b"}}}"#,
            #"{"version":1,"mqtt":{"shared":{"host":"my broker"}}}"#,
            #"{"version":1,"mqtt":{"shared":{"host":"192.168.1"}}}"#,
            #"{"version":1,"mqtt":{"shared":{"host":"broker.local:1883"}}}"#
        ]
        for json in refused {
            XCTAssertThrowsError(try plan(json), json) { error in
                guard case SettingsBackupError.notASettingsFile(let path?) = error else {
                    return XCTFail("names the field: \(json)")
                }
                XCTAssertTrue(path.hasPrefix("health.headers") || path.hasPrefix("mqtt.shared.host"), path)
            }
        }
    }

    func testTheImportTakesValidHostsAndSavesThemPlain() throws {
        XCTAssertEqual(try plan(#"{"version":1,"mqtt":{"shared":{"host":"[fd00::1]"}}}"#).result.mqttHost, "fd00::1")
        XCTAssertEqual(try plan(#"{"version":1,"mqtt":{"shared":{"host":" broker.local "}}}"#).result.mqttHost, "broker.local")
        XCTAssertEqual(try plan(#"{"version":1,"mqtt":{"shared":{"host":""}}}"#).result.mqttHost, "", "no broker in the file")
        XCTAssertEqual(
            try plan(#"{"version":1,"health":{"headers":{"X-Token":"a\tb"}}}"#).result.healthWebhookHeaders,
            ["X-Token": "a\tb"]
        )
    }
}
