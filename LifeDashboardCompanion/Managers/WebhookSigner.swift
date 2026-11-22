import Foundation
import CryptoKit

enum WebhookSigner {
    /// Builds the X-Signature header value: sha256=<hex of HMAC-SHA256(secret, body)>.
    /// Matches the signing scheme of the Android companion app so servers can verify both.
    static func signatureHeader(for body: Data, secret: String) -> String {
        signature(for: body, key: SymmetricKey(data: Data(secret.utf8)))
    }

    /// The label the Life Dashboard integration derives its answer key with. The answer is
    /// signed with HMAC(secret, label) rather than the secret, so a captured request can never
    /// be played back as an answer.
    static let responseKeyLabel = "life-dashboard-response-v1"

    /// The key the integration signs its answers with: HMAC(secret, label).
    static func responseKey(secret: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(responseKeyLabel.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        ))
    }

    /// What the signature of the integration's answer must be, over its raw bytes: in the
    /// X-Signature header, or inside a signed body over the text of `answer`.
    static func responseSignature(for body: Data, secret: String) -> String {
        signature(for: body, key: SymmetricKey(data: responseKey(secret: secret)))
    }

    /// Compares two signatures without stopping at the first differing byte.
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private static func signature(for body: Data, key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        return "sha256=\(hex)"
    }
}
