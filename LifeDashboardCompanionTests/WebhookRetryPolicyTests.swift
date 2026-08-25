import XCTest
@testable import LifeDashboardCompanion

final class WebhookRetryPolicyTests: XCTestCase {

    func testNetworkErrorsAreTransient() {
        XCTAssertTrue(WebhookRetryPolicy.isTransient(statusCode: nil))
    }

    func testTimeoutAndRateLimitAreTransient() {
        XCTAssertTrue(WebhookRetryPolicy.isTransient(statusCode: 408))
        XCTAssertTrue(WebhookRetryPolicy.isTransient(statusCode: 429))
    }

    func testServerErrorsAreTransient() {
        XCTAssertTrue(WebhookRetryPolicy.isTransient(statusCode: 500))
        XCTAssertTrue(WebhookRetryPolicy.isTransient(statusCode: 502))
        XCTAssertTrue(WebhookRetryPolicy.isTransient(statusCode: 503))
        XCTAssertTrue(WebhookRetryPolicy.isTransient(statusCode: 599))
    }

    func testPermanentClientErrorsAreNotTransient() {
        XCTAssertFalse(WebhookRetryPolicy.isTransient(statusCode: 400))
        XCTAssertFalse(WebhookRetryPolicy.isTransient(statusCode: 401))
        XCTAssertFalse(WebhookRetryPolicy.isTransient(statusCode: 403))
        XCTAssertFalse(WebhookRetryPolicy.isTransient(statusCode: 404))
        XCTAssertFalse(WebhookRetryPolicy.isTransient(statusCode: 410))
    }

    func testBackoffIsExponential() {
        XCTAssertEqual(WebhookRetryPolicy.backoffDelayNanoseconds(attempt: 1), 1_000_000_000)
        XCTAssertEqual(WebhookRetryPolicy.backoffDelayNanoseconds(attempt: 2), 2_000_000_000)
    }
}
