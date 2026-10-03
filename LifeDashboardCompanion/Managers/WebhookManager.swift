import Foundation

actor WebhookManager {
    static let shared = WebhookManager()

    // 30s accommodates large payloads over cellular connections
    private let timeoutSeconds: TimeInterval = 30

    private init() {}

    struct WebhookResult {
        let url: String
        let statusCode: Int?
        let success: Bool
        let errorMessage: String?
        var interrupted = false
    }

    /// How a post to every URL ended. Interrupted is neither a delivery nor a failure: the
    /// request was cancelled, as when iOS ends a background task, and says nothing about the
    /// receiver. The caller queues the payload as for a failure.
    ///
    /// Refused is a failure where every URL that failed refused the payload itself (see
    /// `WebhookRetryPolicy.refusesPayload`). With one URL down and another refusing, it is a
    /// plain failure, so the queue waits for the one that is down, as Android's does.
    enum Outcome: Equatable {
        case delivered
        case failed
        case refused
        case interrupted

        var delivered: Bool { self == .delivered }
    }

    /// A post's outcome with the error and status code of the last URL that failed, as its log
    /// row stores them (the error in English; `AppDiagnostic.display` translates it).
    struct Delivery: Equatable {
        let outcome: Outcome
        var error: String?
        var statusCode: Int?
        /// The URLs that did not take the payload although another one did. The post counts as
        /// delivered all the same, so nothing is queued for them; this only makes it visible.
        var missedUrls: [String] = []
        /// How many URLs the payload went to.
        var urlCount = 0
        /// A URL failed without an HTTP answer: offline, a name that does not resolve, a
        /// timeout. The retry queue does not drop a payload for its age then.
        var unanswered = false

        var delivered: Bool { outcome.delivered }

        /// Which webhooks this post reached, for the result line and the partial streak.
        var reach: DeliveryReach { DeliveryReach(missed: Set(missedUrls), total: urlCount) }
    }

    /// A cancelled task, as opposed to a receiver or network that failed. URLSession reports a
    /// cancelled task as URLError.cancelled; that code without a cancelled task stays a failure.
    static func isInterruption(_ error: Error, taskCancelled: Bool) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return taskCancelled }
        return false
    }

    /// Posts a pre-serialized JSON body to every URL. Takes Data rather than a
    /// dictionary so the payload crosses the actor boundary as a Sendable value.
    /// `logSuccess: false` logs only the URLs that failed: a backfill posts hundreds of chunks,
    /// which would push every other entry out of the log, and writes one summary row instead.
    ///
    /// Which URL gets the custom headers is decided here, per URL, at send time, so every
    /// caller obeys it: an address pairing added gets none. Any new way of posting must go
    /// through this method for that reason, with the headers configured now: the retry queue
    /// passes the current ones too, not those of the day a payload was queued.
    func post(
        body jsonData: Data,
        urls: [String],
        headers: [String: String],
        logType: LogType,
        dataType: String,
        recordCount: Int,
        logSuccess: Bool = true
    ) async -> Delivery {
        guard !urls.isEmpty else { return Delivery(outcome: .failed) }

        let prefs = PreferencesManager.shared
        let signingSecret = prefs.healthSigningSecret
        let signature = signingSecret.isEmpty
            ? nil
            : WebhookSigner.signatureHeader(for: jsonData, secret: signingSecret)
        let configuredUrls = prefs.healthWebhookUrls
        let urlsWithoutHeaders = prefs.storedUrlsWithoutHeaders

        let rawPayload = String(data: jsonData, encoding: .utf8)
        var anySuccess = false
        var notTaken: [String] = []
        var anyFailed = false
        var anyInterrupted = false
        var allRefused = true
        var anyUnanswered = false
        var lastError: String?
        var lastStatusCode: Int?

        for url in urls {
            var urlHeaders = PairingApply.headers(
                for: url,
                custom: headers,
                configuredUrls: configuredUrls,
                urlsWithoutHeaders: urlsWithoutHeaders
            )
            if let signature {
                urlHeaders["X-Signature"] = signature
            }
            let result = await postWithRetry(
                data: jsonData,
                urlString: url,
                headers: urlHeaders
            )

            if result.success {
                anySuccess = true
                if !logSuccess { continue }
            } else {
                notTaken.append(url)
            }
            if result.interrupted {
                anyInterrupted = true
            } else if !result.success {
                anyFailed = true
                lastError = result.errorMessage
                lastStatusCode = result.statusCode
                allRefused = allRefused && (result.statusCode.map(WebhookRetryPolicy.refusesPayload) ?? false)
                anyUnanswered = anyUnanswered || result.statusCode == nil
            }

            let log = WebhookLog(
                url: url,
                statusCode: result.statusCode,
                success: result.success,
                errorMessage: result.interrupted ? AppDiagnostic.interrupted.rawValue : result.errorMessage,
                dataType: dataType,
                recordCount: recordCount,
                rawPayload: rawPayload,
                logType: logType
            )
            PreferencesManager.shared.addWebhookLog(log)
        }

        // A URL that failed before the cut is a failure of the whole post, as its row says.
        // One URL that took it makes the post delivered, so the others miss this payload for
        // good: they are named, not queued.
        if anySuccess { return Delivery(outcome: .delivered, missedUrls: notTaken, urlCount: urls.count) }
        if anyInterrupted && !anyFailed { return Delivery(outcome: .interrupted, urlCount: urls.count) }
        let outcome: Outcome = allRefused && !anyInterrupted ? .refused : .failed
        return Delivery(outcome: outcome, error: lastError, statusCode: lastStatusCode, urlCount: urls.count, unanswered: anyUnanswered)
    }

    static let atsRefusal = AppDiagnostic.plainHTTPBlocked.rawValue

    /// One signed request to one address, for the check right after pairing: no custom headers,
    /// one attempt, a short timeout, nothing queued. Logged like a Test Ping.
    func probe(body: Data, url urlString: String, secret: String) async -> PairingPingOutcome {
        let signature = WebhookSigner.signatureHeader(for: body, secret: secret)
        var statusCode: Int?
        var answer = Data()
        var answerSignature: String?
        var failure: String?

        if let url = URL(string: urlString) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(signature, forHTTPHeaderField: "X-Signature")
            request.timeoutInterval = 10
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    statusCode = http.statusCode
                    answerSignature = http.value(forHTTPHeaderField: "X-Signature")
                }
                answer = data
            } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
                failure = WebhookManager.atsRefusal
            } catch {
                failure = error.localizedDescription
            }
        } else {
            failure = AppDiagnostic.invalidURL.rawValue
        }

        let outcome = PairingPingOutcome.from(
            statusCode: statusCode,
            body: answer,
            answerSignature: answerSignature,
            requestSignature: signature,
            secret: secret,
            error: failure
        )
        let delivered = outcome == .confirmed || outcome == .deliveredUnconfirmed
        PreferencesManager.shared.addWebhookLog(WebhookLog(
            url: urlString,
            statusCode: statusCode,
            success: delivered,
            errorMessage: delivered ? nil : (failure ?? statusCode.map(AppDiagnostic.http)),
            dataType: "test",
            recordCount: 0,
            rawPayload: String(data: body, encoding: .utf8),
            logType: .healthConnect
        ))
        return outcome
    }

    private func postWithRetry(
        data: Data,
        urlString: String,
        headers: [String: String]
    ) async -> WebhookResult {
        var lastError: String?
        var lastStatusCode: Int?

        for attempt in 0..<WebhookRetryPolicy.maxAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: WebhookRetryPolicy.backoffDelayNanoseconds(attempt: attempt))
            }

            do {
                guard let url = URL(string: urlString) else {
                    return WebhookResult(url: urlString, statusCode: nil, success: false, errorMessage: AppDiagnostic.invalidURL.rawValue)
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = data
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = timeoutSeconds

                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }

                let (_, response) = try await URLSession.shared.data(for: request)

                if let httpResponse = response as? HTTPURLResponse {
                    lastStatusCode = httpResponse.statusCode
                    if (200...299).contains(httpResponse.statusCode) {
                        return WebhookResult(
                            url: urlString,
                            statusCode: httpResponse.statusCode,
                            success: true,
                            errorMessage: nil
                        )
                    } else {
                        lastError = AppDiagnostic.http(httpResponse.statusCode)
                        if !WebhookRetryPolicy.isTransient(statusCode: httpResponse.statusCode) {
                            // Permanent client error: retrying will not help
                            break
                        }
                    }
                }
            } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
                // No retry can change this: iOS refuses plain HTTP to this host on every attempt.
                lastError = WebhookManager.atsRefusal
                break
            } catch where WebhookManager.isInterruption(error, taskCancelled: Task.isCancelled) {
                // Every attempt after this one would be cancelled as well. An attempt that
                // already failed keeps this delivery a failure, with that attempt's error.
                if let lastError {
                    return WebhookResult(url: urlString, statusCode: lastStatusCode, success: false, errorMessage: lastError)
                }
                return WebhookResult(url: urlString, statusCode: nil, success: false, errorMessage: nil, interrupted: true)
            } catch {
                lastError = error.localizedDescription
            }
        }

        return WebhookResult(
            url: urlString,
            statusCode: lastStatusCode,
            success: false,
            errorMessage: lastError ?? AppDiagnostic.unknownAfterAttempts(WebhookRetryPolicy.maxAttempts)
        )
    }
}
