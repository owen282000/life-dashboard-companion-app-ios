import Foundation
import CryptoKit

enum WebhookSigner {
    /// Builds the X-Signature header value: sha256=<hex of HMAC-SHA256(secret, body)>.
    /// Matches the signing scheme of the Android companion app so servers can verify both.
    static func signatureHeader(for body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        let hex = mac.map { String(format: "%02x", $0) }.joined()
        return "sha256=\(hex)"
    }
}
