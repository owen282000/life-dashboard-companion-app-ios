import Foundation

/// One chance iOS gave the app to sync on its own, and what came of it.
///
/// A sync that iOS never started leaves nothing in Logs, and neither does one the lock or the
/// time budget stopped before anything was sent. These are what show why automatic syncs did
/// not come: iOS did not wake the app at all, it woke it while the iPhone was locked, or it took
/// the time back before the POST. Only the moment, the trigger and the outcome are kept, never
/// health data.
struct BackgroundChance: Codable, Equatable, Identifiable {
    enum Outcome: String, Codable {
        /// Ran and delivered, or had nothing new.
        case synced
        /// Ran, and a delivery failed or was queued.
        case failed
        /// The schedule said no, or a run in progress covered it.
        case notDue
        /// No destination or no data type.
        case notConfigured
        /// The iPhone was locked, so Health data could not be read.
        case locked
        /// iOS took the time back before the run was done.
        case cancelled

        init(_ outcome: AutomaticSyncOutcome) {
            switch outcome {
            case .ran(let success): self = success ? .synced : .failed
            case .notDue: self = .notDue
            case .notConfigured: self = .notConfigured
            case .locked: self = .locked
            case .cancelled: self = .cancelled
            }
        }

        /// Outcomes that come in runs, such as a HealthKit wakeup per type every few minutes
        /// while the iPhone is locked, are kept as one entry with a count.
        var merges: Bool {
            switch self {
            case .notDue, .notConfigured, .locked: return true
            case .synced, .failed, .cancelled: return false
            }
        }
    }

    var id = UUID()
    /// A `SyncTrigger` raw value, kept as a string so an entry from a newer build still decodes.
    var trigger: String
    var outcome: Outcome
    /// The first and the last chance of a merged entry; the same for a single one.
    var first: Date
    var last: Date
    var count = 1
    /// How long the run took, for one that got as far as the lock check.
    var seconds: Double?

    var syncTrigger: SyncTrigger? { SyncTrigger(rawValue: trigger) }
}

/// The last chances, newest first, merged and capped by pure rules the tests can check.
enum BackgroundChanceLog {
    static let maxEntries = 50

    static func adding(_ chance: BackgroundChance, to entries: [BackgroundChance]) -> [BackgroundChance] {
        var entries = entries
        if chance.outcome.merges, var newest = entries.first,
           newest.trigger == chance.trigger, newest.outcome == chance.outcome {
            newest.last = chance.last
            newest.count += chance.count
            entries[0] = newest
            return entries
        }
        entries.insert(chance, at: 0)
        return Array(entries.prefix(maxEntries))
    }
}

/// Keeps the chances in UserDefaults: a few kilobytes, no health data, and not part of a settings
/// backup, which lists its keys one by one.
/// @unchecked Sendable: every access goes through the lock.
final class BackgroundChanceStore: @unchecked Sendable {
    static let shared = BackgroundChanceStore()

    private static let key = "background_chances"
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(_ trigger: SyncTrigger, _ outcome: BackgroundChance.Outcome, at moment: Date, seconds: Double? = nil) {
        let chance = BackgroundChance(trigger: trigger.rawValue, outcome: outcome, first: moment, last: moment, seconds: seconds)
        lock.withLock {
            let entries = BackgroundChanceLog.adding(chance, to: read())
            if let data = try? JSONEncoder().encode(entries) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }

    func load() -> [BackgroundChance] {
        lock.withLock { read() }
    }

    func clear() {
        lock.withLock { defaults.removeObject(forKey: Self.key) }
    }

    private func read() -> [BackgroundChance] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([BackgroundChance].self, from: data)) ?? []
    }
}
