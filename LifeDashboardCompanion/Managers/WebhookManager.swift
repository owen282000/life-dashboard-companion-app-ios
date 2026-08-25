import Foundation

actor WebhookManager {
    static let shared = WebhookManager()

    private let timeoutSeconds: TimeInterval = 10

    private init() {}

    struct WebhookResult {
        let url: String
        let statusCode: Int?
        let success: Bool
        let errorMessage: String?
    }

    func post(
        payload: [String: Any],
        urls: [String],
        headers: [String: String],
        logType: LogType,
        dataType: String,
        recordCount: Int
    ) async -> Bool {
        guard !urls.isEmpty else { return false }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return false
        }

        var allHeaders = headers
        let signingSecret = PreferencesManager.shared.healthSigningSecret
        if !signingSecret.isEmpty {
            allHeaders["X-Signature"] = WebhookSigner.signatureHeader(for: jsonData, secret: signingSecret)
        }

        let rawPayload = String(data: jsonData, encoding: .utf8)
        var anySuccess = false

        for url in urls {
            let result = await postWithRetry(
                data: jsonData,
                urlString: url,
                headers: allHeaders
            )

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

            if result.success {
                anySuccess = true
            }
        }

        return anySuccess
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
                    return WebhookResult(url: urlString, statusCode: nil, success: false, errorMessage: "Invalid URL")
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
                        lastError = "HTTP \(httpResponse.statusCode)"
                        if !WebhookRetryPolicy.isTransient(statusCode: httpResponse.statusCode) {
                            // Permanent client error: retrying will not help
                            break
                        }
                    }
                }
            } catch {
                lastError = error.localizedDescription
            }
        }

        return WebhookResult(
            url: urlString,
            statusCode: lastStatusCode,
            success: false,
            errorMessage: lastError ?? "Unknown error after \(WebhookRetryPolicy.maxAttempts) attempts"
        )
    }
}
