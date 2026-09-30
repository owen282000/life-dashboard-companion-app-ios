import Foundation

/// The figures on the Logs tab's sync history card, worked out from the rows the log keeps and
/// nothing else, as on Android. The log holds the last 100 rows, so every figure covers the span
/// from `since` to now, and the card says so. Clear Logs starts it over.
///
/// One row is one delivery: a body to one webhook URL after its retries, or one MQTT publish.
/// A pending-queue retry is a delivery of its own. Records are counted per delivered webhook
/// row, the unit Nerd Stats and Android use, so two URLs count a sync's records twice.
struct SyncStats: Equatable {
    struct Failure: Equatable, Identifiable {
        /// The newest row of the group, for a later jump to it in the list.
        let logId: String
        /// Host of the webhook URL (never the full URL, which can hold a webhook id),
        /// "MQTT" or "Apple Health".
        let source: String
        let message: String?
        let latest: Date
        let count: Int

        var id: String { logId }
    }

    static let maxRecentFailures = 3
    static let readFailureSource = "Apple Health"
    static let mqttSource = "MQTT"

    let deliveries: Int
    let succeeded: Int
    let webhookDeliveries: Int
    let webhookSucceeded: Int
    let mqttDeliveries: Int
    let mqttSucceeded: Int
    let records: Int
    let since: Date?
    let lastSuccess: Date?
    let recentFailures: [Failure]

    /// Rounded down, so 100 only ever means no failure. nil when nothing was sent.
    var successPercent: Int? {
        deliveries == 0 ? nil : succeeded * 100 / deliveries
    }

    var isEmpty: Bool { deliveries == 0 && recentFailures.isEmpty }

    init(logs: [WebhookLog]) {
        var webhook = 0, webhookOk = 0, mqtt = 0, mqttOk = 0, records = 0
        var since: Date?
        var lastSuccess: Date?
        var failures: [WebhookLog] = []

        for log in logs {
            let kind = log.syncKind
            // An interrupted delivery says nothing about the receiver; its payload is queued
            // and counts when the retry goes out.
            guard kind != .other, !log.isInterrupted else { continue }
            since = min(since ?? log.timestamp, log.timestamp)
            if !log.success { failures.append(log) }

            switch kind {
            case .webhook:
                webhook += 1
                if log.success {
                    webhookOk += 1
                    records += log.recordCount ?? 0
                }
            case .mqtt:
                mqtt += 1
                if log.success { mqttOk += 1 }
            case .readFailure, .other:
                continue
            }
            if log.success {
                lastSuccess = max(lastSuccess ?? log.timestamp, log.timestamp)
            }
        }

        deliveries = webhook + mqtt
        succeeded = webhookOk + mqttOk
        webhookDeliveries = webhook
        webhookSucceeded = webhookOk
        mqttDeliveries = mqtt
        mqttSucceeded = mqttOk
        self.records = records
        self.since = since
        self.lastSuccess = lastSuccess
        recentFailures = SyncStats.group(failures)
    }

    static func source(of log: WebhookLog) -> String {
        switch log.syncKind {
        case .readFailure: return readFailureSource
        case .mqtt: return mqttSource
        case .webhook, .other: return URL(string: log.url)?.host ?? log.url
        }
    }

    /// Groups failures by source and message so one outage does not fill every slot, newest
    /// group first.
    private static func group(_ failures: [WebhookLog]) -> [Failure] {
        var groups: [String: (newest: WebhookLog, count: Int)] = [:]
        for log in failures {
            let key = source(of: log) + "\n" + (log.errorMessage ?? "")
            if let existing = groups[key] {
                let newest = log.timestamp > existing.newest.timestamp ? log : existing.newest
                groups[key] = (newest, existing.count + 1)
            } else {
                groups[key] = (log, 1)
            }
        }
        return groups.values
            .sorted { ($0.newest.timestamp, $0.newest.id) > ($1.newest.timestamp, $1.newest.id) }
            .prefix(maxRecentFailures)
            .map { Failure(
                logId: $0.newest.id,
                source: source(of: $0.newest),
                message: $0.newest.errorMessage,
                latest: $0.newest.timestamp,
                count: $0.count
            ) }
    }
}
