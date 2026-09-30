import Foundation

enum WebhookRetryPolicy {
    static let maxAttempts = 3

    /// Transient failures (network errors, timeouts, HTTP 408, 429, 5xx) are worth retrying.
    /// Permanent client errors (401, 404, ...) fail immediately without retrying.
    static func isTransient(statusCode: Int?) -> Bool {
        guard let code = statusCode else { return true }
        switch code {
        case 408, 429:
            return true
        case 500...599:
            return true
        default:
            return false
        }
    }

    /// A refusal of the payload itself, as Android's WebhookSupport.refusesPayload: malformed
    /// (400), too large (413) or not accepted (422). Sending it again unchanged gets the same
    /// answer, so the retry queue skips it instead of waiting behind it.
    static func refusesPayload(statusCode: Int) -> Bool {
        statusCode == 400 || statusCode == 413 || statusCode == 422
    }

    /// Exponential backoff before retry attempts: 1s before the second, 2s before the third.
    static func backoffDelayNanoseconds(attempt: Int) -> UInt64 {
        1_000_000_000 * UInt64(1 << (attempt - 1))
    }
}
