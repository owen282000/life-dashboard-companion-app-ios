import Foundation
import HealthKit
import UIKit
import OSLog

/// @unchecked Sendable: HKHealthStore is thread-safe, `isAvailable` is set once in init,
/// and the @Published authorization status is only mutated via the @MainActor method.
final class HealthKitManager: ObservableObject, @unchecked Sendable {
    static let shared = HealthKitManager()

    let healthStore = HKHealthStore()
    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "HealthKit")

    @Published var authorizationStatus: [HealthDataType: HKAuthorizationStatus] = [:]
    @Published var isAvailable: Bool

    static let lookbackDays: Int = 7

    /// Result type indicating why data reading failed or returned empty. The anchors and
    /// catch-up cursors a read moved to come with it, unsaved: the caller saves them once what
    /// was read is safe, delivered or in the retry queue (see `AnchorCommit`).
    ///
    /// `notCurrent` names the types whose records do not include their newest sample: a read
    /// that stopped at the cap, or an added sample dated before what HealthKit already holds.
    /// MQTT leaves those out, since a sensor shows the latest record it is given.
    ///
    /// `unanswered` is a read in which every type failed or ran out of time: nothing was read,
    /// and nothing says that there was nothing new either.
    enum ReadResult {
        case data([String: Any], AnchorCommit, notCurrent: Set<HealthDataType>)
        case empty(AnchorCommit)
        case unanswered
        case protectedDataUnavailable
    }

    /// Every type of a read failed or ran out of time, as Android's "Health Connect did not
    /// answer for any data type". A sync reports it as a failure instead of "no new data".
    struct NoTypeAnswered: LocalizedError {
        var errorDescription: String? { AppDiagnostic.healthUnanswered.localized }
    }

    /// True when there were types to read and every one of them failed.
    static func answeredNone(_ types: Set<HealthDataType>, failed: Set<HealthDataType>) -> Bool {
        !types.isEmpty && failed.isSuperset(of: types)
    }

    /// What reading one type incrementally gave: its payload fragments, nil when there was
    /// nothing to send, and the anchors and cursor to save afterwards.
    private struct TypeRead {
        let pairs: [(String, Any)]?
        let anchors: [(HKSampleType, HKQueryAnchor)]
        let cursor: Date?
        let holdsNewest: Bool
        /// Records were left for a later read: past the page budget, or past the cursor.
        let behind: Bool
    }

    private init() {
        self.isAvailable = HKHealthStore.isHealthDataAvailable()
    }

    // MARK: - Permissions

    func readTypesFor(_ types: Set<HealthDataType>) -> Set<HKObjectType> {
        var hkTypes = Set<HKObjectType>()
        for dataType in types {
            hkTypes.formUnion(dataType.hkReadTypes)
        }
        return hkTypes
    }

    func requestAuthorization(for types: Set<HealthDataType>) async throws {
        let readTypes = readTypesFor(types)
        guard !readTypes.isEmpty else { return }
        try await healthStore.requestAuthorization(toShare: [], read: readTypes)
        await updateAuthorizationStatus()
    }

    @MainActor
    func updateAuthorizationStatus() {
        var statuses: [HealthDataType: HKAuthorizationStatus] = [:]
        for dataType in HealthDataType.allCases {
            if let sampleType = dataType.hkSampleTypes.first {
                statuses[dataType] = healthStore.authorizationStatus(for: sampleType)
            } else {
                statuses[dataType] = .notDetermined
            }
        }
        self.authorizationStatus = statuses
    }

    /// Whether HealthKit refused a read because the user was never asked about the sample type,
    /// or said no. Distance reads more sample types since 1.5.0, and until the user answers for
    /// them HealthKit fails every query of one with errorAuthorizationNotDetermined; a denied
    /// read normally finds nothing instead.
    static func isUnanswered(_ error: Error) -> Bool {
        switch (error as? HKError)?.code {
        case .errorAuthorizationNotDetermined?, .errorAuthorizationDenied?: return true
        default: return false
        }
    }

    /// `read` for each sample type of a payload type, leaving out one HealthKit refuses (see
    /// `isUnanswered`), so a new kind of distance the user was never asked about does not take
    /// walking and cycling down with it. Only when every one is refused does the type fail, as
    /// it did before; any other error fails it right away.
    static func eachAnswered<Item, Value>(_ items: [Item], _ read: (Item) async throws -> Value) async throws -> [Value] {
        var values: [Value] = []
        var refusal: Error?
        for item in items {
            do {
                values.append(try await read(item))
            } catch let error where isUnanswered(error) {
                refusal = refusal ?? error
            }
        }
        if values.isEmpty, let refusal { throw refusal }
        return values
    }

    // MARK: - Asking once after an update

    /// The read types the Health tab has asked for by itself, as HealthKit identifiers.
    static let askedReadTypesKey = "health_access_asked_types"

    /// Whether the Health tab asks for access by itself: HealthKit has something to ask for the
    /// enabled types, as after an update that gives one more sample types or a setup whose
    /// Allow button was skipped, and the tab has not asked for these types before. Asked once,
    /// the Grant chip is left to do the rest.
    static func asksOnce(_ request: HKAuthorizationRequestStatus?, readTypes: Set<String>, asked: Set<String>) -> Bool {
        request == .shouldRequest && !readTypes.isEmpty && !readTypes.isSubset(of: asked)
    }

    /// Asks for the enabled types' access when `asksOnce` says so, and remembers that it did.
    func askOnceForEnabledTypes(_ types: Set<HealthDataType>, defaults: UserDefaults = .standard) async {
        let readTypes = readTypesFor(types)
        let identifiers = Set(readTypes.map(\.identifier))
        let asked = Set(defaults.stringArray(forKey: Self.askedReadTypesKey) ?? [])
        let request = try? await healthStore.statusForAuthorizationRequest(toShare: [], read: readTypes)
        guard Self.asksOnce(request, readTypes: identifiers, asked: asked) else { return }
        // Remembered only once iOS took the request, so a sheet that could not show asks again.
        guard (try? await requestAuthorization(for: types)) != nil else { return }
        defaults.set(asked.union(identifiers).sorted(), forKey: Self.askedReadTypesKey)
    }

    /// Most recent heart rate sample, used by the About screen's beating-heart easter egg.
    func latestHeartRateBPM() async -> Int? {
        guard isAvailable else { return nil }
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let bpm = (samples?.first as? HKQuantitySample)
                    .map { HealthRecordMapping.bpm($0) }
                continuation.resume(returning: bpm)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Data Reading

    func readHealthData(
        for enabledTypes: Set<HealthDataType>
    ) async throws -> [String: Any] {
        let startDate = Calendar.current.date(
            byAdding: .day,
            value: -HealthKitManager.lookbackDays,
            to: Date()
        )!
        let endDate = Date()

        // Every type reads on its own; one that fails or does not answer in time is skipped,
        // and a read that every type failed throws.
        let gathered = await HealthKitManager.gatherReporting(enabledTypes) { dataType in
            try await self.readDataForType(dataType, start: startDate, end: endDate)
        } failed: { dataType, error in
            self.logger.error("Read failed for \(dataType.rawValue): \(error.localizedDescription)")
        }
        if HealthKitManager.answeredNone(enabledTypes, failed: gathered.failed) { throw NoTypeAnswered() }
        return HealthKitManager.merge(gathered.fragments.values)
    }

    /// What MQTT gets from a full read. The full read is capped oldest first, so for a type
    /// with more records in the lookback week than its cap, heart rate and steps from an Apple
    /// Watch among others, its newest record is days old, and a sensor would show that as the
    /// current value. Such a type is read again from the newest end (see
    /// `SyncLimits.tailStart`); a type whose probe or read fails is left out, as the sensor
    /// then keeps what it had.
    func newestRecords(for types: Set<HealthDataType>, in read: [String: Any]) async -> [String: Any] {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -HealthKitManager.lookbackDays, to: end)!
        let tails = await HealthKitManager.gather(types) { dataType -> NewestRead? in
            let limit = SyncLimits.maxRecordsPerSync(for: dataType)
            let range = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let starts = try await HealthKitManager.eachAnswered(dataType.hkSampleTypes) { sampleType in
                try await self.boundedSampleQuery(type: sampleType, predicate: range, limit: limit, newestFirst: true).map(\.startDate)
            }.flatMap { $0 }
            guard let tailStart = SyncLimits.tailStart(probedStartDates: starts, limit: limit) else { return .whole }
            return .tail(try await self.readDataForType(dataType, start: tailStart, end: end) ?? [])
        } failed: { dataType, error in
            self.logger.error("Newest records of \(dataType.rawValue) failed: \(error.localizedDescription)")
        }
        return HealthKitManager.newest(in: read, types: types, reads: tails)
    }

    enum NewestRead {
        /// The full read holds the type's newest records.
        case whole
        /// The newest records, read again from the newest end.
        case tail([(String, Any)])
    }

    /// The full read with each type's records as `reads` says; a type missing from `reads`
    /// failed and is left out.
    static func newest(in read: [String: Any], types: Set<HealthDataType>, reads: [HealthDataType: NewestRead]) -> [String: Any] {
        var payload = read
        for type in types {
            switch reads[type] {
            case .whole:
                continue
            case .tail(let pairs):
                payload.removeValue(forKey: type.countedPayloadKey)
                for (key, value) in pairs { payload[key] = value }
            case nil:
                payload.removeValue(forKey: type.countedPayloadKey)
            }
        }
        return payload
    }

    /// Runs `read` for every type in a task of its own and returns what each one read. A type
    /// that throws, a HealthKit query that ran out of time among others, is left out and passed
    /// to `failed`; the other types go ahead.
    static func gather<Fragment>(
        _ types: Set<HealthDataType>,
        read: @escaping @Sendable (HealthDataType) async throws -> Fragment?,
        failed: @escaping @Sendable (HealthDataType, Error) -> Void
    ) async -> [HealthDataType: Fragment] {
        await gatherReporting(types, read: read, failed: failed).fragments
    }

    /// `gather`, with the types that failed, so a caller can tell a read that found nothing
    /// from one in which no type answered.
    static func gatherReporting<Fragment>(
        _ types: Set<HealthDataType>,
        read: @escaping @Sendable (HealthDataType) async throws -> Fragment?,
        failed: @escaping @Sendable (HealthDataType, Error) -> Void
    ) async -> (fragments: [HealthDataType: Fragment], failed: Set<HealthDataType>) {
        await withTaskGroup(of: (HealthDataType, Unchecked<Fragment>?, failed: Bool).self) { group in
            for dataType in types {
                group.addTask {
                    do {
                        return (dataType, try await read(dataType).map(Unchecked.init), false)
                    } catch {
                        failed(dataType, error)
                        return (dataType, nil, true)
                    }
                }
            }
            var results: [HealthDataType: Fragment] = [:]
            var failures: Set<HealthDataType> = []
            for await (dataType, fragment, didFail) in group {
                if let fragment { results[dataType] = fragment.value }
                if didFail { failures.insert(dataType) }
            }
            return (results, failures)
        }
    }

    /// The payload the per-type reads add up to.
    static func merge<Pairs: Sequence>(_ fragments: Pairs) -> [String: Any] where Pairs.Element == [(String, Any)] {
        var payload: [String: Any] = [:]
        for pairs in fragments {
            for (key, value) in pairs { payload[key] = value }
        }
        return payload
    }

    // MARK: - Daily Totals

    /// Deduplicated daily step totals for the last `days` days including today, via
    /// HKStatisticsCollectionQuery which merges overlapping phone and watch samples
    /// instead of double counting. Returns oldest-first; empty when steps are unavailable.
    func readDailyStepTotals(days: Int) async -> [Int] {
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else { return [] }
        let calendar = Calendar.current
        let end = Date()
        let startOfToday = calendar.startOfDay(for: end)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) else { return [] }

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: stepType,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                options: .cumulativeSum,
                anchorDate: startOfToday,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, results, _ in
                var totals: [Int] = []
                results?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let value = statistics.sumQuantity()?.doubleValue(for: .count()) ?? 0
                    totals.append(Int(value.rounded()))
                }
                continuation.resume(returning: totals)
            }
            self.healthStore.execute(query)
        }
    }

    // MARK: - Incremental (Anchor-Based) Reading

    /// Reads only new data since the last successful sync using HKAnchoredObjectQuery.
    /// Falls back to full 7-day read if no anchor exists (first sync).
    /// Returns `.protectedDataUnavailable` if the device is locked and data is encrypted.
    func readIncrementalData(
        for enabledTypes: Set<HealthDataType>
    ) async throws -> ReadResult {
        // Stap 5: Check if HealthKit data is accessible (device may be locked)
        let isProtected = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        guard isProtected else {
            logger.info("Protected data unavailable (device locked) - skipping HealthKit read")
            return .protectedDataUnavailable
        }

        let prefs = PreferencesManager.shared
        let probeNewest = prefs.mqttConfigured

        // A type that fails keeps its anchors and cursor, so the next sync reads it again.
        let gathered = await HealthKitManager.gatherReporting(enabledTypes) { dataType in
            try await self.readIncrementalDataForType(dataType, prefs: prefs, probeNewest: probeNewest)
        } failed: { dataType, error in
            self.logger.error("Incremental read failed for \(dataType.rawValue): \(error.localizedDescription)")
        }
        if HealthKitManager.answeredNone(enabledTypes, failed: gathered.failed) { return .unanswered }
        let reads = gathered.fragments
        var commit = AnchorCommit()
        for (dataType, read) in reads {
            commit.anchors += read.anchors.map { AnchorCommit.Anchor(dataType: dataType, sampleType: $0.0, anchor: $0.1) }
            commit.cursors.append((dataType, read.cursor))
            if read.behind { commit.behind.insert(dataType) }
        }
        let results = HealthKitManager.merge(reads.values.compactMap(\.pairs))
        let notCurrent = Set(reads.filter { !$0.value.holdsNewest }.keys)

        return results.isEmpty ? .empty(commit) : .data(results, commit, notCurrent: notCurrent)
    }

    /// Reads incremental data for a single type using HKAnchoredObjectQuery.
    ///
    /// The anchored queries report the samples added since the last sync, a page of them for
    /// the type (see `IncrementalRead.pageBudget`); what is past the page stays behind the
    /// anchor for the next sync. Only those samples are sent, built by the same code as every
    /// other read (see `readAdded`), so a back-dated entry sends itself and not every record
    /// since its date.
    ///
    /// A sample type read for the first time has no anchor: its anchor is taken at the end of
    /// the store and the lookback week is read by time, capped (see `nextSlice`), with the rest
    /// left to the catch-up cursor, which the next syncs continue from. Anchors and cursor are
    /// returned, for the caller to save once the records are delivered or queued.
    private func readIncrementalDataForType(
        _ dataType: HealthDataType,
        prefs: PreferencesManager,
        probeNewest: Bool
    ) async throws -> TypeRead {
        let sampleTypes = dataType.hkSampleTypes
        var added: [AddedSample] = []
        var addedIds: [String: Set<UUID>] = [:]
        var morePending = false
        var readsFirstTime = false
        var newAnchors: [(HKSampleType, HKQueryAnchor)] = []
        var anchored: [(HKSampleType, HKQueryAnchor)] = []
        var answered = false
        var refusal: Error?

        for sampleType in sampleTypes {
            if let anchor = prefs.loadAnchor(for: dataType, sampleType: sampleType) {
                anchored.append((sampleType, anchor))
                continue
            }
            do {
                // First sync of this sample type: read the lookback window. The anchor is taken
                // before that read, so a sample written in between is read now or next time.
                newAnchors.append((sampleType, try await queryAnchor(for: sampleType)))
                readsFirstTime = true
                answered = true
            } catch let error where HealthKitManager.isUnanswered(error) {
                // Left without an anchor, and not catching up: once the user allows it, its
                // first read sends the week.
                refusal = refusal ?? error
            }
        }

        // One budget for all sample types of the payload type, which the readers cap together,
        // spent in an order that turns every minute, so a busy one (walking distance) cannot
        // keep a quiet one (cycling distance) waiting for good.
        let catchingUp = prefs.loadCatchUpCursor(for: dataType) != nil || readsFirstTime
        var budget = IncrementalRead.pageBudget(for: dataType, catchingUp: catchingUp)
        for (sampleType, anchor) in IncrementalRead.rotated(anchored, by: Int(Date().timeIntervalSince1970 / 60)) {
            // Nothing left: this sample type keeps its anchor for the next sync.
            guard budget > 0 else {
                morePending = true
                continue
            }
            do {
                let page = try await anchoredPage(sampleType: sampleType, anchor: anchor, limit: budget)
                newAnchors.append((sampleType, page.anchor ?? anchor))
                added += page.added
                addedIds[sampleType.identifier, default: []].formUnion(page.added.map(\.uuid))
                morePending = morePending || page.count >= budget
                budget -= page.count
                answered = true
            } catch let error where HealthKitManager.isUnanswered(error) {
                refusal = refusal ?? error
            }
        }
        if !answered, let refusal { throw refusal }
        // The read ends after the anchored queries: a sample saved while they ran is behind
        // the new anchors, so it has to fall inside this read.
        let now = Date()
        let firstRead = readsFirstTime
            ? Calendar.current.date(byAdding: .day, value: -HealthKitManager.lookbackDays, to: now)!
            : nil
        let storedCursor = prefs.loadCatchUpCursor(for: dataType)
        let plan = IncrementalRead.plan(cursor: storedCursor, firstRead: firstRead, added: added, now: now)
        let timeReadStart = plan.timeReadStart
        let byUuid = plan.byUuid

        var result: [(String, Any)]?
        // A cursor at or past now, after the clock was set back, is kept for when it is reached.
        var cursor = storedCursor.flatMap { $0 >= now ? $0 : nil }
        var timeReadReachedNow = false
        if let start = timeReadStart, start < now {
            let slice = try await nextSlice(for: dataType, from: start, to: now)
            if !slice.exact {
                logger.error("More than the cap of \(dataType.rawValue) samples share \(start.iso8601String); the excess is not sent")
            }
            result = try await readDataForType(dataType, start: start, end: slice.end)
            cursor = SyncLimits.catchUpCursor(afterSliceEndingAt: slice.end, now: now)
            timeReadReachedNow = cursor == nil
        }

        if !byUuid.isEmpty {
            // Every sample type whose samples are records of their own is named, a first
            // read's with none, so a reader never falls back to everything in the span. A
            // sample type that only adds fields to another's record, the diastolic value of a
            // blood pressure reading or the carbs and fat of a meal, is read by time around
            // them: its sample can be in another page than the one it belongs to.
            let wanted = Set(byUuid.map(\.uuid))
            let joined = Set(sampleTypes.map(\.identifier)).subtracting(dataType.deletionSampleTypes.map(\.identifier))
            let only = Dictionary(uniqueKeysWithValues: sampleTypes.filter { !joined.contains($0.identifier) }.map {
                ($0.identifier, (addedIds[$0.identifier] ?? []).intersection(wanted))
            })
            result = IncrementalRead.merge(result, try await readAdded(dataType, byUuid, only: only))
        }

        var newestInStore: Date?
        if probeNewest, result != nil, !timeReadReachedNow, !byUuid.isEmpty {
            do {
                newestInStore = try await newestStart(of: dataType, notAfter: now)
            } catch {
                // Unknown is not current: the sensor keeps its value, the records still go.
                newestInStore = .distantFuture
            }
        }
        let behind = morePending || cursor != nil
        let holdsNewest = IncrementalRead.holdsNewest(
            behind: behind,
            timeReadReachedNow: timeReadReachedNow,
            byUuidStarts: byUuid.map(\.start),
            newestInStore: newestInStore,
            now: now
        )
        return TypeRead(pairs: result, anchors: newAnchors, cursor: cursor, holdsNewest: holdsNewest, behind: behind)
    }

    /// Records for exactly the added samples in `added`, from the same readers as every other
    /// read. Most types read them by uuid (`onlySamples`). Sleep sessions and menstruation
    /// periods are built from several samples, so their neighbours are read too, in a window
    /// around each group of added samples, and only what holds an added sample is kept: a
    /// night that gains a stage goes out whole, under the uuid derived from its first stage.
    private func readAdded(
        _ dataType: HealthDataType,
        _ added: [AddedSample],
        only: [String: Set<UUID>]
    ) async throws -> [(String, Any)]? {
        switch dataType {
        case .sleep:
            let limit = HealthKitManager.sessionReadLimit
            var result: [(String, Any)]?
            for window in IncrementalRead.sessionWindows(
                for: added, gap: SleepSessionBuilder.sessionGap, padding: BackfillPlan.sleepPadding
            ) {
                let sessions = try await readSleepData(start: window.start, end: window.end, limit: limit)
                let stages = sessions.reduce(0) { $0 + (($1["stages"] as? [Any])?.count ?? 0) }
                // A night past the limit would be cut and its added stages lost behind the anchor.
                guard stages < limit else { throw SessionReadTooLarge() }
                let holding = IncrementalRead.sessions(sessions, holding: Set(added.map(\.uuid)))
                if !holding.isEmpty { result = IncrementalRead.merge(result, [("sleep", holding)]) }
            }
            return result

        case .menstruation:
            // Flow days are records of their own and go by uuid; the periods built from them
            // need the days around them, read past the flow read's cap of 200.
            let flow = try await readByUuid(dataType, added, only: only)?.filter { $0.0 == "menstruation_flow" }
            let limit = HealthKitManager.sessionReadLimit
            var periods: [(String, Any)]?
            for window in IncrementalRead.sessionWindows(
                for: added, gap: MenstruationPeriodBuilder.maxGap, padding: BackfillPlan.periodPadding
            ) {
                let samples = try await readSamples(
                    type: HKCategoryType(.menstrualFlow), start: window.start, end: window.end, limit: limit
                )
                guard samples.count < limit else { throw SessionReadTooLarge() }
                // As the flow reader does: a day logged as no flow is not part of a period.
                let days = samples.compactMap { $0 as? HKCategorySample }
                    .filter { Self.menstrualFlow($0) != nil }
                    .map { FlowSample(start: $0.startDate, end: $0.endDate, uuid: $0.uuid.uuidString, source: $0.sourceRevision.source.name) }
                let holding = IncrementalRead.periods(MenstruationPeriodBuilder.periods(from: days), holding: added)
                if !holding.isEmpty { periods = IncrementalRead.merge(periods, [("menstruation_period", holding)]) }
            }
            return IncrementalRead.merge(flow.flatMap { $0.isEmpty ? nil : $0 }, periods)

        default:
            return try await readByUuid(dataType, added, only: only)
        }
    }

    /// Reads `dataType` around the added samples with `onlySamples` set, so the type's own
    /// reader builds records for them and nothing else, and keeps the records whose uuid is an
    /// added sample's. That drops a blood pressure reading or a food the reader finds by its
    /// correlation, which is not filtered, when its own sample was sent before or comes in a
    /// later page. The samples are read in spans (see `IncrementalRead.spans`), each a second
    /// wider on both sides for what the readers pair within a second, so a back-dated sample
    /// does not make the unfiltered reads cover the year in between.
    private func readByUuid(
        _ dataType: HealthDataType,
        _ added: [AddedSample],
        only: [String: Set<UUID>]
    ) async throws -> [(String, Any)]? {
        var result: [(String, Any)]?
        for span in IncrementalRead.spans(of: added, gap: 86_400, maxCount: HealthKitManager.maxSpans) {
            let read = try await HealthKitManager.$onlySamples.withValue(only) {
                try await readDataForType(dataType, start: span.start.addingTimeInterval(-1), end: span.end.addingTimeInterval(1))
            }
            result = IncrementalRead.merge(result, read)
        }
        return IncrementalRead.records(result, withUuidIn: Set(added.map(\.uuid)))
    }

    /// Spans read per type in one sync, so an import scattered over a year costs a bounded
    /// number of queries.
    private static let maxSpans = 24

    /// Stages read per window around added sleep stages: a night holds a few dozen.
    private static let sessionReadLimit = 2000

    private struct SessionReadTooLarge: Error {}

    /// The start of the newest sample of `dataType` in HealthKit up to `now`, across its sample
    /// types. A sample dated in the future is no current value, and would hold every later one
    /// back from MQTT.
    private func newestStart(of dataType: HealthDataType, notAfter now: Date) async throws -> Date? {
        let past = HKQuery.predicateForSamples(withStart: nil, end: now, options: [])
        let starts = try await HealthKitManager.eachAnswered(dataType.hkSampleTypes) { sampleType in
            try await boundedSampleQuery(type: sampleType, predicate: past, limit: 1, newestFirst: true).first?.startDate
        }
        return starts.compactMap { $0 }.max()
    }

    /// While set, the record queries in this task return only these samples, by sample type
    /// identifier. A sample type it does not name is read by time alone.
    @TaskLocal static var onlySamples: [String: Set<UUID>]?

    /// Where a read of `dataType` from `start` has to stop to stay under its cap, so that
    /// nothing is cut off: a probe reads the start dates of the oldest samples of every
    /// sample type the payload type combines, and `SyncLimits.sliceEnd` picks the boundary.
    func nextSlice(for dataType: HealthDataType, from start: Date, to end: Date) async throws -> (end: Date, exact: Bool) {
        let limit = SyncLimits.maxRecordsPerSync(for: dataType)
        let startDates = try await HealthKitManager.eachAnswered(dataType.hkSampleTypes) { sampleType in
            try await readSamples(type: sampleType, start: start, end: end, limit: limit).map(\.startDate)
        }.flatMap { $0 }
        return SyncLimits.sliceEnd(probedStartDates: startDates, limit: limit, from: start, to: end)
    }

    /// Samples per page of the anchored query that finds the end of a store. Nothing of a
    /// page is kept, so a type's whole history can go through without being held in memory.
    private static let anchorPageSize = 5000

    /// The current anchor of a sample type, for the first sync of it. A limit of 0 is
    /// HKObjectQueryNoLimit, which loaded the type's entire history at once; paging does not.
    private func queryAnchor(for sampleType: HKSampleType) async throws -> HKQueryAnchor {
        var current: HKQueryAnchor?
        while true {
            let page = try await anchoredPage(sampleType: sampleType, anchor: current, limit: HealthKitManager.anchorPageSize)
            current = page.anchor ?? current
            if page.count < HealthKitManager.anchorPageSize { break }
        }
        return current ?? HKQueryAnchor(fromValue: 0)
    }

    private struct AnchoredPage {
        let added: [AddedSample]
        /// Added samples and deleted objects together: a page that returned `limit` of them
        /// may have more behind it.
        let count: Int
        let anchor: HKQueryAnchor?
    }

    private func anchoredPage(
        sampleType: HKSampleType,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> AnchoredPage {
        let store = healthStore
        let begin = Unchecked(value: (sampleType, anchor))
        let page: Unchecked<AnchoredPage> = try await BoundedCall.run(timeout: HealthKitManager.recordQueryTimeout) { finish in
            let query = HKAnchoredObjectQuery(
                type: begin.value.0,
                predicate: nil,
                anchor: begin.value.1,
                limit: limit
            ) { _, addedSamples, deletedObjects, newAnchor, error in
                if let error {
                    finish(.failure(error))
                    return
                }
                let samples = addedSamples ?? []
                finish(.success(Unchecked(value: AnchoredPage(
                    added: samples.map { AddedSample(uuid: $0.uuid, start: $0.startDate, end: $0.endDate) },
                    count: samples.count + (deletedObjects?.count ?? 0),
                    anchor: newAnchor ?? begin.value.1
                ))))
            }
            store.execute(query)
            let running = Unchecked(value: query as HKQuery)
            return { store.stop(running.value) }
        }
        return page.value
    }

    /// Adds the stable HealthKit UUID and the writing app/device to a payload record,
    /// so servers can deduplicate re-sent records and trace their origin.
    private func record(_ fields: [String: Any], from sample: HKSample) -> [String: Any] {
        HealthRecordMapping.record(fields, from: sample)
    }

    /// Slices at most for one `readWhole`: enough for a few hours of one-second heart rate or
    /// days of steps. A sync that would need more, catching up after a long pause, sends those
    /// windows unmarked instead, which a receiver combines.
    static let maxWholeSlices = 24

    /// Every sample of a bucketed accumulated type in `[start, end)`, read in slices the way the backfill
    /// reads (`nextSlice`, `readDataForType`) and mapped the way a synced record is, so a sync
    /// can send the windows in that range whole (P2-16). Nil when the range cannot be read in
    /// full: a slice was not exact, or it needs more than `maxWholeSlices`.
    func readWhole(_ dataType: HealthDataType, start: Date, end: Date) async throws -> WholeContent? {
        guard let fields = dataType.seriesFields else { return nil }
        var samples: [CarriedSample] = []
        var cursor = start
        var slices = 0
        while cursor < end {
            slices += 1
            guard slices <= HealthKitManager.maxWholeSlices else { return nil }
            let slice = try await nextSlice(for: dataType, from: cursor, to: end)
            guard slice.exact else { return nil }
            let pairs = try await readDataForType(dataType, start: cursor, end: slice.end) ?? []
            let records = pairs.first { $0.0 == dataType.countedPayloadKey }?.1 as? [[String: Any]] ?? []
            samples += records.compactMap { ResolutionApplier.sample(from: $0, fields: fields) }
            cursor = slice.end
        }
        return WholeContent(samples: samples, from: start, to: end)
    }

    /// Reads data for a single HealthDataType. Returns (payloadKey, data) pairs or nil if empty.
    /// Most types produce one pair; menstruation produces both flow records and derived periods.
    /// Reads are capped oldest-first per type (see SyncLimits) to bound payload size.
    /// The incremental sync and the backfill slice reads with `nextSlice`, which relies on
    /// every case reading only the type's `hkSampleTypes`, by start date in `[start, end)`,
    /// at most `SyncLimits.maxRecordsPerSync` per sample type. Blood pressure and nutrition also
    /// read the correlations around the window, but only those starting in it become records.
    func readDataForType(
        _ dataType: HealthDataType,
        start: Date,
        end: Date
    ) async throws -> [(String, Any)]? {
        let limit = SyncLimits.maxRecordsPerSync(for: dataType)
        switch dataType {
        case .steps:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.stepCount),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.stepsFields($0), from: $0) }
            return mapped.isEmpty ? nil : [("steps", mapped)]

        case .distance:
            let samples = try await HealthKitManager.eachAnswered(HealthDataType.distanceIdentifiers) { identifier in
                try await readQuantitySamples(
                    type: HKQuantityType(identifier),
                    start: start, end: end,
                    limit: limit
                )
            }.flatMap { $0 }
            let records = SyncLimits.capOldestFirst(samples, limit: limit, timeOf: { $0.startDate })
                .sorted { $0.startDate < $1.startDate }
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "meters": sample.quantity.doubleValue(for: .meter()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("distance", mapped)]

        case .activeCalories:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.activeEnergyBurned),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "calories": sample.quantity.doubleValue(for: .kilocalorie()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("active_calories", mapped)]

        case .totalCalories:
            async let activeRecords = readQuantitySamples(
                type: HKQuantityType(.activeEnergyBurned),
                start: start, end: end,
                limit: limit
            )
            async let basalRecords = readQuantitySamples(
                type: HKQuantityType(.basalEnergyBurned),
                start: start, end: end,
                limit: limit
            )
            let combined = try await SyncLimits.capOldestFirst(
                activeRecords + basalRecords,
                limit: limit,
                timeOf: { $0.startDate }
            )
            let mapped = combined.map { sample -> [String: Any] in
                record([
                    "calories": sample.quantity.doubleValue(for: .kilocalorie()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("total_calories", mapped)]

        case .weight:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.bodyMass),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "kilograms": sample.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("weight", mapped)]

        case .height:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.height),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "meters": sample.quantity.doubleValue(for: .meter()),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("height", mapped)]

        case .heartRate:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.heartRate),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.heartRateFields($0), from: $0) }
            return mapped.isEmpty ? nil : [("heart_rate", mapped)]

        case .restingHeartRate:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.restingHeartRate),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.heartRateFields($0), from: $0) }
            return mapped.isEmpty ? nil : [("resting_heart_rate", mapped)]

        case .heartRateVariability:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.heartRateVariabilitySDNN),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "heart_rate_variability_millis": sample.quantity.doubleValue(for: .secondUnit(with: .milli)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("heart_rate_variability", mapped)]

        case .bloodPressure:
            // The lone values are read a pairing tolerance past the window, so a slice that ends
            // between a systolic value and its diastolic one still sends the pair.
            let margin = HealthRecordMapping.loosePressureTolerance
            async let correlationRecords = readCorrelations(HKCorrelationType(.bloodPressure), around: start, end)
            async let systolicRecords = readQuantitySamples(
                type: HKQuantityType(.bloodPressureSystolic),
                start: start.addingTimeInterval(-margin), end: end.addingTimeInterval(margin),
                limit: limit
            )
            async let diastolicRecords = readQuantitySamples(
                type: HKQuantityType(.bloodPressureDiastolic),
                start: start.addingTimeInterval(-margin), end: end.addingTimeInterval(margin),
                limit: limit
            )
            let mapped = try await HealthRecordMapping.bloodPressureRecords(
                correlations: correlationRecords,
                systolic: systolicRecords,
                diastolic: diastolicRecords,
                start: start, end: end
            )
            return mapped.isEmpty ? nil : [("blood_pressure", mapped)]

        case .bloodGlucose:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.bloodGlucose),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "mmol_per_liter": sample.quantity.doubleValue(
                        for: HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
                    ),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("blood_glucose", mapped)]

        case .oxygenSaturation:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.oxygenSaturation),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "percentage": sample.quantity.doubleValue(for: .percent()) * 100,
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("oxygen_saturation", mapped)]

        case .bodyTemperature:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.bodyTemperature),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "celsius": sample.quantity.doubleValue(for: .degreeCelsius()),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("body_temperature", mapped)]

        case .respiratoryRate:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.respiratoryRate),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "rate": sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("respiratory_rate", mapped)]

        case .bodyFat:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.bodyFatPercentage),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "percentage": sample.quantity.doubleValue(for: .percent()) * 100,
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("body_fat", mapped)]

        case .leanBodyMass:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.leanBodyMass),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "kilograms": sample.quantity.doubleValue(for: .gramUnit(with: .kilo)),
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("lean_body_mass", mapped)]

        case .sleep:
            let sleepData = try await readSleepData(start: start, end: end, limit: limit)
            return sleepData.isEmpty ? nil : [("sleep", sleepData)]

        case .exercise:
            let workouts = try await readWorkouts(start: start, end: end, limit: limit)
            return workouts.isEmpty ? nil : [("exercise", workouts)]

        case .hydration:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.dietaryWater),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                record([
                    "liters": sample.quantity.doubleValue(for: .liter()),
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("hydration", mapped)]

        case .nutrition:
            let nutritionData = try await readNutritionData(start: start, end: end, limit: limit)
            return nutritionData.isEmpty ? nil : [("nutrition", nutritionData)]

        case .mindfulness:
            let records = try await readCategorySamples(
                type: HKCategoryType(.mindfulSession),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { sample -> [String: Any] in
                let duration = sample.endDate.timeIntervalSince(sample.startDate)
                return record([
                    "start_time": sample.startDate.iso8601String,
                    "end_time": sample.endDate.iso8601String,
                    "duration_seconds": Int(duration)
                ], from: sample)
            }
            return mapped.isEmpty ? nil : [("mindfulness", mapped)]

        case .menstruation:
            let records = try await readCategorySamples(
                type: HKCategoryType(.menstrualFlow),
                start: start, end: end,
                limit: limit
            )
            let flowSamples = records.compactMap { sample in Self.menstrualFlow(sample).map { (sample, $0) } }
            let mapped = flowSamples.map { sample, flow in
                record([
                    "flow": flow,
                    "time": sample.startDate.iso8601String
                ], from: sample)
            }
            guard !mapped.isEmpty else { return nil }

            // HealthKit has no period record type; derive periods from consecutive flow
            // days so the payload matches the Android app's menstruation_period records. The
            // days before the read count too, so a period that began earlier keeps the uuid of
            // its first day when a sync reads only the day just logged.
            let earlier = try await readCategorySamples(
                type: HKCategoryType(.menstrualFlow),
                start: start.addingTimeInterval(-MenstruationPeriodBuilder.lookback), end: start,
                limit: limit
            ).filter { Self.menstrualFlow($0) != nil }
            let periods = MenstruationPeriodBuilder.periods(
                from: (earlier + flowSamples.map(\.0)).map {
                    FlowSample(start: $0.startDate, end: $0.endDate, uuid: $0.uuid.uuidString, source: $0.sourceRevision.source.name)
                },
                reaching: start
            )
            return [("menstruation_flow", mapped), ("menstruation_period", periods)]

        case .vo2Max:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.vo2Max),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.vo2MaxFields($0), from: $0) }
            return mapped.isEmpty ? nil : [(dataType.countedPayloadKey, mapped)]

        case .basalBodyTemperature:
            let records = try await readQuantitySamples(
                type: HKQuantityType(.basalBodyTemperature),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.basalBodyTemperatureFields($0), from: $0) }
            return mapped.isEmpty ? nil : [(dataType.countedPayloadKey, mapped)]

        case .intermenstrualBleeding:
            let records = try await readCategorySamples(
                type: HKCategoryType(.intermenstrualBleeding),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.intermenstrualBleedingFields($0), from: $0) }
            return mapped.isEmpty ? nil : [(dataType.countedPayloadKey, mapped)]

        case .ovulationTest:
            let records = try await readCategorySamples(
                type: HKCategoryType(.ovulationTestResult),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.ovulationTestFields($0), from: $0) }
            return mapped.isEmpty ? nil : [(dataType.countedPayloadKey, mapped)]

        case .cervicalMucus:
            let records = try await readCategorySamples(
                type: HKCategoryType(.cervicalMucusQuality),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.cervicalMucusFields($0), from: $0) }
            return mapped.isEmpty ? nil : [(dataType.countedPayloadKey, mapped)]

        case .sexualActivity:
            let records = try await readCategorySamples(
                type: HKCategoryType(.sexualActivity),
                start: start, end: end,
                limit: limit
            )
            let mapped = records.map { record(HealthRecordMapping.sexualActivityFields($0), from: $0) }
            return mapped.isEmpty ? nil : [(dataType.countedPayloadKey, mapped)]
        }
    }

    /// The payload's flow value; nil for a day logged as no flow, which is no bleeding.
    private static func menstrualFlow(_ sample: HKCategorySample) -> String? {
        guard let value = HKCategoryValueMenstrualFlow(rawValue: sample.value) else { return nil }
        switch value {
        case .light: return "light"
        case .medium: return "medium"
        case .heavy: return "heavy"
        case .unspecified: return "unknown"
        default: return nil
        }
    }

    // MARK: - Query Helpers

    /// How long one HealthKit record query may take. HealthKit answers in well under a second
    /// normally; one that does not answer would otherwise hold the sync, and Sync Now behind it,
    /// for good. The type it belongs to fails for this sync, as the deletion step's reads do.
    static let recordQueryTimeout: Duration = .seconds(10)

    /// Reads at most `limit` samples of any type in `[start, end)`, oldest first.
    func readSamples(
        type: HKSampleType,
        start: Date,
        end: Date,
        limit: Int
    ) async throws -> [HKSample] {
        var predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        if let only = HealthKitManager.onlySamples?[type.identifier] {
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, HKQuery.predicateForObjects(with: only)])
        }
        return try await boundedSampleQuery(type: type, predicate: predicate, limit: limit)
    }

    /// Reads at most `limit` samples, oldest first (ascending sort + query limit), so payload
    /// size stays bounded and later syncs catch up without skipping records.
    private func readQuantitySamples(
        type: HKQuantityType,
        start: Date,
        end: Date,
        limit: Int
    ) async throws -> [HKQuantitySample] {
        try await readSamples(type: type, start: start, end: end, limit: limit).compactMap { $0 as? HKQuantitySample }
    }

    /// The correlations of `type` that start within `correlationMargin` of `[start, end)`, so
    /// the caller can tell which samples of the window belong to one. No limit: the window was
    /// sliced to hold at most the cap of samples, and every correlation that becomes a record
    /// holds at least one of them; the rest are bounded by the two days of margin.
    private func readCorrelations(_ type: HKCorrelationType, around start: Date, _ end: Date) async throws -> [HKCorrelation] {
        let margin = HealthRecordMapping.correlationMargin
        let samples = try await readSamples(
            type: type,
            start: start.addingTimeInterval(-margin),
            end: end.addingTimeInterval(margin),
            limit: HKObjectQueryNoLimit
        )
        return samples.compactMap { $0 as? HKCorrelation }
    }

    private func readCategorySamples(
        type: HKCategoryType,
        start: Date,
        end: Date,
        limit: Int
    ) async throws -> [HKCategorySample] {
        try await readSamples(type: type, start: start, end: end, limit: limit).compactMap { $0 as? HKCategorySample }
    }

    /// One HKSampleQuery by start date, under `recordQueryTimeout`. A query that runs out of
    /// time is stopped and throws `BoundedCall.TimedOut`; its late answer is dropped.
    func boundedSampleQuery(
        type: HKSampleType,
        predicate: NSPredicate?,
        limit: Int,
        newestFirst: Bool = false
    ) async throws -> [HKSample] {
        let store = healthStore
        let begin = SampleQueryStart(type: type, predicate: predicate, limit: limit, ascending: !newestFirst)
        let batch: Unchecked<[HKSample]> = try await BoundedCall.run(timeout: HealthKitManager.recordQueryTimeout) { finish in
            let query = HKSampleQuery(
                sampleType: begin.type,
                predicate: begin.predicate,
                limit: begin.limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: begin.ascending)]
            ) { _, samples, error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(Unchecked(value: samples ?? [])))
                }
            }
            store.execute(query)
            let running = Unchecked(value: query as HKQuery)
            return { store.stop(running.value) }
        }
        return batch.value
    }

    /// @unchecked Sendable: HealthKit query parameters are immutable once built, and
    /// HKHealthStore accepts them from any thread.
    private struct SampleQueryStart: @unchecked Sendable {
        let type: HKSampleType
        let predicate: NSPredicate?
        let limit: Int
        let ascending: Bool
    }

    func readSleepData(start: Date, end: Date, limit: Int) async throws -> [[String: Any]] {
        let samples = try await readCategorySamples(
            type: HKCategoryType(.sleepAnalysis),
            start: start, end: end,
            limit: limit
        )

        // Stage values match the Android companion app so both can feed the same backend.
        let stageSamples = samples.compactMap { sample -> SleepStageSample? in
            guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return nil }
            let stage: String
            switch value {
            case .inBed: stage = "in_bed"  // Container only, not a real stage
            case .asleepUnspecified: stage = "sleeping"
            case .asleepCore: stage = "light"
            case .asleepDeep: stage = "deep"
            case .asleepREM: stage = "rem"
            case .awake: stage = "awake"
            @unknown default: stage = "unknown"
            }
            return SleepStageSample(
                stage: stage,
                start: sample.startDate,
                end: sample.endDate,
                uuid: sample.uuid.uuidString,
                source: sample.sourceRevision.source.name
            )
        }

        return SleepSessionBuilder.sessions(from: stageSamples)
    }

    private func readWorkouts(start: Date, end: Date, limit: Int) async throws -> [[String: Any]] {
        let workouts = try await readSamples(
            type: HKWorkoutType.workoutType(),
            start: start, end: end,
            limit: limit
        ).compactMap { $0 as? HKWorkout }

        return workouts.map { workout in
            record(HealthRecordMapping.exerciseFields(
                type: workout.workoutActivityType.name, start: workout.startDate, end: workout.endDate
            ), from: workout)
        }
    }

    private func readNutritionData(start: Date, end: Date, limit: Int) async throws -> [[String: Any]] {
        let foods = try await readCorrelations(HKCorrelationType(.food), around: start, end)
        var samples: [HKQuantitySample] = []
        for nutrient in HealthRecordMapping.mainNutrients {
            samples += try await readQuantitySamples(
                type: HKQuantityType(nutrient.identifier),
                start: start, end: end,
                limit: limit
            )
        }
        return HealthRecordMapping.nutritionRecords(correlations: foods, samples: samples, start: start, end: end)
    }
}

/// Where an incremental read left each type: the anchors past what it read and the
/// catch-up cursor. Saving it tells the next sync that those records are taken care of, so
/// it is saved only after they are: an anchor saved before the payload was delivered or
/// queued lost the records when iOS suspended or ended the app in between.
struct AnchorCommit: @unchecked Sendable {
    struct Anchor {
        let dataType: HealthDataType
        let sampleType: HKSampleType
        let anchor: HKQueryAnchor
    }

    var anchors: [Anchor] = []
    var cursors: [(HealthDataType, Date?)] = []
    /// The samples of bucketed windows still open after this read (see ResolutionApplier),
    /// saved with the anchors that read them and never earlier. Nil leaves the stored carry
    /// alone.
    var bucketCarry: [HealthDataType: [CarriedSample]]?
    /// The types the read left records behind for, which the next read continues with.
    var behind: Set<HealthDataType> = []

    /// The carry first, then cursors, then anchors. An app ended in between reads a stretch
    /// again: a carried sample read again counts once, by its uuid, and an anchor saved without
    /// its cursor, or without the carry, would skip what they still had to hold. A carry that
    /// cannot be written keeps the anchors where they were, for the same reason.
    func save(to prefs: PreferencesManager = .shared, carryStore: BucketCarryStore = .shared) {
        if let bucketCarry, !carryStore.save(bucketCarry) { return }
        for (dataType, cursor) in cursors {
            prefs.saveCatchUpCursor(cursor, for: dataType)
        }
        for saved in anchors {
            prefs.saveAnchor(saved.anchor, for: saved.dataType, sampleType: saved.sampleType)
        }
    }
}

// MARK: - Extensions

/// Carries a value that is not Sendable across a task boundary it crosses exactly once, such as
/// a HealthKit result handed from its callback to the caller, or one type's payload fragment
/// from its read task to the merge.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

extension Date {
    // ISO8601DateFormatter is documented as thread-safe, unlike DateFormatter
    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    var iso8601String: String {
        Date.iso8601Formatter.string(from: self)
    }
}

extension HKWorkoutActivityType {
    /// The payload's `type`: a snake_case name for every activity HealthKit has, so a receiver
    /// never sees "other" for a workout HealthKit named. Names that went out before stay as
    /// they were (`hiit` among them). The deprecated cases still name workouts saved under them.
    var name: String {
        switch self {
        case .americanFootball: return "american_football"
        case .archery: return "archery"
        case .australianFootball: return "australian_football"
        case .badminton: return "badminton"
        case .baseball: return "baseball"
        case .basketball: return "basketball"
        case .bowling: return "bowling"
        case .boxing: return "boxing"
        case .climbing: return "climbing"
        case .cricket: return "cricket"
        case .crossTraining: return "cross_training"
        case .curling: return "curling"
        case .cycling: return "cycling"
        case .dance: return "dance"
        case .danceInspiredTraining: return "dance_inspired_training"
        case .elliptical: return "elliptical"
        case .equestrianSports: return "equestrian_sports"
        case .fencing: return "fencing"
        case .fishing: return "fishing"
        case .functionalStrengthTraining: return "functional_strength_training"
        case .golf: return "golf"
        case .gymnastics: return "gymnastics"
        case .handball: return "handball"
        case .hiking: return "hiking"
        case .hockey: return "hockey"
        case .hunting: return "hunting"
        case .lacrosse: return "lacrosse"
        case .martialArts: return "martial_arts"
        case .mindAndBody: return "mind_and_body"
        case .mixedMetabolicCardioTraining: return "mixed_metabolic_cardio_training"
        case .paddleSports: return "paddle_sports"
        case .play: return "play"
        case .preparationAndRecovery: return "preparation_and_recovery"
        case .racquetball: return "racquetball"
        case .rowing: return "rowing"
        case .rugby: return "rugby"
        case .running: return "running"
        case .sailing: return "sailing"
        case .skatingSports: return "skating_sports"
        case .snowSports: return "snow_sports"
        case .soccer: return "soccer"
        case .softball: return "softball"
        case .squash: return "squash"
        case .stairClimbing: return "stair_climbing"
        case .surfingSports: return "surfing_sports"
        case .swimming: return "swimming"
        case .tableTennis: return "table_tennis"
        case .tennis: return "tennis"
        case .trackAndField: return "track_and_field"
        case .traditionalStrengthTraining: return "traditional_strength_training"
        case .volleyball: return "volleyball"
        case .walking: return "walking"
        case .waterFitness: return "water_fitness"
        case .waterPolo: return "water_polo"
        case .waterSports: return "water_sports"
        case .wrestling: return "wrestling"
        case .yoga: return "yoga"
        case .barre: return "barre"
        case .coreTraining: return "core_training"
        case .crossCountrySkiing: return "cross_country_skiing"
        case .downhillSkiing: return "downhill_skiing"
        case .flexibility: return "flexibility"
        case .highIntensityIntervalTraining: return "hiit"
        case .jumpRope: return "jump_rope"
        case .kickboxing: return "kickboxing"
        case .pilates: return "pilates"
        case .snowboarding: return "snowboarding"
        case .stairs: return "stairs"
        case .stepTraining: return "step_training"
        case .wheelchairWalkPace: return "wheelchair_walk_pace"
        case .wheelchairRunPace: return "wheelchair_run_pace"
        case .taiChi: return "tai_chi"
        case .mixedCardio: return "mixed_cardio"
        case .handCycling: return "hand_cycling"
        case .discSports: return "disc_sports"
        case .fitnessGaming: return "fitness_gaming"
        case .cardioDance: return "cardio_dance"
        case .socialDance: return "social_dance"
        case .pickleball: return "pickleball"
        case .cooldown: return "cooldown"
        case .swimBikeRun: return "swim_bike_run"
        case .transition: return "transition"
        case .underwaterDiving: return "underwater_diving"
        case .other: return "other"
        // A type from a later iOS than the SDK this was built with; the compiler names any
        // case of the SDK missing above.
        @unknown default: return "other"
        }
    }
}
