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

/// Which redirects a delivery follows, as Android's WebhookSupport.followableRedirect.
enum WebhookRedirect {
    /// Redirects one delivery follows at most, all on the same host (Apps Script aside, see
    /// `appsScriptAnswer`).
    static let maxRedirects = 5

    /// Where a post to `from` follows a redirect to `target` (already resolved against `from`),
    /// or nil when it must not. The body, the signature and the custom headers go along, so only
    /// the same host is followed: the same port, or http on port 80 moving up to https on 443.
    /// Another host or a step down from https to http is not, because that would reach an
    /// address the user never entered: behind a login proxy it is the login page, which answers
    /// 200 to a request that never reached the webhook.
    static func followable(from: URL, to target: URL) -> URL? {
        guard let fromScheme = from.scheme?.lowercased(),
              let toScheme = target.scheme?.lowercased(),
              toScheme == "http" || toScheme == "https",
              let fromHost = asciiHost(from), let toHost = asciiHost(target),
              fromHost == toHost
        else { return nil }
        if fromScheme == "https" && toScheme == "http" { return nil }
        let fromPort = from.port ?? defaultPort(fromScheme)
        let toPort = target.port ?? defaultPort(toScheme)
        let upgrade = fromScheme == "http" && toScheme == "https" && fromPort == 80 && toPort == 443
        return fromPort == toPort || upgrade ? target : nil
    }

    /// Google's Apps Script hosts, as `host:port`. A parameter only so a test can stand in for
    /// Google; a delivery always uses `.google`.
    struct AppsScriptRule: Sendable {
        let scheme: String
        let scriptHost: String
        let answerHost: String

        static let google = AppsScriptRule(
            scheme: "https", scriptHost: "script.google.com:443", answerHost: "script.googleusercontent.com:443"
        )
    }

    /// The one redirect to another host a delivery accepts, as Android's
    /// WebhookSupport.appsScriptAnswer: a Google Apps Script web app. Its `/exec` URL runs doPost
    /// on the POST itself and then answers 302 with the script's output parked on the answer
    /// host. By then the payload has arrived, so nothing is sent again: the answer is read with
    /// a plain GET, without the body, the signature or the custom headers. Only a 301, 302 or 303
    /// (the ones that become a GET) from a `/macros/` path on the script host to a `/macros/`
    /// path on the answer host counts; a sign-in page, another Google host or anything else does
    /// not, and fails the delivery as before. Nil when this is not that redirect.
    static func appsScriptAnswer(from: URL, status: Int, location: String?, rule: AppsScriptRule = .google) -> URL? {
        guard [301, 302, 303].contains(status),
              let location = location?.trimmingCharacters(in: .whitespaces), !location.isEmpty,
              let target = URL(string: location, relativeTo: from)?.absoluteURL,
              isAt(from, scheme: rule.scheme, hostAndPort: rule.scriptHost),
              isAt(target, scheme: rule.scheme, hostAndPort: rule.answerHost),
              from.path(percentEncoded: true).contains("/macros/"),
              target.path(percentEncoded: true).hasPrefix("/macros/"),
              target.user == nil, target.password == nil
        else { return nil }
        return target
    }

    private static func isAt(_ url: URL, scheme: String, hostAndPort: String) -> Bool {
        guard let urlScheme = url.scheme?.lowercased(), urlScheme == scheme, let host = asciiHost(url) else { return false }
        return "\(host):\(url.port ?? defaultPort(urlScheme))" == hostAndPort.lowercased()
    }

    /// True when an Apps Script web app sent the POST to Google's sign-in page: it is deployed
    /// for signed-in users only, which a phone cannot be.
    static func isAppsScriptSignIn(from: URL?, targetHost: String?) -> Bool {
        guard let from, let fromHost = asciiHost(from) else { return false }
        return fromHost == "script.google.com" && targetHost?.lowercased() == "accounts.google.com"
    }

    /// The log line for a 3xx that was not followed. Names the host it pointed at, so the user
    /// can enter the final address, and says when it was the number of redirects that stopped it.
    /// The host stays percent-encoded, so a Location cannot put a line break into the log.
    static func failureMessage(_ response: HTTPURLResponse, overLimit: Bool) -> String {
        let target = response.value(forHTTPHeaderField: "Location")
            .flatMap { URL(string: $0, relativeTo: response.url)?.absoluteURL }
        guard let host = target?.host(percentEncoded: true), !host.isEmpty else {
            return AppDiagnostic.redirectNotFollowed(response.statusCode, host: nil)
        }
        if isAppsScriptSignIn(from: response.url, targetHost: host) {
            return AppDiagnostic.appsScriptSignIn(response.statusCode)
        }
        return overLimit
            ? AppDiagnostic.tooManyRedirects(response.statusCode, host: host)
            : AppDiagnostic.redirectNotFollowed(response.statusCode, host: host)
    }

    /// The host in lower case, or nil unless it is plain ASCII. Foundation's case-insensitive
    /// comparison folds Unicode (a percent-encoded "ß" matches "ss"), which would let another
    /// host pass as this one; an internationalised name arrives here in its xn-- form anyway.
    private static func asciiHost(_ url: URL) -> String? {
        guard let host = url.host(percentEncoded: true), !host.isEmpty,
              !host.contains("%"), host.unicodeScalars.allSatisfy(\.isASCII)
        else { return nil }
        return host.lowercased()
    }

    private static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }
}
