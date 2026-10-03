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
                return await publishOnly(healthData, sensorsFrom: await healthKit.newestRecords(for: enabledTypes, in: healthData))
            } catch {
                return readFailed(error)
            }
        }

        let readGeneration = await DeletionStep.run(for: enabledTypes)

        do {
            let healthData = try await healthKit.readHealthData(for: enabledTypes)

            guard !healthData.isEmpty else {
                return await postDeletionsOnly(readGeneration: readGeneration, urls: webhookUrls, headers: headers, commit: nil) ?? .noData
            }

            var payload: [String: Any] = healthData
            payload["timestamp"] = Date().iso8601String
            payload["app_version"] = appVersion
            payload["source"] = "healthkit_ios"
            let deletions = await attachDeletions(to: &payload, records: healthData, readGeneration: readGeneration)
            let totalsDay = await attachDailyTotals(to: &payload, types: enabledTypes)
            var noCommit: AnchorCommit?
            let resolved = resolveSeries(in: &payload, commit: &noCommit, notCurrent: [])

            // Publish latest values to MQTT (Home Assistant Discovery) when configured;
            // failures never block the webhook sync and surface in the MQTT section status.
            if prefs.mqttConfigured {
                let newest = await healthKit.newestRecords(for: enabledTypes, in: healthData)
                await MqttPublisher.shared.publish(healthPayload: withDailyTotals(newest, from: payload))
            }

            var syncCounts: [HealthDataType: Int] = [:]
            let totalRecords = countRecords(in: healthData, syncCounts: &syncCounts)
            if resolved.leavesNothingToSend(of: totalRecords) {
                return await postDeletionsOnly(
                    readGeneration: readGeneration, urls: webhookUrls, headers: headers, commit: nil, records: healthData
                ).map { $0.counting(syncCounts) } ?? .success(syncCounts: syncCounts)
            }

            let outcome = await send(
                payload, totalsDay: totalsDay, recordCount: totalRecords,
                urls: webhookUrls, headers: headers, deletions: deletions, commit: nil
            )
            guard let outcome else { return .failure(error: AppDiagnostic.serializeFailed.rawValue) }
            return outcome.delivered
                ? .success(syncCounts: syncCounts, reach: outcome.reach)
                : .failure(error: AppDiagnostic.queuedForRetry.rawValue)
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
        updateWidgetStatus(WebhookManager.Delivery(outcome: .delivered), records: totalRecords)
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
                // MQTT keeps no queue to write ahead to: a sensor holds the latest value, and a
                // publish that fails is not retried, so the anchors are saved as soon as the
                // read is done.
                switch try await healthKit.readIncrementalData(for: types) {
                case .protectedDataUnavailable:
                    return .failure(error: AppDiagnostic.deviceLocked.rawValue)
                case .empty(let commit):
                    commit.save()
                    return .noData
                case .data(let healthData, let commit, let notCurrent):
                    commit.save()
                    return await publishOnly(healthData, sensorsFrom: current(healthData, leaving: notCurrent))
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
            case .empty(let commit):
                guard let result = await postDeletionsOnly(
                    readGeneration: readGeneration, urls: webhookUrls, headers: headers, commit: commit
                ) else {
                    commit.save()
                    return .noData
                }
                return result
            case .data(let healthData, let readCommit, let notCurrent):
                var payload: [String: Any] = healthData
                payload["timestamp"] = Date().iso8601String
                payload["app_version"] = appVersion
                payload["source"] = "healthkit_ios"
                let deletions = await attachDeletions(to: &payload, records: healthData, readGeneration: readGeneration)
                let totalsDay = await attachDailyTotals(to: &payload, types: prefs.healthEnabledDataTypes)
                var resolvedCommit: AnchorCommit? = readCommit
                let resolved = resolveSeries(in: &payload, commit: &resolvedCommit, notCurrent: notCurrent)
                let commit = resolvedCommit ?? readCommit

                var syncCounts: [HealthDataType: Int] = [:]
                let totalRecords = countRecords(in: healthData, syncCounts: &syncCounts)
                // Every record went into a window still filling: nothing to post, as on Android.
                // The anchors and the carry are saved together, or go with the deletions.
                if resolved.leavesNothingToSend(of: totalRecords) {
                    guard let result = await postDeletionsOnly(
                        readGeneration: readGeneration, urls: webhookUrls, headers: headers, commit: commit, records: healthData
                    ) else {
                        commit.save()
                        return .success(syncCounts: syncCounts)
                    }
                    return result.counting(syncCounts)
                }

                let outcome = await send(
                    payload, totalsDay: totalsDay, recordCount: totalRecords,
                    urls: webhookUrls, headers: headers, deletions: deletions, commit: commit
                )
                guard let outcome else { return .failure(error: AppDiagnostic.serializeFailed.rawValue) }
                let result: HealthSyncResult = outcome.delivered
                    ? .success(syncCounts: syncCounts, reach: outcome.reach)
                    : .failure(error: AppDiagnostic.queuedForRetry.rawValue)

                // Last, once the webhook's payload is delivered or queued: a HealthKit wakeup's
                // time budget is for that first. New records only, so a type without any keeps
                // its retained value on the broker.
                if !Task.isCancelled {
                    await MqttPublisher.shared.publish(healthPayload: withDailyTotals(current(healthData, leaving: notCurrent), from: payload))
                }
                return result
            }
        } catch {
            return .failure(error: error.localizedDescription)
        }
    }

    /// MQTT's today sensors come from `daily_totals`; one the webhook payload already carries
    /// spares the publisher a statistics query of its own.
    private func withDailyTotals(_ mqtt: [String: Any], from payload: [String: Any]) -> [String: Any] {
        var copy = mqtt
        if let totals = payload[DailyTotals.payloadKey] { copy[DailyTotals.payloadKey] = totals }
        return copy
    }

    /// What an incremental read gives MQTT: the types whose records include their newest
    /// sample. A type whose read stopped at the cap has newer records still to come, and a
    /// back-dated entry is older than what the sensor shows; either would put an old value on
    /// the broker as the current one. Such a type is published once a read holds its newest.
    private func current(_ healthData: [String: Any], leaving notCurrent: Set<HealthDataType>) -> [String: Any] {
        var payload = healthData
        for type in notCurrent {
            payload.removeValue(forKey: type.countedPayloadKey)
        }
        return payload
    }

    /// Pushes the latest sync result to the app group so the home screen widget stays
    /// current, and tracks the failure streak and the partial streak for the local
    /// notifications. An interrupted delivery changes none of them: it is queued, and its
    /// retry counts.
    private func updateWidgetStatus(_ delivery: WebhookManager.Delivery, records: Int) {
        guard delivery.outcome != .interrupted else { return }
        let success = delivery.delivered
        SharedSyncStatus.record(success: success, records: success ? records : 0)
        WidgetCenter.shared.reloadAllTimelines()
        // The notification is read in the phone's language; the row keeps the English text.
        SyncFailureNotifier.shared.recordResult(success: success, lastError: delivery.error.map(AppDiagnostic.display))
        SyncFailureNotifier.shared.recordReach(delivered: success, missedUrls: delivery.missedUrls)
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

    /// Delivers the queue (see `QueueDrain`), and reports what it dropped.
    private func drainPendingQueueOnce() async {
        let items = pendingStore.dequeueAll()
        guard !items.isEmpty else { return }

        logger.info("Draining pending sync queue: \(items.count) item(s)")

        let prefs = self.prefs
        let pendingStore = self.pendingStore
        let logger = self.logger
        var dropped: [(PendingSyncItem, QueueDrop)] = []
        await QueueDrain(
            now: Date(),
            urls: { prefs.healthWebhookUrls },
            headers: { prefs.healthWebhookHeaders },
            post: { item, urls, headers in
                await WebhookManager.shared.post(
                    body: item.payload,
                    urls: urls,
                    headers: headers,
                    logType: LogType(rawValue: item.logType) ?? .healthConnect,
                    dataType: item.dataType,
                    recordCount: item.recordCount
                )
            },
            remove: { pendingStore.remove(id: $0.id) },
            attempt: { item, delivery in
                pendingStore.updateAttempt(id: item.id, error: delivery.error, statusCode: delivery.statusCode)
                logger.info("Pending sync item \(item.id) not delivered: \(delivery.error ?? "", privacy: .public)")
            },
            // A delivered retry is a delivered sync: the widget counts its records and the
            // failure streak ends. A failed retry was already counted when it was queued.
            delivered: { item, delivery in self.updateWidgetStatus(delivery, records: item.recordCount) },
            dropped: { dropped.append(($0, $1)) }
        ).run(items)
        reportDropped(dropped)
    }

    /// A payload dropped from the queue takes its records with it: the anchors moved past them
    /// when it was queued. Each gets a failed row in the log, with its payload, and one
    /// notification says how many went.
    private func reportDropped(_ dropped: [(PendingSyncItem, QueueDrop)]) {
        guard !dropped.isEmpty else { return }
        for (item, reason) in dropped {
            prefs.addWebhookLog(PendingSyncStore.droppedLog(for: item, reason: reason))
        }
        logger.error("Dropped \(dropped.count) undelivered payload(s) older than a week from the queue")
        SyncFailureNotifier.shared.notifyDropped(count: dropped.count)
    }

    // MARK: - Preview

    func buildPreviewPayload() async throws -> [String: Any] {
        let enabledTypes = prefs.healthEnabledDataTypes

        var payload = try await healthKit.readHealthData(for: enabledTypes)
        payload["timestamp"] = Date().iso8601String
        payload["app_version"] = appVersion
        payload["source"] = "healthkit_ios"
        await attachDailyTotals(to: &payload, types: enabledTypes)
        // What Sync Now would send, so bucketed the same way; it stores nothing.
        var noCommit: AnchorCommit?
        resolveSeries(in: &payload, commit: &noCommit, notCurrent: [])

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
    private func postDeletionsOnly(
        readGeneration: Int,
        urls: [String],
        headers: [String: String],
        commit: AnchorCommit?,
        records: [String: Any] = [:]
    ) async -> HealthSyncResult? {
        var payload: [String: Any] = [
            "timestamp": Date().iso8601String,
            "app_version": appVersion,
            "source": "healthkit_ios"
        ]
        // Records read but held in open windows still exist, so their deletions stay out.
        let deletions = await attachDeletions(to: &payload, records: records, readGeneration: readGeneration)
        guard !deletions.summary.isEmpty else { return nil }

        let outcome = await send(
            payload, totalsDay: nil, recordCount: 0,
            urls: urls, headers: headers, deletions: deletions, commit: commit
        )
        guard let outcome else { return nil }
        return outcome.delivered
            ? .success(syncCounts: [:], reach: outcome.reach)
            : .failure(error: AppDiagnostic.queuedForRetry.rawValue)
    }

    // MARK: - Write-ahead delivery

    /// Sends a sync's payload to the webhooks, write-ahead: into the retry queue first, and
    /// only then are the anchors that read it saved and the deletions it carries let go. The
    /// post comes last and takes the queued copy out once a webhook accepted it. iOS can
    /// suspend or end the app at any point of that, a HealthKit wakeup after 25 seconds and a
    /// foreground sync when its background time runs out, and every record is then delivered,
    /// still queued, or still ahead of the anchor, which reads it again. At worst a payload
    /// goes out twice, which the receiver deduplicates on `uuid`.
    ///
    /// The live post carries today's daily totals; the queued copy leaves them out (see
    /// `queuedBody`). Nil when the payload cannot be serialized: the anchors are saved anyway,
    /// since reading the same records again would fail the same way every sync.
    private func send(
        _ payload: [String: Any],
        totalsDay: String?,
        recordCount: Int,
        urls: [String],
        headers: [String: String],
        deletions: DeletionPlan,
        commit: AnchorCommit?
    ) async -> WebhookManager.Delivery? {
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            commit?.save()
            return nil
        }
        let queued = queuedBody(body, payload: payload, totalsDay: totalsDay)
        let pendingStore = self.pendingStore
        let deletionStore = self.deletionStore
        var queuedId: String?
        defer { if let queuedId { pendingStore.endSending(id: queuedId) } }
        let delivery = await WriteAhead(
            enqueue: {
                queuedId = pendingStore.enqueue(
                    payload: queued,
                    urls: urls,
                    logType: LogType.healthConnect.rawValue,
                    dataType: "health_connect",
                    recordCount: recordCount
                )?.id
                // On its way, not waiting: the Health tab leaves it out of the pending count.
                if let queuedId { pendingStore.beginSending(id: queuedId) }
                return queuedId
            },
            commit: {
                commit?.save()
                await deletionStore.remove(deletions.carried)
            },
            post: {
                await WebhookManager.shared.post(
                    body: body,
                    urls: urls,
                    headers: headers,
                    logType: .healthConnect,
                    dataType: "health_connect",
                    recordCount: recordCount
                )
            },
            delivered: { pendingStore.remove(id: $0) },
            failed: { id, delivery in
                pendingStore.updateAttempt(id: id, error: delivery.error, statusCode: delivery.statusCode)
            }
        ).run()

        if !delivery.delivered {
            logger.info("Sync payload (\(recordCount) records) waits in the retry queue")
        }
        updateWidgetStatus(delivery, records: recordCount)
        return delivery
    }

    // MARK: - Data resolution

    /// Buckets the series that have a resolution set (see ResolutionApplier). With a commit, an
    /// incremental read, the windows still filling are carried into it and saved with its
    /// anchors. Without one, Sync Now and its preview, which read the last week again and save
    /// nothing, send the closed windows and leave the filling one to the incremental syncs,
    /// which read it on their own.
    ///
    /// A window counts as filling up to a type's catch-up cursor, where its next read starts,
    /// and up to the newest measurement read for a type that is behind (the cap, or a page
    /// left for the next sync): the next read may still add to the window that holds it.
    @discardableResult
    private func resolveSeries(
        in payload: inout [String: Any],
        commit: inout AnchorCommit?,
        notCurrent: Set<HealthDataType>
    ) -> ResolvedSeries {
        let resolutions = prefs.storedSeriesResolutions
        let now = Date()
        let carriedIn = commit == nil ? [:] : BucketCarryStore.shared.load()
        var boundaries: [HealthDataType: Date] = [:]
        for type in ResolutionFamily.configurableTypes where (resolutions[type] ?? .raw) != .raw {
            var boundary = now
            if let commit {
                let read = commit.cursors.first { $0.0 == type }
                if let cursor = read.map({ $0.1 }) ?? prefs.loadCatchUpCursor(for: type) { boundary = min(boundary, cursor) }
            }
            let behind = commit == nil
                ? ((payload[type.countedPayloadKey] as? [Any])?.count ?? 0) >= SyncLimits.maxRecordsPerSync(for: type)
                : notCurrent.contains(type)
            if behind, let newest = ResolutionApplier.newestMeasurement(of: type, in: payload, carried: carriedIn[type] ?? []) {
                boundary = min(boundary, newest)
            }
            if boundary < now { boundaries[type] = boundary }
        }
        let resolved = ResolutionApplier.apply(
            to: payload, resolutions: resolutions, carriedIn: carriedIn, now: now, boundaries: boundaries
        )
        payload = resolved.payload
        commit?.bucketCarry = resolved.carriedOut
        return resolved
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
    /// A deletions-only delivery that stands for a sync whose records all went into windows
    /// still filling: it reports those records, as the Android app counts them.
    func counting(_ syncCounts: [HealthDataType: Int]) -> HealthSyncResult {
        guard case .success(_, let reach) = self else { return self }
        return .success(syncCounts: syncCounts, reach: reach)
    }

    /// Combines the results of the rounds of one sync: a failure wins, record counts add up,
    /// and a webhook that missed one round missed part of the sync.
    func merged(with other: HealthSyncResult) -> HealthSyncResult {
        switch (self, other) {
        case (.failure, _): return self
        case (_, .failure): return other
        case (.noData, _): return other
        case (_, .noData): return self
        case let (.success(first, firstReach), .success(second, secondReach)):
            return .success(
                syncCounts: first.merging(second, uniquingKeysWith: +),
                reach: firstReach.merged(with: secondReach)
            )
        }
    }
}

/// The order a sync's payload leaves the phone in, see `HealthSyncManager.send`. Apart from
/// the stores and the network, so a test can stop it at every step.
struct WriteAhead {
    /// Writes the payload to the retry queue; the queued item's id, nil when the write failed.
    var enqueue: () -> String?
    /// Saves the anchors that read the payload and lets go of the deletions it carries.
    var commit: () async -> Void
    var post: () async -> WebhookManager.Delivery
    /// Takes the queued copy out.
    var delivered: (String) -> Void
    /// Counts a failed delivery on the queued copy.
    var failed: (String, WebhookManager.Delivery) -> Void

    func run() async -> WebhookManager.Delivery {
        guard let id = enqueue() else {
            // Nothing on disk to fall back on: the anchors move only past what arrived, and an
            // undelivered payload is read again by the next sync.
            let delivery = await post()
            if delivery.delivered { await commit() }
            return delivery
        }
        await commit()
        let delivery = await post()
        switch delivery.outcome {
        case .delivered: delivered(id)
        case .failed, .refused: failed(id, delivery)
        // Cut off by iOS, which says nothing about the receiver: the retry does not count it.
        case .interrupted: break
        }
        return delivery
    }
}

/// One pass over the retry queue, oldest first, apart from the stores and the network so the
/// tests can run it. Every item is posted with the webhook settings of that moment, as Android's
/// PendingDrainer does: to the URLs configured now, which WebhookManager gives the headers
/// configured now, apart from the addresses that pairing added. A rotated API key or a new
/// address therefore reaches what was queued before, and a removed address gets nothing more.
///
/// The pass stops at the first item that fails, so the rest wait in order for a receiver that
/// answers again. An item refused for what it carries (400, 413, 422) does not hold them up: it
/// is skipped and stays queued, since the refusal can also come from a receiver bug that an
/// update fixes. An interruption ends the pass without counting an attempt.
///
/// An item older than a week is dropped when a delivery of it fails, refused or not: a phone
/// that got no chance to sync for a week still tries once. One item goes per failed pass, so
/// while a receiver stays down the queue holds about a week, however long the outage.
struct QueueDrain {
    var now: Date
    /// The URLs configured now; none leaves every item waiting.
    var urls: () -> [String]
    var headers: () -> [String: String]
    var post: (PendingSyncItem, [String], [String: String]) async -> WebhookManager.Delivery
    var remove: (PendingSyncItem) -> Void
    /// Counts a failed or refused delivery on the item.
    var attempt: (PendingSyncItem, WebhookManager.Delivery) -> Void
    var delivered: (PendingSyncItem, WebhookManager.Delivery) -> Void
    /// An item taken out undelivered, with why.
    var dropped: (PendingSyncItem, QueueDrop) -> Void

    func run(_ items: [PendingSyncItem]) async {
        for item in items {
            let urls = urls()
            guard !urls.isEmpty else { return }
            let delivery = await post(item, urls, headers())
            let expired = item.expired(at: now)
            switch delivery.outcome {
            case .delivered:
                remove(item)
                delivered(item, delivery)
            case .interrupted:
                return
            case .refused:
                if expired {
                    remove(item)
                    dropped(item, .refused(delivery.statusCode))
                } else {
                    attempt(item, delivery)
                }
            case .failed:
                if expired {
                    remove(item)
                    dropped(item, .undelivered)
                } else {
                    attempt(item, delivery)
                }
                return
            }
        }
    }
}
