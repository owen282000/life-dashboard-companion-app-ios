import Foundation
import OSLog
import WidgetKit

final class HealthSyncManager: Sendable {
    static let shared = HealthSyncManager()
    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "HealthSync")

    private let prefs = PreferencesManager.shared
    private let healthKit = HealthKitManager.shared
    private let pendingStore = PendingSyncStore.shared
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

        do {
            let healthData = try await healthKit.readHealthData(for: enabledTypes)

            guard !healthData.isEmpty else {
                return .noData
            }

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

    func performIncrementalSync(types: Set<HealthDataType>) async -> HealthSyncResult {
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

    func drainPendingQueue() async {
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
        let keyToType: [String: HealthDataType] = [
            "steps": .steps, "sleep": .sleep, "heart_rate": .heartRate,
            "distance": .distance, "active_calories": .activeCalories,
            "total_calories": .totalCalories, "weight": .weight, "height": .height,
            "blood_pressure": .bloodPressure, "blood_glucose": .bloodGlucose,
            "oxygen_saturation": .oxygenSaturation, "body_temperature": .bodyTemperature,
            "respiratory_rate": .respiratoryRate, "resting_heart_rate": .restingHeartRate,
            "exercise": .exercise, "hydration": .hydration, "nutrition": .nutrition,
            "mindfulness": .mindfulness, "body_fat": .bodyFat,
            "lean_body_mass": .leanBodyMass, "heart_rate_variability": .heartRateVariability,
            "menstruation_flow": .menstruation
        ]

        for (key, type) in keyToType {
            if let records = data[key] as? [Any] {
                syncCounts[type] = records.count
                total += records.count
            }
        }
        return total
    }
}
