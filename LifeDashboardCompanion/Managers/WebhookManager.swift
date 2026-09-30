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
    }

    /// Posts a pre-serialized JSON body to every URL. Takes Data rather than a
    /// dictionary so the payload crosses the actor boundary as a Sendable value.
    /// `logSuccess: false` logs only the URLs that failed: a backfill posts hundreds of chunks,
    /// which would push every other entry out of the log, and writes one summary row instead.
    ///
    /// Which URL gets the custom headers is decided here, per URL, at send time, so every
    /// caller obeys it: an address pairing added gets none. Any new way of posting must go
    /// through this method for that reason.
    func post(
        body jsonData: Data,
        urls: [String],
        headers: [String: String],
        logType: LogType,
        dataType: String,
        recordCount: Int,
        logSuccess: Bool = true
    ) async -> Bool {
        guard !urls.isEmpty else { return false }

        let prefs = PreferencesManager.shared
        let signingSecret = prefs.healthSigningSecret
        let signature = signingSecret.isEmpty
            ? nil
            : WebhookSigner.signatureHeader(for: jsonData, secret: signingSecret)
        let configuredUrls = prefs.healthWebhookUrls
        let urlsWithoutHeaders = prefs.storedUrlsWithoutHeaders

        let rawPayload = String(data: jsonData, encoding: .utf8)
        var anySuccess = false

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
            }

            let log = WebhookLog(
                url: url,
                statusCode: result.statusCode,
                success: result.success,
                errorMessage: result.errorMessage,
                dataType: dataType,
                recordCount: recordCount,
                rawPayload: rawPayload,
                logType: logType
            )
            PreferencesManager.shared.addWebhookLog(log)
        }

        return anySuccess
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
