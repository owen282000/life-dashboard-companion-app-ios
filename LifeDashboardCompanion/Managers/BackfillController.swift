import BackgroundTasks
import Foundation
import HealthKit
import OSLog
import UIKit
import WidgetKit

/// Runs the backfill for the screen and keeps its job on disk. MainActor: the job, the run
/// token and the keep-alive state are only touched here; the engine runs off the main actor
/// and reports back through the closures, which check the token so a stale run cannot write.
@MainActor
final class BackfillController: ObservableObject {
    static let shared = BackfillController()
    static let rangeOptions = [30, 90, 365]
    static let logDataType = "health_connect_backfill"

    @Published private(set) var job: BackfillJob?
    @Published private(set) var progress: BackfillProgress?
    /// Pause was asked for; the chunk in flight finishes first.
    @Published private(set) var isStopping = false
    /// iOS 26 runs the backfill as a continued processing task, which goes on after the user
    /// leaves the app and shows its progress in the system UI.
    @Published private(set) var runsInBackground = false

    var isRunning: Bool { job?.status == .running }

    private let logger = Logger(subsystem: "com.owen282000.lifedashboard", category: "Backfill")
    private let store = BackfillJobStore(defaults: .standard)
    private let prefs = PreferencesManager.shared
    private var runTask: Task<Void, Never>?
    private var runToken: UUID?
    private var stopReason: BackfillJob.PauseReason?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var segmentStart = 0
    private var segmentStartWindow = 0
    private var continuedTask: BGTask?
    private var passesInWindow = 0

    private init() {
        if var saved = store.load() {
            if saved.status == .done {
                // The "complete" line is for the session it finished in.
                store.clear()
            } else if saved.status == .running {
                // Found running: the app was closed or crashed during the run.
                saved = saved.paused(.closed, at: saved.updatedAt)
                store.save(saved)
            }
            job = saved.status == .done ? nil : saved
        }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BackfillController.shared.resumeIfInterrupted() }
        }
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BackfillController.shared.requestStop(.locked) }
        }
    }

    // MARK: - Actions

    func start(days: Int) {
        guard !isRunning else { return }
        let range = BackfillPlan.range(
            days: days, now: Date(), earliestPermitted: HealthKitManager.shared.healthStore.earliestPermittedSampleDate()
        )
        run(BackfillJob(days: days, range: range))
    }

    func resume() {
        guard let job, !isRunning, job.status == .paused || job.status == .failed else { return }
        run(job)
    }

    /// Stops after the chunk in flight; Resume continues at the window that was not finished.
    func pause() {
        requestStop(.user)
    }

    /// Forgets the job. What was sent stays on the receiver.
    func discard() {
        requestStop(.user)
        runTask?.cancel()
        runToken = nil
        store.clear()
        job = nil
        progress = nil
        endKeepAlive()
    }

    // MARK: - Run

    private func run(_ start: BackfillJob) {
        let token = UUID()
        runToken = token
        stopReason = nil
        isStopping = false
        segmentStart = start.recordsSent
        segmentStartWindow = start.nextWindow
        var running = start
        running.status = .running
        running.pauseReason = nil
        running.failure = nil
        job = running
        store.save(running)
        progress = BackfillProgress(windowsDone: start.nextWindow, windowCount: start.windowCount, recordsSent: start.recordsSent)
        beginKeepAlive()
        submitContinuedTask(for: token, job: running)

        let prefs = prefs
        let engine = BackfillEngine(
            reader: HealthKitBackfillReader(),
            sink: WebhookBackfillSink(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            enabledTypes: { Array(prefs.healthEnabledDataTypes) },
            shouldStop: { await BackfillController.shared.stopRequest(for: token) },
            onProgress: { progress in await BackfillController.shared.report(progress, for: token) },
            onWindowDone: { job, records in await BackfillController.shared.commit(job, windowRecords: records, for: token) }
        )
        runTask = Task.detached(priority: .userInitiated) {
            let final = await engine.run(running)
            await BackfillController.shared.finish(final, for: token)
        }
    }

    private func requestStop(_ reason: BackfillJob.PauseReason) {
        guard isRunning, stopReason == nil else { return }
        stopReason = reason
        isStopping = true
    }

    private func stopRequest(for token: UUID) -> BackfillJob.PauseReason? {
        guard token == runToken else { return .interrupted }
        if let stopReason { return stopReason }
        // Before iOS lets the app go, stop at a pass boundary instead of being cut off mid-post.
        let app = UIApplication.shared
        if continuedTask == nil, app.applicationState == .background, app.backgroundTimeRemaining < 10 {
            return .background
        }
        return nil
    }

    private func report(_ progress: BackfillProgress, for token: UUID) {
        guard token == runToken else { return }
        passesInWindow = progress.windowsDone == self.progress?.windowsDone ? passesInWindow + 1 : 1
        self.progress = progress
        updateContinuedTask(progress)
    }

    private func commit(_ committed: BackfillJob, windowRecords: Int, for token: UUID) {
        guard token == runToken else { return }
        store.save(committed)
        job = committed
        // A delivered window counts on the dashboard, as on Android: "today" and "last sync"
        // would otherwise say nothing while thousands of records go out.
        SharedSyncStatus.record(success: true, records: windowRecords)
    }

    private func finish(_ final: BackfillJob, for token: UUID) {
        guard token == runToken else { return }
        runToken = nil
        runTask = nil
        stopReason = nil
        isStopping = false
        store.save(final)
        job = final
        progress = nil
        if final.failure == .delivery {
            SharedSyncStatus.record(success: false, records: 0)
        }
        WidgetCenter.shared.reloadAllTimelines()
        logSegment(final)
        completeContinuedTask(success: final.status == .done)
        endKeepAlive()
        logger.info("Backfill \(final.status.rawValue) after \(final.nextWindow) of \(final.windowCount) windows, \(final.recordsSent) records")
        continueIfBack(final)
    }

    /// A pause for the background or the lock can end after the app is already back: iOS
    /// froze the run mid-pass and it only reached the stop once the app was active again. The
    /// activation that would resume it has passed then, so the run picks up here. After a lock
    /// only when the last run got somewhere, so a store that is still closing cannot loop.
    private func continueIfBack(_ final: BackfillJob) {
        let app = UIApplication.shared
        guard final.status == .paused, app.applicationState == .active, app.isProtectedDataAvailable,
              BackfillResume.shouldAutoResume(
                final,
                now: Date(),
                hasWebhook: !prefs.healthWebhookUrls.isEmpty,
                hasTypes: !prefs.healthEnabledDataTypes.isEmpty
              ) else { return }
        switch final.pauseReason {
        case .background:
            run(final)
        case .locked where final.nextWindow > segmentStartWindow:
            run(final)
        default:
            break
        }
    }

    /// One row in the Logs tab per run, since the chunks that went through are not logged.
    private func logSegment(_ final: BackfillJob) {
        let sent = final.recordsSent - segmentStart
        guard sent > 0 || final.status == .done || final.failure != nil else { return }
        let summary: [String: Any] = [
            "backfill": true,
            "status": final.status.rawValue,
            "windows_done": final.nextWindow,
            "window_count": final.windowCount,
            "records_sent": sent
        ]
        let raw = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        prefs.addWebhookLog(WebhookLog(
            url: prefs.healthWebhookUrls.first ?? "backfill",
            success: final.status != .failed,
            errorMessage: final.failure.map(BackfillController.describe),
            dataType: BackfillController.logDataType,
            recordCount: sent,
            rawPayload: raw,
            logType: .healthConnect
        ))
    }

    private func resumeIfInterrupted() {
        guard let job, !isRunning else { return }
        if BackfillResume.shouldAutoResume(
            job,
            now: Date(),
            hasWebhook: !prefs.healthWebhookUrls.isEmpty,
            hasTypes: !prefs.healthEnabledDataTypes.isEmpty
        ) {
            run(job)
        }
    }

    // MARK: - Keeping the run alive

    /// The screen stays on while the backfill runs, and iOS gives about 30 seconds after the
    /// user leaves the app. HealthKit cannot be read while the iPhone is locked, so there is
    /// nothing to gain from running later in the background: the run pauses and resumes when
    /// the app is opened again.
    private func beginKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = true
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Backfill") {
            MainActor.assumeIsolated {
                let controller = BackfillController.shared
                // A continued processing task keeps the run going past this.
                if controller.continuedTask == nil {
                    controller.requestStop(.background)
                }
                controller.endBackgroundTask()
            }
        }
    }

    private func endKeepAlive() {
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - iOS 26: continued processing

    static let continuedTaskPrefix = "com.owen282000.lifedashboard.backfill."

    /// Asks iOS 26 to keep the run going when the user leaves the app. The request has to be
    /// made while the app is in front, and is registered under an identifier of its own each
    /// time: iOS stops the app when one identifier gets a second handler. When iOS says no, the
    /// run carries on as on older versions.
    private func submitContinuedTask(for token: UUID, job: BackfillJob) {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *), UIApplication.shared.applicationState == .active else { return }
        let identifier = BackfillController.continuedTaskPrefix + token.uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { BackfillController.shared.attach(task, for: token) }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Backfill History",
            subtitle: "Backfilling \(job.nextWindow)/\(job.windowCount)..."
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.info("Backfill runs in the foreground only: \(error.localizedDescription)")
        }
        #endif
    }

    private func attach(_ task: BGTask, for token: UUID) {
        guard token == runToken, isRunning else {
            task.setTaskCompleted(success: false)
            return
        }
        continuedTask = task
        runsInBackground = true
        task.expirationHandler = {
            // iOS ended it, or the user stopped it from the system UI: the two look the same.
            Task { @MainActor in
                let controller = BackfillController.shared
                controller.requestStop(.system)
                controller.completeContinuedTask(success: false)
            }
        }
        if let progress { updateContinuedTask(progress) }
    }

    /// The system expires a continued task whose progress looks stalled, so it moves on every
    /// pass: a hundred units per window, and one per pass inside it.
    private func updateContinuedTask(_ progress: BackfillProgress) {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = Int64(max(progress.windowCount, 1) * 100)
        task.progress.completedUnitCount = Int64(progress.windowsDone * 100 + min(passesInWindow, 99))
        task.updateTitle("Backfill History", subtitle: "Backfilling \(progress.windowsDone)/\(progress.windowCount)...")
        #endif
    }

    private func completeContinuedTask(success: Bool) {
        continuedTask?.setTaskCompleted(success: success)
        continuedTask = nil
        runsInBackground = false
    }

    static func describe(_ failure: BackfillJob.Failure) -> String {
        switch failure {
        case .delivery: return "Delivery failed"
        case .read(let type): return "HealthKit did not return \(type)"
        }
    }
}

// MARK: - HealthKit and webhook

/// Reads backfill slices from HealthKit with the sync's own mapping, so a backfilled record is
/// the same as a synced one, uuid included.
struct HealthKitBackfillReader: BackfillReading {
    func canRead() async -> Bool {
        await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
    }

    func readSlice(_ type: HealthDataType, from cursor: Date, window: DateInterval, rangeEnd: Date) async throws -> BackfillSlice {
        let healthKit = HealthKitManager.shared
        do {
            switch type {
            case .sleep:
                return try await readSleep(window: window, rangeEnd: rangeEnd, healthKit: healthKit)
            case .menstruation:
                return try await readCycle(window: window, rangeEnd: rangeEnd, healthKit: healthKit)
            default:
                let slice = try await healthKit.nextSlice(for: type, from: cursor, to: window.end)
                let records = try await healthKit.readDataForType(type, start: cursor, end: slice.end) ?? []
                return BackfillSlice(records: records, end: slice.end, exact: slice.exact)
            }
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            throw BackfillReadError.locked
        }
    }

    /// Sessions are built from stages read a day around the window and sent by the window they
    /// end in, so a night that crosses a window bound goes out once and whole.
    private func readSleep(window: DateInterval, rangeEnd: Date, healthKit: HealthKitManager) async throws -> BackfillSlice {
        let limit = 2000
        let start = window.start.addingTimeInterval(-BackfillPlan.sleepPadding)
        let end = min(window.end.addingTimeInterval(BackfillPlan.sleepPadding), rangeEnd)
        let stages = try await healthKit.readSamples(type: HKCategoryType(.sleepAnalysis), start: start, end: end, limit: limit)
        let sessions = try await healthKit.readSleepData(start: start, end: end, limit: limit).filter { session in
            guard let end = (session["session_end_time"] as? String).flatMap(BackfillController.parseDate) else { return false }
            return BackfillPlan.ownsSession(endingAt: end, window: window, rangeEnd: rangeEnd)
        }
        return BackfillSlice(records: sessions.isEmpty ? [] : [("sleep", sessions)], end: window.end, exact: stages.count < limit)
    }

    /// Flow records by their own time; periods, which the app derives from flow days, from two
    /// weeks around the window and sent by the window they start in.
    private func readCycle(window: DateInterval, rangeEnd: Date, healthKit: HealthKitManager) async throws -> BackfillSlice {
        let flow = try await healthKit.readDataForType(.menstruation, start: window.start, end: window.end) ?? []
        let around = try await healthKit.readDataForType(
            .menstruation,
            start: window.start.addingTimeInterval(-BackfillPlan.periodPadding),
            end: min(window.end.addingTimeInterval(BackfillPlan.periodPadding), rangeEnd)
        ) ?? []
        let flowRecords = flow.first { $0.0 == "menstruation_flow" }.map { [$0] } ?? []
        let periods = (around.first { $0.0 == "menstruation_period" }?.1 as? [[String: Any]] ?? []).filter { period in
            guard let start = (period["start_time"] as? String).flatMap(BackfillController.parseDate) else { return false }
            return BackfillPlan.ownsPeriod(startingAt: start, window: window)
        }
        let flowCount = BackfillPayload.recordCount(flowRecords)
        let records = flowRecords + (periods.isEmpty ? [] : [("menstruation_period", periods as Any)])
        return BackfillSlice(
            records: records, end: window.end, exact: flowCount < SyncLimits.maxRecordsPerSync(for: .menstruation)
        )
    }
}

struct WebhookBackfillSink: BackfillDelivering {
    func deliver(_ body: Data, recordCount: Int) async -> Bool {
        let prefs = PreferencesManager.shared
        return await WebhookManager.shared.post(
            body: body,
            urls: prefs.healthWebhookUrls,
            headers: prefs.healthWebhookHeaders,
            logType: .healthConnect,
            dataType: BackfillController.logDataType,
            recordCount: recordCount,
            logSuccess: false
        )
    }
}

extension BackfillController {
    nonisolated(unsafe) private static let isoParser = ISO8601DateFormatter()

    /// Parses the payload's own timestamps back; ISO8601DateFormatter is thread-safe.
    nonisolated static func parseDate(_ string: String) -> Date? {
        isoParser.date(from: string)
    }
}
