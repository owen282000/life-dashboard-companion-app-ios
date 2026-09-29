import CommonCrypto
import CryptoKit
import Foundation
import Security

enum SettingsBackupCryptoError: Error, Equatable {
    /// A wrong password or an edited file: GCM cannot tell the two apart, and neither can the user.
    case wrongPassword
    case notAnEnvelope
    /// An envelope with a version or key derivation this build does not know.
    case unsupported
    case failed
}

/// Password encryption for settings exports that carry secrets, byte-compatible with the
/// Android app's ConfigCrypto so a file moves between the two platforms: AES-256-GCM under a
/// PBKDF2-HMAC-SHA256 key, salt and IV random per export, all in a small JSON envelope.
///
/// Java writes the GCM output as ciphertext followed by the 16-byte tag, which is what goes into
/// `ciphertext` here as well (not CryptoKit's combined nonce-ciphertext-tag layout).
enum SettingsBackupCrypto {
    static let envelopeType = "life-dashboard-encrypted-config"
    /// The envelope's own format version, separate from the settings format inside it.
    static let envelopeVersion = 1
    static let kdf = "PBKDF2WithHmacSHA256"
    static let iterations = 210_000
    /// Android always writes 210000. The bounds keep a crafted file from pinning the CPU for
    /// minutes, or from being brute-forced cheaply because it asked for ten rounds.
    static let acceptedIterations = 100_000...2_000_000

    private static let saltLength = 16
    private static let ivLength = 12
    private static let tagLength = 16

    struct Envelope: Codable, Equatable {
        let type: String
        let version: Int
        let kdf: String
        let iterations: Int
        let salt: String
        let iv: String
        let ciphertext: String
    }

    /// True when the data is an encrypted export. Decodes the `type` key rather than searching
    /// for the marker, so a plain export whose URL happens to contain it is not mistaken for one.
    static func isEnvelope(_ data: Data) -> Bool {
        struct Probe: Decodable { let type: String? }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return false }
        return probe.type == envelopeType
    }

    static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        try encrypt(plaintext, password: password, salt: randomBytes(saltLength), iv: randomBytes(ivLength))
    }

    /// Fixed salt and IV, for the known-answer tests against Android's output.
    static func encrypt(_ plaintext: Data, password: String, salt: Data, iv: Data) throws -> Data {
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: iv))
        let envelope = Envelope(
            type: envelopeType,
            version: envelopeVersion,
            kdf: kdf,
            iterations: iterations,
            salt: salt.base64EncodedString(),
            iv: iv.base64EncodedString(),
            ciphertext: (sealed.ciphertext + sealed.tag).base64EncodedString()
        )
        // Android reads the envelope with a regex, not a JSON parser: an escaped "\/" in the
        // base64 would reach its decoder and fail, so slashes must stay unescaped.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    static func decrypt(_ data: Data, password: String) throws -> Data {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.type == envelopeType else {
            throw SettingsBackupCryptoError.notAnEnvelope
        }
        guard envelope.version <= envelopeVersion,
              envelope.kdf == kdf,
              acceptedIterations.contains(envelope.iterations) else {
            throw SettingsBackupCryptoError.unsupported
        }
        guard let salt = Data(base64Encoded: envelope.salt),
              let iv = Data(base64Encoded: envelope.iv),
              let combined = Data(base64Encoded: envelope.ciphertext),
              salt.count == saltLength, iv.count == ivLength, combined.count >= tagLength else {
            throw SettingsBackupCryptoError.notAnEnvelope
        }

        let key = try deriveKey(password: password, salt: salt, iterations: envelope.iterations)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: iv),
                ciphertext: combined.prefix(combined.count - tagLength),
                tag: combined.suffix(tagLength)
            )
            return try AES.GCM.open(box, using: key)
        } catch {
            throw SettingsBackupCryptoError.wrongPassword
        }
    }

    /// PBKDF2 over the password's UTF-8 bytes, as Java's PBEKeySpec does on both the JDK and
    /// Android, so a password with accents or emoji derives the same key on both platforms.
    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBytes { passwordPointer in
            salt.withUnsafeBytes { saltPointer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPointer.baseAddress?.assumingMemoryBound(to: CChar.self),
                    passwordBytes.count,
                    saltPointer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &key,
                    key.count
                )
            }
        }
        guard status == kCCSuccess else { throw SettingsBackupCryptoError.failed }
        return SymmetricKey(data: key)
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw SettingsBackupCryptoError.failed
        }
        return Data(bytes)
    }
}
