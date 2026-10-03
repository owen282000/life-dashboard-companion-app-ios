import Foundation
import Security

/// What the Advanced row shows about the imported client certificate. PreferencesManager keeps
/// it next to the identity in the Keychain, so the row needs no Keychain read, and a summary
/// without its identity tells the sync that the certificate went missing.
struct ClientCertificateInfo: Codable, Equatable, Sendable {
    /// The certificate's subject summary, usually its common name.
    let subject: String
    /// Nil when the certificate's validity could not be read.
    let expiresAt: Date?

    /// How long before the expiry date the row starts to warn.
    static let warningPeriod: TimeInterval = 30 * 86_400

    func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// Expired, or expiring within `warningPeriod`.
    func needsAttention(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < ClientCertificateInfo.warningPeriod
    }
}

enum ClientCertificateError: Error, Equatable {
    case wrongPassword
    /// Not a PKCS #12 file, or one in a format iOS cannot read.
    case unreadable
    /// The file holds certificates but no private key.
    case noIdentity
    case keychain(OSStatus)
}

/// The client certificate (mTLS) presented to webhooks, the iOS side of the Android app's
/// ClientCertSupport.
///
/// iOS has no system certificate picker an app can use: a profile installed in Settings is
/// only for Safari and Apple's own apps. So the user imports a .p12 file with its password, and
/// the identity (certificate and private key) goes into this app's Keychain, readable after the
/// first unlock so background syncs can present it, and ThisDeviceOnly, so it never reaches
/// iCloud Keychain or another device through a backup. The password is used for the import and
/// then forgotten.
///
/// As on Android there is one certificate, presented to every webhook whose server asks for
/// one, background syncs included. MQTT is not affected.
enum ClientCertificateStore {
    /// The label of the identity in the Keychain. The app keeps at most one.
    static let label = "com.owen282000.lifedashboard.client-certificate"
    /// The rest of the file's chain (intermediates), sent along with the certificate.
    private static let chainKey = "client_certificate_chain"

    /// Reads the identity from a PKCS #12 file and stores it in place of the current one.
    /// The current certificate stays when the file cannot be read; when the Keychain refuses the
    /// new one (`keychain`), the current one is already gone.
    static func importPKCS12(_ data: Data, password: String) throws -> ClientCertificateInfo {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        switch status {
        case errSecSuccess: break
        case errSecAuthFailed, errSecPkcs12VerifyFailure: throw ClientCertificateError.wrongPassword
        default: throw ClientCertificateError.unreadable
        }
        let entries = items as? [[String: Any]] ?? []
        guard let entry = entries.first(where: { $0[kSecImportItemIdentity as String] != nil }),
              let identityRef = entry[kSecImportItemIdentity as String],
              CFGetTypeID(identityRef as CFTypeRef) == SecIdentityGetTypeID() else {
            throw ClientCertificateError.noIdentity
        }
        // swiftlint:disable:next force_cast
        let identity = identityRef as! SecIdentity
        guard let certificate = certificate(of: identity) else { throw ClientCertificateError.noIdentity }

        let leaf = SecCertificateCopyData(certificate) as Data
        let chain = (entry[kSecImportItemCertChain as String] as? [SecCertificate] ?? [])
            .map { SecCertificateCopyData($0) as Data }
            .filter { $0 != leaf }

        remove()
        let attributes: [String: Any] = [
            kSecValueRef as String: identity,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw ClientCertificateError.keychain(added) }
        if !chain.isEmpty, let encoded = try? PropertyListEncoder().encode(chain) {
            KeychainStore.setData(encoded, forKey: chainKey, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        }
        return info(for: certificate)
    }

    /// The stored identity, or nil when there is none or the Keychain is locked.
    static func identity() -> SecIdentity? {
        lookup().identity
    }

    private static func lookup() -> (identity: SecIdentity?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecIdentityGetTypeID() else {
            return (nil, status == errSecSuccess ? errSecItemNotFound : status)
        }
        // swiftlint:disable:next force_cast
        let identity = result as! SecIdentity
        return (identity, status)
    }

    /// Why a delivery cannot present the certificate that was imported, as the log stores it;
    /// nil when it can, or when none was imported. `configured` is whether PreferencesManager
    /// has one on record: on an iPhone set up from another one's backup it does, while the
    /// Keychain, which keeps the identity for this device only, does not.
    static func unavailableReason(configured: Bool) -> String? {
        guard configured else { return nil }
        switch lookup().status {
        case errSecSuccess: return nil
        case errSecInteractionNotAllowed: return AppDiagnostic.clientCertificateLocked.rawValue
        default: return AppDiagnostic.clientCertificateUnavailable.rawValue
        }
    }

    /// The credential, only while PreferencesManager has the certificate on record. iOS keeps
    /// Keychain items when the app is deleted, so after a reinstall an identity can be there
    /// that the Advanced row does not show; it is never presented.
    static func recordedCredential() -> URLCredential? {
        PreferencesManager.shared.clientCertificateConfigured ? credential() : nil
    }

    /// What a TLS handshake that asks for a client certificate is answered with.
    static func credential() -> URLCredential? {
        guard let identity = identity() else { return nil }
        let chain = KeychainStore.data(forKey: chainKey)
            .flatMap { try? PropertyListDecoder().decode([Data].self, from: $0) } ?? []
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        return URLCredential(identity: identity, certificates: certificates.isEmpty ? nil : certificates, persistence: .none)
    }

    /// Deletes the identity (certificate and private key) and its chain. False when the
    /// Keychain refused, and the identity may still be there.
    @discardableResult
    static func remove() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label
        ]
        let status = SecItemDelete(query as CFDictionary)
        KeychainStore.removeValue(forKey: chainKey)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func certificate(of identity: SecIdentity) -> SecCertificate? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess else { return nil }
        return certificate
    }

    static func info(for certificate: SecCertificate) -> ClientCertificateInfo {
        let der = SecCertificateCopyData(certificate) as Data
        return ClientCertificateInfo(
            subject: SecCertificateCopySubjectSummary(certificate) as String? ?? "",
            expiresAt: notValidAfter(der: der)
        )
    }

    // MARK: - Answering the challenge

    /// The answer to one authentication challenge of a webhook request: the certificate when
    /// the server asks for one and there is one, iOS's own handling for everything else. Without
    /// a certificate the handshake goes on without one, and the server decides.
    static func answer(
        _ challenge: URLAuthenticationChallenge,
        credential: () -> URLCredential? = ClientCertificateStore.recordedCredential
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
              let credential = credential() else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, credential)
    }

    // MARK: - Reading the expiry date

    /// The certificate's notAfter, read from its DER encoding: iOS 17 has no API for it
    /// (SecCertificateCopyNotValidAfterDate arrived in iOS 18).
    static func notValidAfter(der: Data) -> Date? {
        var certificate = DERReader(Array(der))
        guard let outer = certificate.next(tag: 0x30) else { return nil }
        var body = DERReader(certificate.bytes, outer)
        guard let tbs = body.next(tag: 0x30) else { return nil }
        var fields = DERReader(body.bytes, tbs)
        if fields.peek == 0xA0 { _ = fields.next() } // version
        guard fields.next(tag: 0x02) != nil, // serial number
              fields.next(tag: 0x30) != nil, // signature algorithm
              fields.next(tag: 0x30) != nil, // issuer
              let validity = fields.next(tag: 0x30) else { return nil }
        var times = DERReader(fields.bytes, validity)
        guard times.next() != nil, let notAfter = times.nextElement(),
              let text = String(bytes: fields.bytes[notAfter.content], encoding: .ascii) else { return nil }
        return time(tag: notAfter.tag, text: text)
    }

    /// UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ), the two forms RFC 5280
    /// allows in a certificate.
    static func time(tag: UInt8, text: String) -> Date? {
        let digits: Int
        switch tag {
        case 0x17: digits = 2
        case 0x18: digits = 4
        default: return nil
        }
        guard text.count == digits + 11, text.hasSuffix("Z") else { return nil }
        let numbers = Array(text.dropLast())
        guard numbers.allSatisfy(\.isASCII), numbers.allSatisfy(\.isNumber) else { return nil }
        func field(_ start: Int, _ length: Int) -> Int { Int(String(numbers[start..<(start + length)])) ?? 0 }
        var year = field(0, digits)
        if digits == 2 { year += year >= 50 ? 1900 : 2000 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(
            year: year,
            month: field(digits, 2),
            day: field(digits + 2, 2),
            hour: field(digits + 4, 2),
            minute: field(digits + 6, 2),
            second: field(digits + 8, 2)
        ))
    }
}

/// Walks the elements of one DER-encoded sequence, enough to find a certificate's validity.
private struct DERReader {
    let bytes: [UInt8]
    private var index: Int
    private let end: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        index = 0
        end = bytes.count
    }

    init(_ bytes: [UInt8], _ range: Range<Int>) {
        self.bytes = bytes
        index = range.lowerBound
        end = range.upperBound
    }

    var peek: UInt8? { index < end ? bytes[index] : nil }

    mutating func next(tag: UInt8) -> Range<Int>? {
        guard let element = nextElement(), element.tag == tag else { return nil }
        return element.content
    }

    mutating func next() -> Range<Int>? { nextElement()?.content }

    mutating func nextElement() -> (tag: UInt8, content: Range<Int>)? {
        guard index + 2 <= end else { return nil }
        let tag = bytes[index]
        var position = index + 1
        var length = Int(bytes[position])
        position += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), position + count <= end else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[position])
                position += 1
            }
        }
        guard position + length <= end else { return nil }
        index = position + length
        return (tag, position..<(position + length))
    }
}
