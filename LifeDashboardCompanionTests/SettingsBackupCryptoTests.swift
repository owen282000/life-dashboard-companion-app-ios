import XCTest
@testable import LifeDashboardCompanion

final class SettingsBackupCryptoTests: XCTestCase {

    // Known answers from the Android algorithm with a fixed salt (bytes 00...0f) and IV
    // (bytes a0...ab), produced by ConfigCrypto's own code on a JVM.
    private let salt = Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODw==")!
    private let iv = Data(base64Encoded: "oKGio6Slpqeoqaqr")!

    private struct Vector {
        let password: String
        let plaintext: String
        let ciphertext: String
    }

    private let vectors: [Vector] = [
        Vector(
            password: "correct horse battery staple",
            plaintext: #"{"health":{"signing_secret":"hmac-secret"}}"#,
            ciphertext: "oGExFIGUZOPrXa7jSOXU47SmIWH/H9oX02u2RT7HtdPRUXZi+zpDZ4suEd/nKbDabx/3i0Kvq++iAhI="
        ),
        Vector(
            password: "wachtw\u{f6}ord \u{1F510}",
            plaintext: #"{"version":1,"health":{"webhook_urls":["https://example.com/h"],"headers":{"Authorization":"Bearer abc"},"signing_secret":"s3cret"}}"#,
            ciphertext: "VPzVwTmy6IoCmCxtRRRX0Z3Kluts2aop4jTOHEo32451v+b2uMB11lTVLiZBqxLAFUIJxu6QSQe6gEDLR3LRryD8zyBLn8hxgPkZpRDoubiTJpqZZCXAPol7muM1ufqUlqO1Yyf05sYRpZky8tEvY1gF4eoka4dn97EarbcAN+KCkydxZIpP6ZXrzocoCATjzLosQw=="
        ),
        Vector(
            password: "wachtwoord \u{e9}\u{1F510}",
            plaintext: #"{"version":1,"platform":"android","note":"Zo\#u{eb} \#u{1F510}"}"#,
            ciphertext: "G+79qZkm+7nJHoppIuTarnaEVvsv3e0D/lks8QTnGHR+NuNC6IzAaYO9J8aUrRPgJo7MaL9LHAN1G5TiTDjGH36Y9yAh"
        )
    ]

    private func envelope(ciphertext: String, salt: String? = nil, iv: String? = nil,
                          iterations: Int = 210_000, version: Int = 1, kdf: String = "PBKDF2WithHmacSHA256") -> Data {
        Data("""
        {
          "type": "life-dashboard-encrypted-config",
          "version": \(version),
          "kdf": "\(kdf)",
          "iterations": \(iterations),
          "salt": "\(salt ?? self.salt.base64EncodedString())",
          "iv": "\(iv ?? self.iv.base64EncodedString())",
          "ciphertext": "\(ciphertext)"
        }
        """.utf8)
    }

    func testDecryptsAndroidKnownAnswers() throws {
        for vector in vectors {
            let plain = try SettingsBackupCrypto.decrypt(envelope(ciphertext: vector.ciphertext), password: vector.password)
            XCTAssertEqual(String(bytes: plain, encoding: .utf8), vector.plaintext)
        }
    }

    func testEncryptsExactlyAsAndroidDoes() throws {
        for vector in vectors {
            let data = try SettingsBackupCrypto.encrypt(Data(vector.plaintext.utf8), password: vector.password, salt: salt, iv: iv)
            let written = try JSONDecoder().decode(SettingsBackupCrypto.Envelope.self, from: data)
            XCTAssertEqual(written.ciphertext, vector.ciphertext)
            XCTAssertEqual(written.iterations, 210_000)
            XCTAssertEqual(written.kdf, "PBKDF2WithHmacSHA256")
        }
    }

    func testOpensAnExportMadeByTheAndroidApp() throws {
        let data = Data(AndroidFixtures.encrypted.utf8)
        XCTAssertTrue(SettingsBackupCrypto.isEnvelope(data))
        let plain = try SettingsBackupCrypto.decrypt(data, password: AndroidFixtures.encryptedPassword)
        XCTAssertEqual(try SettingsBackup.decode(plain), try SettingsBackup.decode(Data(AndroidFixtures.plain.utf8)))
    }

    /// Android does not parse the envelope as JSON: it pulls each value out with this regex. An
    /// escaped slash in the base64 would reach its decoder and fail the whole import there.
    func testAndroidsEnvelopeReaderCanReadAnIOSEnvelope() throws {
        var data = Data()
        // Enough exports that the base64 is all but certain to contain a slash.
        for _ in 0..<8 {
            data = try SettingsBackupCrypto.encrypt(Data(String(repeating: "settings ", count: 40).utf8), password: "password1")
            let text = String(bytes: data, encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains("\\/"))

            let lengths: [String: Int] = ["salt": 16, "iv": 12]
            for field in ["salt", "iv", "ciphertext", "iterations"] {
                let regex = try NSRegularExpression(pattern: "\"\(field)\"\\s*:\\s*\"?([^\",}\\s]+)\"?")
                let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
                let value = String(text[Range(match.range(at: 1), in: text)!])
                if field == "iterations" {
                    XCTAssertEqual(value, "210000")
                } else {
                    let bytes = try XCTUnwrap(Data(base64Encoded: value), "\(field) is not plain base64: \(value)")
                    if let length = lengths[field] {
                        XCTAssertEqual(bytes.count, length)
                    } else {
                        XCTAssertEqual(bytes.count, 360 + 16)
                    }
                }
            }
        }
    }

    func testRoundTripAndFreshSaltPerExport() throws {
        let plain = Data(#"{"version":1}"#.utf8)
        let first = try SettingsBackupCrypto.encrypt(plain, password: "a long passphrase")
        let second = try SettingsBackupCrypto.encrypt(plain, password: "a long passphrase")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try SettingsBackupCrypto.decrypt(first, password: "a long passphrase"), plain)
        XCTAssertFalse((String(bytes: first, encoding: .utf8) ?? "").contains("version\":1}"))
    }

    func testWrongPasswordOrEditedFileIsRefused() throws {
        let vector = vectors[0]
        XCTAssertThrowsError(try SettingsBackupCrypto.decrypt(envelope(ciphertext: vector.ciphertext), password: "wrong")) {
            XCTAssertEqual($0 as? SettingsBackupCryptoError, .wrongPassword)
        }

        var bytes = Data(base64Encoded: vector.ciphertext)!
        bytes[0] ^= 0x01
        XCTAssertThrowsError(try SettingsBackupCrypto.decrypt(envelope(ciphertext: bytes.base64EncodedString()), password: vector.password)) {
            XCTAssertEqual($0 as? SettingsBackupCryptoError, .wrongPassword)
        }

        var tag = Data(base64Encoded: vector.ciphertext)!
        tag[tag.count - 1] ^= 0x01
        XCTAssertThrowsError(try SettingsBackupCrypto.decrypt(envelope(ciphertext: tag.base64EncodedString()), password: vector.password)) {
            XCTAssertEqual($0 as? SettingsBackupCryptoError, .wrongPassword)
        }
    }

    /// Checked before any key derivation, so a crafted iteration count cannot hang the app.
    func testRejectsEnvelopesItShouldNotTry() {
        let ciphertext = vectors[0].ciphertext
        let cases: [(Data, SettingsBackupCryptoError)] = [
            (envelope(ciphertext: ciphertext, iterations: 2_000_000_000), .unsupported),
            (envelope(ciphertext: ciphertext, iterations: 1000), .unsupported),
            (envelope(ciphertext: ciphertext, version: 2), .unsupported),
            (envelope(ciphertext: ciphertext, kdf: "scrypt"), .unsupported),
            (envelope(ciphertext: ciphertext, salt: Data(count: 15).base64EncodedString()), .notAnEnvelope),
            (envelope(ciphertext: ciphertext, iv: Data(count: 16).base64EncodedString()), .notAnEnvelope),
            (envelope(ciphertext: Data(count: 8).base64EncodedString()), .notAnEnvelope),
            (Data(#"{"version":1,"health":{}}"#.utf8), .notAnEnvelope)
        ]
        for (data, expected) in cases {
            XCTAssertThrowsError(try SettingsBackupCrypto.decrypt(data, password: "password1")) {
                XCTAssertEqual($0 as? SettingsBackupCryptoError, expected)
            }
        }
    }

    /// Detected by the type key, not by searching for the marker anywhere in the file.
    func testPlainFileMentioningTheMarkerIsNotAnEnvelope() {
        let plain = Data(#"{"version":1,"health":{"webhook_urls":["https://x.example/\"life-dashboard-encrypted-config\""]}}"#.utf8)
        XCTAssertFalse(SettingsBackupCrypto.isEnvelope(plain))
        XCTAssertFalse(SettingsBackupCrypto.isEnvelope(Data("[1,2]".utf8)))
    }
}
