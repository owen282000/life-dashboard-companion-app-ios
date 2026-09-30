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
    private let deletionStore = DeletionStore.shared
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    private init() {}

    // MARK: - Full Sync (all enabled types, always last 7 days)

    func performSync() async -> HealthSyncResult {
        let enabledTypes = prefs.healthEnabledDataTypes
        let webhookUrls = prefs.healthWebhookUrls
        let headers = prefs.healthWebhookHeaders

        guard !enabledTypes.isEmpty, !webhookUrls.isEmpty || prefs.mqttConfigured else {
            return .noData
        }

        // A locked iPhone keeps Health data encrypted, and every read then comes back empty,
        // which used to read as "no data". Say what it is instead, in the result and the log,
        // as a read failure: no webhook was contacted.
        guard await MainActor.run(body: { UIApplication.shared.isProtectedDataAvailable }) else {
            let message = AppDiagnostic.healthLocked.rawValue
            prefs.addWebhookLog(WebhookLog(
                url: SyncStats.readFailureSource,
                success: false,
                errorMessage: message,
                dataType: WebhookLog.readFailureDataType,
                logType: .healthConnect
            ))
            return .failure(error: message)
        }

        guard !webhookUrls.isEmpty else {
            do {
                let healthData = try await healthKit.readHealthData(for: enabledTypes)
                return await publishOnly(healthData, sensorsFrom: healthData)
            } catch {
                return readFailed(error)
            }
        }

        let readGeneration = await DeletionStep.run(for: enabledTypes)

        do {
            let healthData = try await healthKit.readHealthData(for: enabledTypes)

            guard !healthData.isEmpty else {
                return await postDeletionsOnly(readGeneration: readGeneration, urls: webhookUrls, headers: headers) ?? .noData
            }

            var payload: [String: Any] = healthData
            payload["timestamp"] = Date().iso8601String
            payload["app_version"] = appVersion
            payload["source"] = "healthkit_ios"
            let deletions = await attachDeletions(to: &payload, records: healthData, readGeneration: readGeneration)
            let totalsDay = await attachDailyTotals(to: &payload, types: enabledTypes)

            // Publish latest values to MQTT (Home Assistant Discovery) when configured;
            // failures never block the webhook sync and surface in the MQTT section status.
            await MqttPublisher.shared.publish(healthPayload: healthData)

            var syncCounts: [HealthDataType: Int] = [:]
            let totalRecords = countRecords(in: healthData, syncCounts: &syncCounts)

            guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                return .failure(error: AppDiagnostic.serializeFailed.rawValue)
            }

            let outcome = await WebhookManager.shared.post(
                body: body,
                urls: webhookUrls,
                headers: headers,
                logType: .healthConnect,
                dataType: "health_connect",
                recordCount: totalRecords
            )

            updateWidgetStatus(outcome, records: totalRecords)

            if outcome.delivered {
                await deletionStore.remove(deletions.carried)
                return .success(syncCounts: syncCounts)
            } else {
                if enqueueBody(queuedBody(body, payload: payload, totalsDay: totalsDay), urls: webhookUrls, headers: headers, totalRecords: totalRecords) {
                    await deletionStore.remove(deletions.carried)
                }
                return .failure(error: AppDiagnostic.queuedForRetry.rawValue)
            }
        } catch {
            return readFailed(error)
        }
    }

    /// Reading failed before anything was sent, so the row names Apple Health and not a
    /// webhook URL or a broker that was never contacted.
    private func readFailed(_ error: Error) -> HealthSyncResult {
        let log = WebhookLog(
            url: SyncStats.readFailureSource,
            success: false,
            errorMessage: error.localizedDescription,
            dataType: WebhookLog.readFailureDataType,
            logType: .healthConnect
        )
        prefs.addWebhookLog(log)
        return .failure(error: error.localizedDescription)
    }

    /// A sync with the MQTT broker and no webhook URL, as on Android: the latest value of each
    /// type goes to the broker, and nothing is posted or queued. Deletions are not read, since a
    /// sensor holds one value and has no record to withdraw, and a deletion that no webhook
    /// takes would wait in the store for good.
    ///
    /// A broker that cannot be reached fails the sync and shows on the widget. It does not add
    /// to the failure notification's streak, whose text is about webhooks and a retry queue
    /// that MQTT does not have; the MQTT status and the Logs tab carry the error.
    private func publishOnly(_ healthData: [String: Any], sensorsFrom sensorData: [String: Any]) async -> HealthSyncResult {
        guard !healthData.isEmpty else { return .noData }
        var syncCounts: [HealthDataType: Int] = [:]
        let totalRecords = countRecords(in: healthData, syncCounts: &syncCounts)
        if let error = await MqttPublisher.shared.publish(healthPayload: sensorData) {
            // Cut off by iOS: the widget keeps the last sync that finished.
            if error != AppDiagnostic.interrupted.rawValue {
                SharedSyncStatus.record(success: false, records: 0)
                WidgetCenter.shared.reloadAllTimelines()
            }
            return .failure(error: error)
        }
        updateWidgetStatus(.delivered, records: totalRecords)
        return .success(syncCounts: syncCounts)
    }

    // MARK: - Incremental Sync (anchor-based, every automatic sync and the Shortcuts action)

    /// One incremental sync at a time. Two at once read the same anchors and catch-up cursors
    /// and save them over each other, and a newer anchor without its cursor skips the records
    /// past the cap for good. A caller that finds a sync running hands its types to it and
    /// returns: the running sync reads them in one more round before it ends.
    ///
    /// Callers go through SyncCoordinator, whose one flight already keeps syncs apart; this
    /// gate holds the anchors safe for any caller that does not.
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

        guard !types.isEmpty, !webhookUrls.isEmpty || prefs.mqttConfigured else { return .noData }

        guard !webhookUrls.isEmpty else {
            do {
                switch try await healthKit.readIncrementalData(for: types) {
                case .protectedDataUnavailable:
                    return .failure(error: AppDiagnostic.deviceLocked.rawValue)
                case .empty:
                    return .noData
                case .data(let healthData):
                    return await publishOnly(healthData, sensorsFrom: caughtUp(healthData, types: types))
                }
            } catch {
                return .failure(error: error.localizedDescription)
            }
        }

        // Deletions are read for every enabled type, not only the ones an observer named: the
        // step costs milliseconds, and every read shortens the time HealthKit could forget one.
        let readGeneration = await DeletionStep.run(for: prefs.healthEnabledDataTypes.union(types))

        do {
            let readResult = try await healthKit.readIncrementalData(for: types)

            switch readResult {
            case .protectedDataUnavailable:
                return .failure(error: AppDiagnostic.deviceLocked.rawValue)
            case .empty:
                return await postDeletionsOnly(readGeneration: readGeneration, urls: webhookUrls, headers: headers) ?? .noData
            case .data(let healthData):
                var payload: [String: Any] = healthData
                payload["timestamp"] = Date().iso8601String
                payload["app_version"] = appVersion
                payload["source"] = "healthkit_ios"
                let deletions = await attachDeletions(to: &payload, records: healthData, readGeneration: readGeneration)
                let totalsDay = await attachDailyTotals(to: &payload, types: prefs.healthEnabledDataTypes)

                var syncCounts: [HealthDataType: Int] = [:]
                let totalRecords = countRecords(in: healthData, syncCounts: &syncCounts)

                guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                    return .failure(error: AppDiagnostic.serializeFailed.rawValue)
                }

                let outcome = await WebhookManager.shared.post(
                    body: body,
                    urls: webhookUrls,
                    headers: headers,
                    logType: .healthConnect,
                    dataType: "health_connect",
                    recordCount: totalRecords
                )

                updateWidgetStatus(outcome, records: totalRecords)

                let result: HealthSyncResult
                if outcome.delivered {
                    await deletionStore.remove(deletions.carried)
                    result = .success(syncCounts: syncCounts)
                } else {
                    if enqueueBody(queuedBody(body, payload: payload, totalsDay: totalsDay), urls: webhookUrls, headers: headers, totalRecords: totalRecords) {
                        await deletionStore.remove(deletions.carried)
                    }
                    result = .failure(error: AppDiagnostic.queuedForRetry.rawValue)
                }

                // Last, once the webhook's payload is delivered or queued: a HealthKit wakeup's
                // time budget is for that first. New records only, so a type without any keeps
                // its retained value on the broker.
                if !Task.isCancelled {
                    await MqttPublisher.shared.publish(healthPayload: caughtUp(healthData, types: types))
                }
                return result
            }
        } catch {
            return .failure(error: error.localizedDescription)
        }
    }

    /// What an incremental read gives MQTT: the types that have caught up. A type whose read
    /// stopped at the cap, oldest first, has newer records still to come, and its sensor would
    /// show an old value as the current one; it is published once the reads have caught up.
    private func caughtUp(_ healthData: [String: Any], types: Set<HealthDataType>) -> [String: Any] {
        var payload = healthData
        for type in types where prefs.loadCatchUpCursor(for: type) != nil {
            payload.removeValue(forKey: type.countedPayloadKey)
        }
        return payload
    }

    /// Pushes the latest sync result to the app group so the home screen widget stays
    /// current, and tracks the failure streak for the local failure notification. An
    /// interrupted delivery changes neither: it is queued, and its retry counts.
    private func updateWidgetStatus(_ outcome: WebhookManager.Outcome, records: Int) {
        guard outcome != .interrupted else { return }
        let success = outcome.delivered
        SharedSyncStatus.record(success: success, records: success ? records : 0)
        WidgetCenter.shared.reloadAllTimelines()
        SyncFailureNotifier.shared.recordResult(success: success, lastError: nil)
    }

    // MARK: - Pending Queue Drain

    private let drainFlight = SingleFlight<Never>()

    /// Delivers what earlier syncs queued, oldest first, one drain at a time. Called through
    /// SyncCoordinator; the drain's own flight still keeps a payload from going out twice
    /// should anything else call it.
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
            // An address removed since this was queued gets nothing more; with none left, the
            // item is done. The next full sync resends its window anyway.
            let urls = PairingApply.deliverable(item.urls, configuredUrls: prefs.healthWebhookUrls)
            guard !urls.isEmpty else {
                pendingStore.remove(id: item.id)
                continue
            }
            let outcome = await WebhookManager.shared.post(
                body: item.payload,
                urls: urls,
                headers: item.headers,
                logType: LogType(rawValue: item.logType) ?? .healthConnect,
                dataType: item.dataType,
                recordCount: item.recordCount
            )

            switch outcome {
            case .delivered:
                pendingStore.remove(id: item.id)
                // A delivered retry is a delivered sync: the widget counts its records and the
                // failure streak ends. A failed retry was already counted when it was queued.
                updateWidgetStatus(.delivered, records: item.recordCount)
                logger.info("Pending sync item \(item.id) delivered successfully")
            case .interrupted:
                // Not an attempt: the item keeps its 20 tries for a receiver that answers.
                logger.info("Pending sync retry interrupted, stopping drain")
                return
            case .failed:
                pendingStore.updateAttempt(id: item.id, error: AppDiagnostic.retryFailed.rawValue)
                logger.info("Pending sync retry failed, stopping drain")
                return
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
        await attachDailyTotals(to: &payload, types: enabledTypes)

        return payload
    }

    // MARK: - Deletions

    /// Puts the pending deletions on a payload, minus any uuid the payload carries as a record.
    /// They leave the store only once the payload is delivered or in the outbox.
    private func attachDeletions(
        to payload: inout [String: Any],
        records: [String: Any],
        readGeneration: Int
    ) async -> DeletionPlan {
        let plan = await deletionStore.plan(
            readIds: DeletionTracking.recordUUIDs(in: records),
            readGeneration: readGeneration
        )
        payload.merge(DeletionTracking.payloadFields(plan.summary)) { current, _ in current }
        return plan
    }

    /// A deletion is often the only change, as when a meal is removed and nothing is added.
    /// Such a sync sends a payload with the deletions and no records, and reports it as a
    /// delivery of 0 records. Nil when there is nothing to send.
    private func postDeletionsOnly(readGeneration: Int, urls: [String], headers: [String: String]) async -> HealthSyncResult? {
        var payload: [String: Any] = [
            "timestamp": Date().iso8601String,
            "app_version": appVersion,
            "source": "healthkit_ios"
        ]
        let deletions = await attachDeletions(to: &payload, records: [:], readGeneration: readGeneration)
        guard !deletions.summary.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }

        let outcome = await WebhookManager.shared.post(
            body: body,
            urls: urls,
            headers: headers,
            logType: .healthConnect,
            dataType: "health_connect",
            recordCount: 0
        )
        updateWidgetStatus(outcome, records: 0)

        if outcome.delivered {
            await deletionStore.remove(deletions.carried)
            return .success(syncCounts: [:])
        }
        if enqueueBody(body, urls: urls, headers: headers, totalRecords: 0) {
            await deletionStore.remove(deletions.carried)
        }
        return .failure(error: AppDiagnostic.queuedForRetry.rawValue)
    }

    // MARK: - Daily Totals

    /// Puts the totals of today and the two days before on the payload when the setting is on,
    /// for every enabled type, not only the ones whose observer fired. Returns the day they were
    /// built on, nil when the payload carries none.
    @discardableResult
    private func attachDailyTotals(to payload: inout [String: Any], types: Set<HealthDataType>) async -> String? {
        guard prefs.includeDailyTotals else { return nil }
        let calendar = DailyTotals.calendar()
        let now = Date()
        let totals = await healthKit.readDailyTotals(
            in: DailyTotals.window(now: now, calendar: calendar),
            enabledTypes: types,
            calendar: calendar
        )
        guard !totals.isEmpty else { return nil }
        payload[DailyTotals.payloadKey] = totals
        return DailyTotals.dateString(now, calendar: calendar)
    }

    /// The body a failed payload waits in the retry queue with, see DailyTotals.forQueue.
    private func queuedBody(_ body: Data, payload: [String: Any], totalsDay: String?) -> Data {
        guard let totalsDay else { return body }
        let queued = DailyTotals.forQueue(payload, builtOn: totalsDay)
        return (try? JSONSerialization.data(withJSONObject: queued, options: [.sortedKeys])) ?? body
    }

    // MARK: - Private Helpers

    @discardableResult
    private func enqueueBody(
        _ body: Data,
        urls: [String],
        headers: [String: String],
        totalRecords: Int
    ) -> Bool {
        let queued = pendingStore.enqueue(
            payload: body,
            urls: urls,
            headers: headers,
            logType: LogType.healthConnect.rawValue,
            dataType: "health_connect",
            recordCount: totalRecords
        )

        logger.info("Enqueued failed sync payload (\(totalRecords) records) for retry")
        return queued
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
