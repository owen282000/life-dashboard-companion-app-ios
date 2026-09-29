import XCTest
@testable import LifeDashboardCompanion

final class WebhookSignerTests: XCTestCase {

    func testKnownHmacVector() {
        // Known answer: HMAC-SHA256("key", "The quick brown fox jumps over the lazy dog")
        let body = Data("The quick brown fox jumps over the lazy dog".utf8)
        let signature = WebhookSigner.signatureHeader(for: body, secret: "key")
        XCTAssertEqual(
            signature,
            "sha256=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
        )
    }

    func testSignatureHasExpectedFormat() {
        let signature = WebhookSigner.signatureHeader(for: Data("{}".utf8), secret: "secret")
        XCTAssertTrue(signature.hasPrefix("sha256="))
        XCTAssertEqual(signature.count, "sha256=".count + 64)
    }

    func testDifferentSecretsProduceDifferentSignatures() {
        let body = Data("payload".utf8)
        XCTAssertNotEqual(
            WebhookSigner.signatureHeader(for: body, secret: "secret-a"),
            WebhookSigner.signatureHeader(for: body, secret: "secret-b")
        )
    }

    func testResponseSignatureMatchesTheIntegration() {
        // HA's test_response_key_is_derived_not_the_secret: the answer is signed with
        // HMAC(secret, "life-dashboard-response-v1"), never with the secret itself.
        let body = Data("The quick brown fox jumps over the lazy dog".utf8)
        let signature = WebhookSigner.responseSignature(for: body, secret: "key")
        XCTAssertEqual(
            signature,
            "sha256=1f5e6e7bf7761bb81dcbbb34f09b6ba176523cdeba9e80d9a28dce3f34791e9b"
        )
        XCTAssertNotEqual(signature, WebhookSigner.signatureHeader(for: body, secret: "key"))
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(WebhookSigner.constantTimeEqual("sha256=ab", "sha256=ab"))
        XCTAssertFalse(WebhookSigner.constantTimeEqual("sha256=ab", "sha256=ac"))
        XCTAssertFalse(WebhookSigner.constantTimeEqual("sha256=ab", "sha256=abc"))
    }

    func testDifferentBodiesProduceDifferentSignatures() {
        XCTAssertNotEqual(
            WebhookSigner.signatureHeader(for: Data("a".utf8), secret: "secret"),
            WebhookSigner.signatureHeader(for: Data("b".utf8), secret: "secret")
        )
    }
}
