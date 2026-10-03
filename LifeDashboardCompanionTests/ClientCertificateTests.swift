import Security
import XCTest
@testable import LifeDashboardCompanion

/// Throwaway certificates made with OpenSSL for these tests only, signed by a throwaway
/// "Life Dashboard Test CA" whose key is not in this repository. Every file's password is
/// `password` unless its comment says otherwise.
enum ClientCertificateFixtures {
    static let password = "test-password"

    /// CN=Test iPhone, O=Life Dashboard; EC P-256; valid until 1 January 2051 (a GeneralizedTime),
    /// with the CA in the file. OpenSSL 3's default encryption: AES-256 and PBKDF2.
    static let modern = file("""
        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
        """)

    /// The same identity, encrypted the way older tools and OpenSSL's -legacy do (3DES, RC2).
    static let legacy = file("""
        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
        """)

    /// CN=Old iPhone, expired on 1 January 2025 at 12:00 UTC (a UTCTime). Password "old".
    static let expired = file("""
        MIIEiQIBAzCCBDcGCSqGSIb3DQEHAaCCBCgEggQkMIIEIDCCAqoGCSqGSIb3DQEHBqCCApswggKXAgEAMIICkAYJKoZIhvcN
        AQcBMF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBCWImtsWnPHMLfVdkdm6rySAgIIADAMBggqhkiG9w0CCQUAMB0G
        CWCGSAFlAwQBKgQQcMtFw3nuV7NEwb56DDqwg4CCAiAYi6QkZAsHiGJD/nPr1uIogwDrn906vQGQE9KuDtynzaBu0fOHmBCr
        XfakwG+UhG5s37QlWZUtUEYMAASWc/DZLzHBGZSQQESR7VjQndRpmu//7rlZNk3036SBFNp8ofQAwtFNNPRzpFm8rp6HefZ2
        XWiCVEcg2Oo/o4z38Cyc4wevFDoFExyZnDbNJ3l3v2D4MVN82nCbjMLbdhqEaXQWWLZACxglFJ65zCUhmraSVQOFW9CTXmSV
        Y/8oz/uLAN9AzH1nbkjNHjoNeBNFqQW/i85rrcnV1+5K02FnvyZlx9noElTk4fdZqpEoaND1LSZM0GkMLjD5jO/mlhpQsVN+
        oGvY1mDmai98zd0fAwbuJJqD8zdlenO5BMKFd2lRIESpIFO+p/7CD51rLivbTFLuPuwxokKEZdVcFKmSvxlJCnQU0GUh59VQ
        f5dtTsjdr7o2fXts9K5lAynaqmjA7babtZWCtmObuUTHgExH4wWubKHCd0MTVx02gTbLctcKzJf8vujTd36Rx8xLXVKgwCwn
        cqKJob5yiV3Yrkx4OtgpBZg31uSls3JAcRg4UT54bLatRT6g3ROkjWmKilMUjAtHutdO8MJ7shf0lloiaAOdnawX97vyTHvA
        9DW06NQ6sn6TwZrE0u24ymXZoJg0L+PYKIoNj9Ol9cgkxWq8BoQCneQoAEuw4CffvfcjbdByY56pOJaCqAeQVtx9nKefj8SN
        MIIBbgYJKoZIhvcNAQcBoIIBXwSCAVswggFXMIIBUwYLKoZIhvcNAQwKAQKggfcwgfQwXwYJKoZIhvcNAQUNMFIwMQYJKoZI
        hvcNAQUMMCQEEAS6eEqfMJupMK1P1ZCoaXsCAggAMAwGCCqGSIb3DQIJBQAwHQYJYIZIAWUDBAEqBBBlAwLQlsD5JWbe48xh
        dTxOBIGQmFU8LuFz1Po9tNhmm5irDFnYvgk1/+XWcvzQzPknx1aDgAvswPq53sUVT0iafekQyvqvm70OPJcs3n/0OYHKW6aN
        av1X5TjcscG+5MCVFg8UwTuttISTEVWk4hUZY/ztFX/QKFHx95HYBTrV9cd1b+BcK4aN5iR+Rw5gBUzh7PaYSXtpeZ2D/iaM
        BOfqSUmLMUowIwYJKoZIhvcNAQkUMRYeFABPAGwAZAAgAGkAUABoAG8AbgBlMCMGCSqGSIb3DQEJFTEWBBQsF7fyhApUMGpp
        Rtjv2nEPWC4IPDBJMDEwDQYJYIZIAWUDBAIBBQAEIKC6iszU4NZC6MypD94KTj4bRFqOFATnLe0MfrGRY8EEBBAj1g0VRCwG
        D3VWHFf4iPAAAgIIAA==
        """)

    /// Only the CA certificate, no private key.
    static let certificateOnly = file("""
        MIICxwIBAzCCAnUGCSqGSIb3DQEHAaCCAmYEggJiMIICXjCCAloGCSqGSIb3DQEHBqCCAkswggJHAgEAMIICQAYJKoZIhvcN
        AQcBMF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBAaRv5t3FVDQ8ggZqBKvIZEAgIIADAMBggqhkiG9w0CCQUAMB0G
        CWCGSAFlAwQBKgQQFITlP+fPx4fb4qkOjsyxfICCAdAwSni9FWGhZJKWunbgNCrq+d8Wa6t4T+1fPltGKb1W3SyzZnm3P7gC
        u1gG2MO/Nd/J8ur+Pj9xoo7Gq00EVvw1r3HGpHJI0+68fPKarCcXKvwp9g1jnTS3uR0qZKJ1PGSLPe104lCoIlgBNGZyENSt
        MWrtot7JMDIECaynt6iAer7hZpqd7yq4+Ek5vYjbksOUGusJZX5oK6kGUWv9644iGiOogSvb+SZCfp1fwxqWajC5WwuV6Gk+
        c43sv6IrUQGGWWFVKrE+pAekQDyJ5owyC/zgzkdhjIhsqIcNrqEYbt73RgDGAMSElcVPGGtp7LNKg8picxn6zot+QJSoz9mM
        44yTb+H0pIpvwYNkWBz9xQjCimD5+6C0mnOfDLlaLIxRUp29jMH7sfMn56mFT97DqYeKZkYb3UpIUmJA+LqFaq1lMc3zyJfF
        4vOu01Az2gHoPhfMQSVleZD8z040fWQaB1EhDR4d+sbGVapIcxgpq5kI1Og+ersZetMUlEKhBZMFgNdOEt2MPGorCfD/V8+D
        e4qUh4T7SYxgI19NB3gXC9d2k0gPEnevobw4fHZ1RRFh63KNiQM7jtNz8dsV9FJ0w72dupcy/IF9hfsyuyR4fjBJMDEwDQYJ
        YIZIAWUDBAIBBQAEIAv90SiQiQuFoJM687JwSxAD1dPsYH1FArz0cfquzfGfBBBDDOttgitvw7Vsz5ojk8yjAgIIAA==
        """)

    private static func file(_ base64: String) -> Data {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
    }
}

@MainActor
final class ClientCertificateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ClientCertificateStore.remove()
        PreferencesManager.shared.clientCertificate = nil
    }

    override func tearDown() {
        ClientCertificateStore.remove()
        PreferencesManager.shared.clientCertificate = nil
        super.tearDown()
    }

    /// Imports the test identity the way the Advanced row does: into the Keychain, and on record.
    private func importFixture() throws {
        PreferencesManager.shared.clientCertificate = try ClientCertificateStore.importPKCS12(
            ClientCertificateFixtures.modern, password: ClientCertificateFixtures.password
        )
    }

    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func storedCertificate() -> SecCertificate? {
        ClientCertificateStore.identity().flatMap(ClientCertificateStore.certificate(of:))
    }

    private func storedSubject() -> String? {
        storedCertificate().flatMap { SecCertificateCopySubjectSummary($0) as String? }
    }

    /// Every item of a Keychain class that carries the certificate's label, with its attributes.
    private func items(_ itemClass: CFString, label: String = ClientCertificateStore.label) -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecAttrLabel as String: label,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return result as? [[String: Any]] ?? []
    }

    private func privateKeyExists(_ applicationLabel: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationLabel as String: applicationLabel,
            kSecReturnRef as String: true
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    private func applicationLabel(of identity: SecIdentity) throws -> Data {
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(identity, &key), errSecSuccess)
        let attributes = try XCTUnwrap(SecKeyCopyAttributes(XCTUnwrap(key)) as? [String: Any])
        return try XCTUnwrap(attributes[kSecAttrApplicationLabel as String] as? Data)
    }

    // MARK: - Import

    func testImportStoresTheIdentityAndReadsItsSubjectAndExpiry() throws {
        let info = try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.modern, password: ClientCertificateFixtures.password)

        XCTAssertEqual(info, ClientCertificateInfo(subject: "Test iPhone", expiresAt: Self.utc(2051, 1, 1)))
        XCTAssertEqual(storedSubject(), "Test iPhone")
    }

    func testAFileFromOlderToolsImportsToo() throws {
        let info = try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.legacy, password: ClientCertificateFixtures.password)
        XCTAssertEqual(info.subject, "Test iPhone")
        XCTAssertNotNil(ClientCertificateStore.identity())
    }

    func testTheIdentityIsKeptOnThisDeviceOnlyAndNeverSynced() throws {
        _ = try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.modern, password: ClientCertificateFixtures.password)

        let identities = items(kSecClassIdentity)
        XCTAssertEqual(identities.count, 1)
        for attributes in identities + items(kSecClassCertificate) {
            XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
        }
        // The private key is a Keychain item of its own, with the same protection.
        let identity = try XCTUnwrap(ClientCertificateStore.identity())
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationLabel as String: try applicationLabel(of: identity),
            kSecReturnAttributes as String: true
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let key = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(key[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(key[kSecAttrSynchronizable as String] as? Bool, true)
    }

    func testAWrongPasswordKeepsTheCurrentCertificate() throws {
        _ = try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.modern, password: ClientCertificateFixtures.password)

        XCTAssertThrowsError(try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.expired, password: "wrong")) { error in
            XCTAssertEqual(error as? ClientCertificateError, .wrongPassword)
        }
        XCTAssertEqual(storedSubject(), "Test iPhone")
    }

    func testAFileThatIsNoCertificateIsRefused() {
        XCTAssertThrowsError(try ClientCertificateStore.importPKCS12(Data("{\"health\": {}}".utf8), password: "")) { error in
            XCTAssertEqual(error as? ClientCertificateError, .unreadable)
        }
        XCTAssertNil(ClientCertificateStore.identity())
    }

    func testAFileWithoutAPrivateKeyIsRefused() {
        XCTAssertThrowsError(try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.certificateOnly, password: ClientCertificateFixtures.password)) { error in
            XCTAssertEqual(error as? ClientCertificateError, .noIdentity)
        }
        XCTAssertNil(ClientCertificateStore.identity())
    }

    func testAnImportReplacesTheCertificateAndItsKey() throws {
        _ = try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.modern, password: ClientCertificateFixtures.password)
        let firstKey = try applicationLabel(of: XCTUnwrap(ClientCertificateStore.identity()))

        let info = try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.expired, password: "old")

        XCTAssertEqual(info.subject, "Old iPhone")
        XCTAssertEqual(storedSubject(), "Old iPhone")
        XCTAssertEqual(items(kSecClassIdentity).count, 1)
        XCTAssertFalse(privateKeyExists(firstKey), "The replaced certificate's private key stayed behind")
    }

    func testImportingTheSameFileTwiceKeepsOneIdentity() throws {
        _ = try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.modern, password: ClientCertificateFixtures.password)
        _ = try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.legacy, password: ClientCertificateFixtures.password)
        XCTAssertEqual(items(kSecClassIdentity).count, 1)
        XCTAssertEqual(storedSubject(), "Test iPhone")
    }

    // MARK: - Remove

    func testRemoveDeletesTheCertificateAndItsPrivateKey() throws {
        _ = try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.modern, password: ClientCertificateFixtures.password)
        let key = try applicationLabel(of: XCTUnwrap(ClientCertificateStore.identity()))
        XCTAssertTrue(privateKeyExists(key))

        ClientCertificateStore.remove()

        XCTAssertNil(ClientCertificateStore.identity())
        XCTAssertNil(ClientCertificateStore.credential())
        XCTAssertTrue(items(kSecClassCertificate).isEmpty)
        XCTAssertFalse(privateKeyExists(key))
    }

    // MARK: - The challenge

    private final class IgnoringSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func challenge(_ method: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: "ha.example.com", port: 443, protocol: "https", realm: nil, authenticationMethod: method)
        return URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: IgnoringSender()
        )
    }

    func testAServerThatAsksForACertificateGetsTheImportedOneWithItsChain() throws {
        try importFixture()

        let (disposition, credential) = ClientCertificateStore.answer(challenge(NSURLAuthenticationMethodClientCertificate))

        XCTAssertEqual(disposition, .useCredential)
        let identity = try XCTUnwrap(credential?.identity)
        let certificate = try XCTUnwrap(ClientCertificateStore.certificate(of: identity))
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "Test iPhone")
        // The CA from the file travels along, the certificate itself is not repeated.
        let chain = (credential?.certificates as? [SecCertificate]) ?? []
        XCTAssertEqual(chain.compactMap { SecCertificateCopySubjectSummary($0) as String? }, ["Life Dashboard Test CA"])
        XCTAssertEqual(credential?.persistence, URLCredential.Persistence.none)
    }

    func testWithoutACertificateTheHandshakeGoesOnWithoutOne() {
        let (disposition, credential) = ClientCertificateStore.answer(challenge(NSURLAuthenticationMethodClientCertificate))
        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
    }

    /// iOS keeps Keychain items when the app is deleted, UserDefaults it does not: after a
    /// reinstall the row says None, and the identity left behind is not presented.
    func testAnIdentityThatIsNotOnRecordIsNeverPresented() throws {
        _ = try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.modern, password: ClientCertificateFixtures.password)
        XCTAssertNotNil(ClientCertificateStore.identity())

        let (disposition, credential) = ClientCertificateStore.answer(challenge(NSURLAuthenticationMethodClientCertificate))
        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
    }

    func testOtherChallengesAreLeftToIOS() {
        for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodHTTPBasic] {
            let (disposition, credential) = ClientCertificateStore.answer(challenge(method)) {
                XCTFail("The certificate is only read for a client certificate challenge")
                return nil
            }
            XCTAssertEqual(disposition, .performDefaultHandling, method)
            XCTAssertNil(credential)
        }
    }

    func testTheWebhookDelegateAnswersWithTheCertificate() async throws {
        try importFixture()
        let request = URLRequest(url: URL(string: "https://ha.example.com/api/webhook/abc")!)
        let delegate = WebhookTaskDelegate(request: request)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)

        let (disposition, credential) = await delegate.urlSession(session, task: task, didReceive: challenge(NSURLAuthenticationMethodClientCertificate))
        XCTAssertEqual(disposition, .useCredential)
        XCTAssertNotNil(credential?.identity)

        let (trust, none) = await delegate.urlSession(session, task: task, didReceive: challenge(NSURLAuthenticationMethodServerTrust))
        XCTAssertEqual(trust, .performDefaultHandling)
        XCTAssertNil(none)
    }

    // MARK: - A certificate that went missing

    func testOnlyACertificateOnRecordWithoutItsIdentityIsUnavailable() throws {
        XCTAssertNil(ClientCertificateStore.unavailableReason(configured: false))
        XCTAssertEqual(ClientCertificateStore.unavailableReason(configured: true), AppDiagnostic.clientCertificateUnavailable.rawValue)

        _ = try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.modern, password: ClientCertificateFixtures.password)
        XCTAssertNil(ClientCertificateStore.unavailableReason(configured: true))
    }

    /// An iPhone set up from another one's backup: the summary came along, the identity did not.
    /// Nothing is sent, and every URL gets a row that says why, as on Android.
    func testAMissingCertificateSendsNothingAndSaysSoPerURL() async throws {
        PreferencesManager.shared.clientCertificate = ClientCertificateInfo(subject: "Test iPhone", expiresAt: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStub.self]
        let webhooks = WebhookManager(configuration: configuration)
        let host = "h\(UUID().uuidString.prefix(8).lowercased()).redirect-stub"
        let urls = ["https://\(host)/a", "https://\(host)/b"]
        urls.forEach { RedirectStub.route($0, status: 200) }
        defer {
            for row in LogStore.shared.load() where urls.contains(row.url) { LogStore.shared.delete(id: row.id) }
        }

        let delivery = await webhooks.post(
            body: Data("{}".utf8), urls: urls, headers: [:],
            logType: .healthConnect, dataType: "health_connect", recordCount: 1
        )
        XCTAssertEqual(delivery.outcome, .failed, "queued, as for any failure")
        XCTAssertEqual(delivery.error, AppDiagnostic.clientCertificateUnavailable.rawValue)
        let probe = await webhooks.probe(body: Data("{}".utf8), url: urls[0], secret: "secret")
        XCTAssertEqual(probe, .failed(AppDiagnostic.clientCertificateUnavailable.rawValue))
        XCTAssertTrue(RedirectStub.requests(to: host).isEmpty, "nothing was sent without the certificate")
        let rows = LogStore.shared.load().filter { urls.contains($0.url) }
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.errorMessage == AppDiagnostic.clientCertificateUnavailable.rawValue && !$0.success })

        _ = try ClientCertificateStore.importPKCS12(ClientCertificateFixtures.modern, password: ClientCertificateFixtures.password)
        let imported = await webhooks.post(
            body: Data("{}".utf8), urls: urls, headers: [:],
            logType: .healthConnect, dataType: "health_connect", recordCount: 1
        )
        XCTAssertEqual(imported.outcome, .delivered)
    }

    // MARK: - Expiry

    func testTheExpiryDateMatchesWhatIOSReads() throws {
        for (file, password) in [(ClientCertificateFixtures.modern, ClientCertificateFixtures.password), (ClientCertificateFixtures.expired, "old")] {
            var items: CFArray?
            let options = [kSecImportExportPassphrase as String: password] as CFDictionary
            XCTAssertEqual(SecPKCS12Import(file as CFData, options, &items), errSecSuccess)
            let entry = try XCTUnwrap((items as? [[String: Any]])?.first)
            // swiftlint:disable:next force_cast
            let identity = entry[kSecImportItemIdentity as String] as! SecIdentity
            let certificate = try XCTUnwrap(ClientCertificateStore.certificate(of: identity))
            let parsed = ClientCertificateStore.notValidAfter(der: SecCertificateCopyData(certificate) as Data)
            if #available(iOS 18, *) {
                XCTAssertEqual(parsed, SecCertificateCopyNotValidAfterDate(certificate) as Date?)
            }
            XCTAssertNotNil(parsed)
        }
    }

    func testTimesInBothCertificateForms() {
        XCTAssertEqual(ClientCertificateStore.time(tag: 0x17, text: "250101120000Z"), Self.utc(2025, 1, 1, 12))
        XCTAssertEqual(ClientCertificateStore.time(tag: 0x17, text: "491231000000Z"), Self.utc(2049, 12, 31))
        XCTAssertEqual(ClientCertificateStore.time(tag: 0x17, text: "500101000000Z"), Self.utc(1950, 1, 1))
        XCTAssertEqual(ClientCertificateStore.time(tag: 0x18, text: "20510101000000Z"), Self.utc(2051, 1, 1))
        XCTAssertNil(ClientCertificateStore.time(tag: 0x18, text: "20510101000000+0100"))
        XCTAssertNil(ClientCertificateStore.time(tag: 0x04, text: "20510101000000Z"))
        XCTAssertNil(ClientCertificateStore.notValidAfter(der: Data([0x30, 0x03, 0x02, 0x01])))
    }

    func testTheRowWarnsAMonthBeforeTheCertificateExpires() {
        let expiry = Self.utc(2027, 3, 1)
        let info = ClientCertificateInfo(subject: "Test iPhone", expiresAt: expiry)

        XCTAssertFalse(info.needsAttention(at: Self.utc(2027, 1, 15)))
        XCTAssertTrue(info.needsAttention(at: Self.utc(2027, 2, 15)))
        XCTAssertFalse(info.isExpired(at: Self.utc(2027, 2, 28)))
        XCTAssertTrue(info.isExpired(at: expiry))
        XCTAssertFalse(ClientCertificateInfo(subject: "Test iPhone", expiresAt: nil).needsAttention())
    }

    // MARK: - Settings

    func testTheSummaryOutlivesARelaunchButNotTheBackup() throws {
        let name = "client-certificate-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let prefs = PreferencesManager(defaults: defaults, secrets: InMemorySecretStore())
        let info = ClientCertificateInfo(subject: "Test iPhone", expiresAt: Self.utc(2051, 1, 1))
        prefs.clientCertificate = info

        let relaunched = PreferencesManager(defaults: defaults, secrets: InMemorySecretStore())
        XCTAssertEqual(relaunched.clientCertificate, info)
        XCTAssertTrue(relaunched.clientCertificateConfigured)

        // Not in the file, with or without secrets, and an import leaves it alone.
        XCTAssertNotNil(SettingsBackup.notBackedUp["clientCertificate"])
        for includeSecrets in [false, true] {
            let file = try SettingsBackup.encode(SettingsBackup.export(prefs.backupSnapshot(), includeSecrets: includeSecrets, appVersion: nil))
            let text = String(bytes: file, encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains("Test iPhone"))
            XCTAssertFalse(text.lowercased().contains("certificate"))
        }
        relaunched.applyBackup(relaunched.backupSnapshot())
        XCTAssertEqual(relaunched.clientCertificate, info)

        relaunched.clientCertificate = nil
        XCTAssertFalse(relaunched.clientCertificateConfigured)
        XCTAssertNil(PreferencesManager(defaults: defaults, secrets: InMemorySecretStore()).clientCertificate)
    }
}
