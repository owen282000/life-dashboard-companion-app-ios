import Foundation
import OSLog
import UIKit
import WidgetKit

final class HealthSyncManager: Sendable {
    static let shared = HealthSyncManager()
    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "HealthSync")

    private let prefs = PreferencesManager.shared
    private let healthKit = HealthKitManager.shared
    private let pendingStore = PendingSyncStore.shared
    private let incrementalGate = SingleFlight<HealthDataType>()
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    private init() {}

    // MARK: - Full Sync (all enabled types, always last 7 days)

    func performSync() async -> HealthSyncResult {
        let enabledTypes = prefs.healthEnabledDataTypes
        let webhookUrls = prefs.healthWebhookUrls
        let headers = prefs.healthWebhookHeaders

        guard !enabledTypes.isEmpty, !webhookUrls.isEmpty else {
            return .noData
        }

        // A locked iPhone keeps Health data encrypted, and every read then comes back empty,
        // which used to read as "no data". Say what it is instead, in the result and the log.
        guard await MainActor.run(body: { UIApplication.shared.isProtectedDataAvailable }) else {
            let message = "iPhone is locked, Health data can't be read"
            prefs.addWebhookLog(WebhookLog(
                url: webhookUrls.first ?? "unknown",
                success: false,
                errorMessage: message,
                dataType: "health_connect",
                logType: .healthConnect
            ))
            return .failure(error: message)
        }

        do {
            let healthData = try await healthKit.readHealthData(for: enabledTypes)

            guard !healthData.isEmpty else {
                return .noData
            }

            var payload: [String: Any] = healthData
            payload["timestamp"] = Date().iso8601String
            payload["app_version"] = appVersion
            payload["source"] = "healthkit_ios"

            // Publish latest values to MQTT (Home Assistant Discovery) when configured;
            // failures never block the webhook sync and surface in the MQTT section status.
            await MqttPublisher.shared.publish(healthPayload: healthData)

            var syncCounts: [HealthDataType: Int] = [:]
            let totalRecords = countRecords(in: healthData, syncCounts: &syncCounts)

            guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                return .failure(error: "Failed to serialize payload")
            }

            let success = await WebhookManager.shared.post(
                body: body,
                urls: webhookUrls,
                headers: headers,
                logType: .healthConnect,
                dataType: "health_connect",
                recordCount: totalRecords
            )

            updateWidgetStatus(success: success, records: totalRecords)

            if success {
                return .success(syncCounts: syncCounts)
            } else {
                enqueueBody(body, urls: webhookUrls, headers: headers, totalRecords: totalRecords)
                return .failure(error: "Webhook failed - queued for retry")
            }
        } catch {
            let log = WebhookLog(
                url: webhookUrls.first ?? "unknown",
                success: false,
                errorMessage: error.localizedDescription,
                dataType: "health_connect",
                logType: .healthConnect
            )
            prefs.addWebhookLog(log)
            return .failure(error: error.localizedDescription)
        }
    }

    // MARK: - Incremental Sync (anchor-based, triggered by HKObserverQuery)

    /// One incremental sync at a time. The observer debounce, the refresh task and the
    /// foreground catch-up can all start one; two at once read the same anchors and catch-up
    /// cursors and save them over each other, and a newer anchor without its cursor skips
    /// the records past the cap for good. A caller that finds a sync running hands its types
    /// to it and returns: the running sync reads them in one more round before it ends.
    func performIncrementalSync(types: Set<HealthDataType>) async -> HealthSyncResult {
        guard await incrementalGate.enter(types) else { return .noData }
        var round = types
        var result = HealthSyncResult.noData
        while true {
            result = result.merged(with: await runIncrementalSync(types: round))
            guard let pending = await incrementalGate.next() else { return result }
            round = pending
        }
    }

    private func runIncrementalSync(types: Set<HealthDataType>) async -> HealthSyncResult {
        let webhookUrls = prefs.healthWebhookUrls
        let headers = prefs.healthWebhookHeaders

        guard !types.isEmpty, !webhookUrls.isEmpty else { return .noData }

        do {
            let readResult = try await healthKit.readIncrementalData(for: types)

            switch readResult {
            case .protectedDataUnavailable:
                return .failure(error: "Device locked - data encrypted")
            case .empty:
                return .noData
            case .data(let healthData):
                var payload: [String: Any] = healthData
                payload["timestamp"] = Date().iso8601String
                payload["app_version"] = appVersion
                payload["source"] = "healthkit_ios"

                var syncCounts: [HealthDataType: Int] = [:]
                let totalRecords = countRecords(in: healthData, syncCounts: &syncCounts)

                guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                    return .failure(error: "Failed to serialize payload")
                }

                let success = await WebhookManager.shared.post(
                    body: body,
                    urls: webhookUrls,
                    headers: headers,
                    logType: .healthConnect,
                    dataType: "health_connect",
                    recordCount: totalRecords
                )

                updateWidgetStatus(success: success, records: totalRecords)

                if success {
                    return .success(syncCounts: syncCounts)
                } else {
                    enqueueBody(body, urls: webhookUrls, headers: headers, totalRecords: totalRecords)
                    return .failure(error: "Webhook failed - queued for retry")
                }
            }
        } catch {
            return .failure(error: error.localizedDescription)
        }
    }

    /// Pushes the latest sync result to the app group so the home screen widget stays
    /// current, and tracks the failure streak for the local failure notification.
    private func updateWidgetStatus(success: Bool, records: Int) {
        SharedSyncStatus.record(success: success, records: success ? records : 0)
        WidgetCenter.shared.reloadAllTimelines()
        SyncFailureNotifier.shared.recordResult(success: success, lastError: nil)
    }

    // MARK: - Pending Queue Drain

    private let drainFlight = SingleFlight<Never>()

    /// Delivers what earlier syncs queued, oldest first, one drain at a time.
    func drainPendingQueue() async {
        await drainFlight.run { [self] in
            await drainPendingQueueOnce()
        }
    }

    private func drainPendingQueueOnce() async {
        let items = pendingStore.dequeueAll()
        guard !items.isEmpty else { return }

        logger.info("Draining pending sync queue: \(items.count) item(s)")

        for item in items {
            let success = await WebhookManager.shared.post(
                body: item.payload,
                urls: item.urls,
                headers: item.headers,
                logType: LogType(rawValue: item.logType) ?? .healthConnect,
                dataType: item.dataType,
                recordCount: item.recordCount
            )

            if success {
                pendingStore.remove(id: item.id)
                // A delivered retry is a delivered sync: the widget counts its records and the
                // failure streak ends. A failed retry was already counted when it was queued.
                updateWidgetStatus(success: true, records: item.recordCount)
                logger.info("Pending sync item \(item.id) delivered successfully")
            } else {
                pendingStore.updateAttempt(id: item.id, error: "Retry failed")
                logger.info("Pending sync retry failed, stopping drain")
                break
            }
        }
    }

    // MARK: - Preview

    func buildPreviewPayload() async throws -> [String: Any] {
        let enabledTypes = prefs.healthEnabledDataTypes

        var payload = try await healthKit.readHealthData(for: enabledTypes)
        payload["timestamp"] = Date().iso8601String
        payload["app_version"] = appVersion
        payload["source"] = "healthkit_ios"

        return payload
    }

    // MARK: - Private Helpers

    private func enqueueBody(
        _ body: Data,
        urls: [String],
        headers: [String: String],
        totalRecords: Int
    ) {
        pendingStore.enqueue(
            payload: body,
            urls: urls,
            headers: headers,
            logType: LogType.healthConnect.rawValue,
            dataType: "health_connect",
            recordCount: totalRecords
        )

        logger.info("Enqueued failed sync payload (\(totalRecords) records) for retry")
    }

    private func countRecords(in data: [String: Any], syncCounts: inout [HealthDataType: Int]) -> Int {
        var total = 0
        for type in HealthDataType.allCases {
            if let records = data[type.countedPayloadKey] as? [Any] {
                syncCounts[type] = records.count
                total += records.count
            }
        }
        return total
    }
}

extension HealthSyncResult {
    /// Combines the results of the rounds of one sync: a failure wins, record counts add up.
    func merged(with other: HealthSyncResult) -> HealthSyncResult {
        switch (self, other) {
        case (.failure, _): return self
        case (_, .failure): return other
        case (.noData, _): return other
        case (_, .noData): return self
        case let (.success(first), .success(second)):
            return .success(syncCounts: first.merging(second, uniquingKeysWith: +))
        }
    }
}
