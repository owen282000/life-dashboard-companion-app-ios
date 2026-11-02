import HealthKit
import StoreKit
import SwiftUI

/// The Health tab: where the data goes, whether it arrives, and what the user sends. Its four
/// states come from the settings and the log, nothing from a state of its own.
struct HomeScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared
    @ObservedObject private var healthKit = HealthKitManager.shared
    @ObservedObject private var backfill = BackfillController.shared
    @EnvironmentObject private var pairing: PairingCoordinator
    @EnvironmentObject private var navigator: LDNavigator

    @StateObject private var today = TodayStatsProvider()
    @State private var deliveries = HomeDeliveries()
    @State private var pendingCount = 0
    @State private var isSyncing = false
    @State private var outcome: SyncOutcome?

    // UI state, not a setting, so it stays out of PreferencesManager and the settings backup.
    @AppStorage("refresh_hint_dismissed") private var refreshHintDismissed = false
    @State private var refreshOff = false
    @State private var lowPower = false
    @State private var overdueSince: Date?

    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if healthKit.isAvailable {
                home
            } else {
                unavailable
            }
        }
        .task { await askOnceAfterUpdate() }
        .onAppear {
            considerReview()
            reload()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                considerReview()
                reload()
            }
        }
        // A new log row and every settings change come through here, also from a background sync.
        .onReceive(prefs.objectWillChange.debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in reload() }
        // A backfill that just finished is a good moment of its own.
        .onChange(of: backfill.job?.status) { _, status in if status == .done { considerReview(backfillDone: true) } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)) { _ in checkHolds() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in checkHolds() }
    }

    // MARK: - States

    private var unavailable: some View {
        LDScreen {
            LDHeading("Apple Health is not available")
            PulseLine(variant: .flat)
            LDNote("This device cannot share Health data with apps.", top: 4)
        } pinned: {
            // About, Backup and Appearance live behind More, and do not need Health.
            LDTileGrid {
                moreTile
            }
        }
    }

    private var home: some View {
        let destinations = self.destinations
        let state = state(of: destinations)
        return LDScreen {
            LDHeading(state.heading)
            PulseLine(variant: state.pulse)
                .id(state.pulse)
            if state == .noDestination {
                firstStart
            } else {
                destinationList(destinations, state: state)
            }
            if let outcome {
                HomeNoticeLine(systemImage: outcome.tone.systemImage, text: outcome.text, color: outcome.ldColor)
            }
            holds
            if pendingCount > 0 {
                LDBanner(Text("\(pendingCount) pending syncs")) {
                    LDBannerAction("Retry Now", action: retryPending)
                }
            }
            if state != .noDestination {
                TodayPanel(provider: today, firstIndex: destinations.count)
            }
            if prefs.healthSyncConfigured {
                statusLine
            }
        } pinned: {
            LDTileGrid {
                LDTile("What to send", subtitle: whatToSendSummary, systemImage: LDSymbol.whatToSend)
                    .ldLink(to: .whatToSend)
                LDTile("When to send", subtitle: whenToSendSummary, systemImage: LDSymbol.whenToSend)
                    .ldLink(to: .whenToSend)
                LDTile("Notifications", subtitle: notificationsSummary, systemImage: LDSymbol.notifications)
                    .ldLink(to: .notifications)
                moreTile
            }
        }
    }

    private func state(of destinations: [HomeDestination]) -> HomeState {
        if destinations.isEmpty { return .noDestination }
        if prefs.healthEnabledDataTypes.isEmpty { return .nothingSelected }
        let failing = destinations.filter(\.hasProblem)
        if !failing.isEmpty { return .problem(failing.map(\.name)) }
        if overdueSince != nil { return .overdue }
        if deliveries.isLoaded, destinations.allSatisfy({ $0.delivery == nil }) { return .waiting }
        return .arriving
    }

    private var firstStart: some View {
        Group {
            LDGap(4)
            LDButton("Scan a pairing code") { pairing.startScan() }
            LDGap(10)
            LDButton("Use your own server", kind: .ghost) { navigator.present(.addDestination) }
            LDNote("A pairing code comes from Home Assistant or the Life Dashboard Stack.")
        }
    }

    // MARK: - Destinations

    /// One per webhook URL, then MQTT when it is on.
    private var destinations: [HomeDestination] {
        let links = prefs.healthWebhookUrls.map { PairingLink(url: $0, secret: "", name: nil) }
        let integrations = links.filter(\.looksLikeHomeAssistant).count
        var list = links.enumerated().map { index, link in
            HomeDestination(
                id: index,
                // Two instances of the integration are told apart by their host.
                name: link.looksLikeHomeAssistant && integrations == 1 ? "Home Assistant" : link.host,
                route: .webhookDestination(address: link.url),
                delivery: deliveries.webhooks[link.url]
            )
        }
        if prefs.mqttEnabled {
            let host = prefs.mqttHost.trimmingCharacters(in: .whitespaces)
            list.append(HomeDestination(
                id: list.count,
                name: host.isEmpty ? SyncStats.mqttSource : String(localized: "Broker \(host)"),
                route: .mqttDestination,
                delivery: deliveries.mqtt,
                hasNoBroker: host.isEmpty
            ))
        }
        return list
    }

    private func destinationList(_ destinations: [HomeDestination], state: HomeState) -> some View {
        Group {
            TimelineView(.everyMinute) { context in
                VStack(spacing: 0) {
                    ForEach(destinations) { destination in
                        let status = status(of: destination, state: state, now: context.date)
                        LDDestinationRow(Text(verbatim: destination.name), status: status.text, statusColor: status.color)
                            .ldButton { navigator.present(destination.route) }
                            .ldStaggerRise(destination.id)
                    }
                }
            }
            HStack(spacing: 8) {
                LDTextButton("Add destination") { navigator.present(.addDestination) }
                Spacer(minLength: 8)
                // With nothing selected there is nothing to sync, so the board has no button.
                if state != .nothingSelected {
                    LDButton(isSyncing ? Text("Syncing...") : Text("Sync now"), size: .small, fullWidth: false, isBusy: isSyncing, action: syncNow)
                        .disabled(!prefs.healthSyncConfigured || backfill.isRunning)
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, LDTheme.textInset)
        }
    }

    private func status(of destination: HomeDestination, state: HomeState, now: Date) -> (text: Text, color: Color) {
        if destination.hasNoBroker {
            return (Text("On: no broker set"), LDTheme.warning)
        }
        if state == .nothingSelected {
            return (Text("Connected"), LDTheme.inactive)
        }
        guard let delivery = destination.delivery else {
            // Blank for the moment the log takes to read, so a row never says something untrue.
            return (deliveries.isLoaded ? Text("No deliveries yet") : Text(verbatim: " "), LDTheme.inactive)
        }
        let time = Self.time(since: delivery.date, now: now)
        if delivery.succeeded {
            return (Text(verbatim: time), LDTheme.accentTextSoft)
        }
        if let code = delivery.statusCode {
            return (Text("HTTP \(code), \(time)"), LDTheme.warning)
        }
        return (Text("Failed, \(time)"), LDTheme.warning)
    }

    private static func time(since date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "just now") }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    // MARK: - Holds

    /// iOS has no battery exemption per app, but two settings hold background syncs the same way:
    /// Background App Refresh off (a card, until "Don't show again"), and Low Power Mode on (one
    /// line, since it switches itself off). And when nothing was delivered for longer than the
    /// schedule explains (`SyncHealthCheck`), a line that says since when, with the likely cause.
    @ViewBuilder
    private var holds: some View {
        if prefs.healthSyncConfigured {
            if showsRefreshCard {
                refreshCard
            }
            if lowPower {
                HomeNoticeLine(
                    systemImage: "battery.25percent",
                    text: Text("Low Power Mode is on, so syncs can wait until it switches off."),
                    color: LDTheme.warningText
                )
            }
            // With the card showing, the card says since when; the banner would say it twice.
            if let overdueSince, !showsRefreshCard {
                LDBanner(overdueText(since: overdueSince))
            }
            if showsRefreshCard || lowPower || overdueSince != nil {
                LDGap(8)
            }
        }
    }

    private var showsRefreshCard: Bool { refreshOff && !refreshHintDismissed }

    private var refreshCard: some View {
        LDBanner("Background App Refresh is off", message: Text("Background syncs can come later.")) {
            if let overdueSince {
                Text("Nothing delivered since \(overdueSince.formatted(date: .abbreviated, time: .omitted)).")
                    .font(LDType.sans(14, .bold, relativeTo: .subheadline))
                    .foregroundStyle(LDTheme.warningText)
                    .padding(.top, 4)
            }
            // The space is on the buttons: the layout's own spacing would also part its rows.
            LDFlowLayout(spacing: 0) {
                LDBannerAction("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .padding(.trailing, 16)
                LDBannerAction("Help for your phone") { openURL(AboutLinks.troubleshooting) }
                    .padding(.trailing, 16)
                LDBannerAction("Don't show again") { refreshHintDismissed = true }
            }
        }
    }

    private func overdueText(since: Date) -> Text {
        let day = since.formatted(date: .abbreviated, time: .omitted)
        switch SyncHealthCheck.cause(refreshOff: refreshOff, lowPower: lowPower) {
        case .refreshOff: return Text("Nothing delivered since \(day). Background App Refresh is off for Life Dashboard.")
        case .lowPower: return Text("Nothing delivered since \(day). Low Power Mode may be holding the syncs.")
        case .unknown: return Text("Nothing delivered since \(day). The Logs tab shows what happened.")
        }
    }

    private func checkHolds() {
        refreshOff = UIApplication.shared.backgroundRefreshStatus != .available
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let delivered = SharedSyncStatus.read().lastDelivered
        overdueSince = SyncHealthCheck.isOverdue(
            lastDelivered: delivered, now: Date(), schedule: prefs.healthSyncSchedule,
            hasDestination: prefs.healthSyncConfigured, timeZone: .current
        ) ? delivered : nil
        #if DEBUG
        // For screenshots: -ld.holds "refresh,power,quiet" shows the card and both lines.
        if let holds = UserDefaults.standard.string(forKey: "ld.holds")?.split(separator: ",").map(String.init) {
            refreshOff = holds.contains("refresh")
            lowPower = holds.contains("power")
            overdueSince = holds.contains("quiet") ? Date().addingTimeInterval(-3 * 86400) : nil
        }
        #endif
    }

    // MARK: - Status line and tiles

    /// Only while automatic syncs are held. The plain cadence is on the When to send tile and the
    /// addresses are the rows, and one more line would push the tiles under the tab bar.
    private var statusLine: some View {
        TimelineView(.everyMinute) { context in
            if prefs.healthSyncSchedule.hold(at: context.date, timeZone: .autoupdatingCurrent) != nil {
                LDNote(
                    Text(verbatim: ScheduleStatusLine.text(
                        schedule: prefs.healthSyncSchedule,
                        webhookCount: prefs.healthWebhookUrls.count,
                        mqtt: prefs.mqttConfigured,
                        now: context.date,
                        timeZone: .autoupdatingCurrent
                    )),
                    color: LDTheme.muted,
                    top: 12,
                    size: 13
                )
            }
        }
    }

    private var moreTile: some View {
        LDTile("More", subtitle: Text("Backup, about"), systemImage: LDSymbol.more)
            .ldLink(to: .more)
    }

    private var whatToSendSummary: Text {
        let count = prefs.healthEnabledDataTypes.count
        return count == 0 ? Text("None yet") : Text("\(count) of \(HealthDataType.allCases.count) types")
    }

    private var whenToSendSummary: Text {
        let schedule = prefs.healthSyncSchedule
        if schedule.isNeverRunning {
            return schedule.mode == .times && schedule.times.isEmpty ? Text("No sync times yet") : Text("Off")
        }
        switch schedule.mode {
        case .interval:
            return Text("Every \(schedule.intervalMinutes) min")
        case .times:
            let count = Set(schedule.times).count
            return count == 1 ? Text("Once a day") : Text("\(count) times a day")
        }
    }

    private var notificationsSummary: Text {
        prefs.failureNotificationsEnabled ? Text("After \(prefs.failureNotificationThreshold) failures") : Text("Off")
    }

    // MARK: - Actions

    private func syncNow() {
        isSyncing = true
        outcome = nil
        Task {
            let result = await SyncCoordinator.shared.runManual(syncNow: true)
            await MainActor.run {
                isSyncing = false
                report(SyncOutcome(result))
                reload()
            }
        }
    }

    private func report(_ result: SyncOutcome) {
        outcome = result
        if case .synced = result { considerReview() }
        AccessibilityNotification.Announcement(result.announcement).post()
    }

    private func retryPending() {
        Task {
            await SyncCoordinator.shared.drain(automatic: false)
            await MainActor.run { reload() }
        }
    }

    /// Everything on the screen that lives outside the settings: read off the main thread, since
    /// the log is up to a hundred files with payloads.
    private func reload() {
        checkHolds()
        let urls = prefs.healthWebhookUrls
        Task {
            let read = await Task.detached(priority: .utility) {
                (HomeDeliveries(logs: LogStore.shared.load(), urls: urls), PendingSyncStore.shared.pendingCount)
            }.value
            deliveries = read.0
            pendingCount = read.1
        }
        Task { await today.refresh(enabled: prefs.healthEnabledDataTypes) }
    }

    /// After an update that gives an enabled type more sample types (distance in 1.5.0), the
    /// Grant chip alone went unnoticed, and the type sent less than it could. The tab asks iOS
    /// once by itself when there is something to ask, never over the setup.
    private func askOnceAfterUpdate() async {
        guard UserDefaults.standard.bool(forKey: "onboarding_completed") else { return }
        #if DEBUG
        // For screenshots: -ld.ask NO, or the default, keeps the Health sheet away.
        if UserDefaults.standard.object(forKey: "ld.ask") as? Bool == false { return }
        #endif
        await healthKit.askOnceForEnabledTypes(prefs.healthEnabledDataTypes)
    }

    /// Asks for an App Store rating at a good moment (P1-28): see `ReviewPrompt`. The first use
    /// is noted here too, the first time this screen shows after the setup.
    private func considerReview(backfillDone: Bool = false) {
        let defaults = UserDefaults.standard
        let now = Date()
        if defaults.object(forKey: ReviewPrompt.firstUseKey) == nil { defaults.set(now, forKey: ReviewPrompt.firstUseKey) }
        let status = SharedSyncStatus.read()
        let state = ReviewPrompt.State(
            lastDelivered: status.lastDelivered,
            lastSyncSucceeded: status.lastSuccess,
            failureStreak: defaults.integer(forKey: "sync_failure_streak"),
            partialStreak: defaults.integer(forKey: "sync_partial_streak"),
            pending: PendingSyncStore.shared.pendingCount
        )
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard ReviewPrompt.shouldAsk(
            goodMoment: backfillDone || ReviewPrompt.isGoodMoment(state, now: now),
            firstUse: defaults.object(forKey: ReviewPrompt.firstUseKey) as? Date,
            askedVersion: defaults.string(forKey: ReviewPrompt.askedVersionKey),
            version: version, now: now
        ) else { return }
        defaults.set(version, forKey: ReviewPrompt.askedVersionKey)
        requestReview()
    }
}

// MARK: - State

private enum HomeState: Equatable {
    case noDestination
    case nothingSelected
    /// The names of the destinations that need attention.
    case problem([String])
    /// Nothing delivered for longer than the schedule explains.
    case overdue
    /// Set up, and the first delivery is still to come.
    case waiting
    case arriving

    var heading: Text {
        switch self {
        case .noDestination: return Text("Where should your data go?")
        case .nothingSelected: return Text("Connected. Now pick your data.")
        case .problem(let names):
            if names.count == 1 { return Text("\(names[0]) needs you.") }
            return Text("\(names.count) destinations need you.")
        case .overdue: return Text("Nothing has arrived lately.")
        case .waiting: return Text("Ready for the first sync.")
        case .arriving: return Text("Your data is arriving.")
        }
    }

    var pulse: PulseLine.Variant {
        switch self {
        case .arriving: return .normal
        case .problem, .overdue: return .warning
        case .noDestination, .nothingSelected, .waiting: return .flat
        }
    }
}

private struct HomeDestination: Identifiable {
    let id: Int
    let name: String
    let route: LDSheetRoute
    let delivery: HomeDelivery?
    var hasNoBroker = false

    var hasProblem: Bool { hasNoBroker || delivery?.succeeded == false }
}

private struct HomeDelivery: Sendable {
    let date: Date
    let succeeded: Bool
    let statusCode: Int?

    init(_ log: WebhookLog) {
        date = log.timestamp
        succeeded = log.success
        statusCode = log.statusCode
    }
}

/// The last delivery per destination, from the log.
private struct HomeDeliveries: Sendable {
    var webhooks: [String: HomeDelivery] = [:]
    var mqtt: HomeDelivery?
    var isLoaded = false

    init() {}

    /// `logs` is newest first, so the first row that counts is the last delivery.
    init(logs: [WebhookLog], urls: [String]) {
        isLoaded = true
        let rows = logs.filter(Self.isDelivery)
        mqtt = rows.first(where: \.isMqtt).map(HomeDelivery.init)
        for url in urls {
            webhooks[url] = rows.first { !$0.isMqtt && $0.url == url }.map(HomeDelivery.init)
        }
    }

    /// Not a delivery: a test ping or pairing check, which the destination sheet reports itself; a
    /// delivery iOS cut off, which says nothing about the receiver (as in `SyncStats`); a read
    /// failure; and an item dropped from the queue, whose row can be newer than a delivery that
    /// went fine, and which lists every address it was queued for.
    private static func isDelivery(_ log: WebhookLog) -> Bool {
        guard log.dataType != "test", !log.isInterrupted else { return false }
        guard log.syncKind == .webhook || log.syncKind == .mqtt else { return false }
        let dropped = log.errorMessage == AppDiagnostic.droppedUndelivered.rawValue
            || log.errorMessage == AppDiagnostic.droppedFull.rawValue
            || (log.errorMessage != nil && log.statusCode.map(AppDiagnostic.droppedRefused) == log.errorMessage)
        return !dropped
    }
}

// MARK: - Small parts

private extension SyncOutcome {
    var ldColor: Color {
        switch tone {
        case .success: return LDTheme.accentText
        case .failure, .warning: return LDTheme.warning
        case .info: return LDTheme.secondary
        }
    }
}

/// A result or a hold in one line: a symbol as well as a colour, so the state does not rest on
/// colour alone. The kit's LDNote has no symbol.
private struct HomeNoticeLine: View {
    let systemImage: String
    let text: Text
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(LDType.noteSmall)
                .accessibilityHidden(true)
            text
                .font(LDType.note)
                .lineSpacing(LDType.lineSpacing(size: 14, lineHeight: 20))
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .padding(.horizontal, LDTheme.textInset)
        .accessibilityElement(children: .combine)
    }
}
