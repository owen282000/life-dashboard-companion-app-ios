import SwiftUI

/// What a status says, for a result line: always a word too, so the colour is never the only signal.
enum StatusTone {
    case success, failure, warning, info

    var systemImage: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

/// The Test ping, the same request from Logs and the first-run setup: a small JSON
/// POST with `test` set, to every webhook URL with the custom headers, signed when a secret is
/// set, logged with data type `test` and never queued. It counts as delivered only when every
/// URL took it: a test is there to show the address that does not work.
enum TestPing {
    static func body() -> Data? {
        let payload: [String: Any] = [
            "test": true,
            "message": "Test ping from Life Dashboard Companion",
            "timestamp": Date().iso8601String,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "source": "healthkit_ios"
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// Whether every webhook took it; nil when the request could not be built.
    static func send(prefs: PreferencesManager) async -> Bool? {
        guard let body = body() else { return nil }
        let delivery = await WebhookManager.shared.post(
            body: body,
            urls: prefs.healthWebhookUrls,
            logType: .healthConnect,
            dataType: "test",
            recordCount: 0
        )
        return delivery.delivered && delivery.missedUrls.isEmpty
    }
}

/// What Sync Now or Test ping last did. It decides the colour, instead of the text deciding it.
enum SyncOutcome: Equatable {
    /// What Sync Now's result line says, on the Health tab and in the setup.
    init(_ result: HealthSyncResult) {
        switch result {
        case .noData:
            self = .noData
        case .success(let counts, let reach):
            let records = counts.values.reduce(0, +)
            self = reach.partial ? .partlySynced(records, delivered: reach.delivered, of: reach.total) : .synced(records)
        case .failure(let error):
            self = .failed(AppDiagnostic.display(error))
        }
    }

    case synced(Int)
    /// Delivered, but not to every webhook: those that missed it get nothing queued.
    case partlySynced(Int, delivered: Int, of: Int)
    case noData
    case failed(String)
    case pingDelivered
    case pingFailed
    case exportFailed(String)

    var text: Text {
        switch self {
        case .synced(let records): return Text("Synced \(records) records")
        case .partlySynced: return Text(verbatim: announcement)
        case .noData: return Text("No data to sync")
        case .failed(let reason): return Text("Sync failed: \(reason)")
        case .pingDelivered: return Text("Test ping delivered")
        case .pingFailed: return Text("Test ping failed, check the logs")
        case .exportFailed(let reason): return Text("Export failed: \(reason)")
        }
    }

    var announcement: String {
        switch self {
        case .synced(let records): return String(localized: "Synced \(records) records")
        case .partlySynced(let records, let delivered, let total):
            return String(localized: "Synced \(records) records") + " "
                + String(localized: "Delivered to \(delivered) of \(total) destinations, see Logs.")
        case .noData: return String(localized: "No data to sync")
        case .failed(let reason): return String(localized: "Sync failed: \(reason)")
        case .pingDelivered: return String(localized: "Test ping delivered")
        case .pingFailed: return String(localized: "Test ping failed, check the logs")
        case .exportFailed(let reason): return String(localized: "Export failed: \(reason)")
        }
    }

    var tone: StatusTone {
        switch self {
        case .synced, .pingDelivered: return .success
        case .noData: return .info
        case .failed, .partlySynced, .pingFailed, .exportFailed: return .failure
        }
    }
}
