import SwiftUI

/// Every pushed page. ContentView registers `destination` once, for both tabs, so a screen only
/// needs `NavigationLink(value:)`, `.ldLink(to:)`, `LDButton(route:)` or `navigator.push(_:)`.
enum LDRoute: Hashable {
    // What to send
    case whatToSend
    case typeCategory(LDTypeCategory)
    case dataResolution
    case backfillRun
    // When to send
    case whenToSend
    // More
    case more
    case advanced
    case notifications
    case exportData
    case backupRestore
    // Logs: `id` is WebhookLog.id, so a large payload does not travel in the path.
    case logDetail(id: String)
    // About
    case about
    case aboutHelp
    case aboutSupport
    case aboutPrivacy
    case aboutOpenSource
    case aboutNerdStats

    var isAbout: Bool {
        switch self {
        case .about, .aboutHelp, .aboutSupport, .aboutPrivacy, .aboutOpenSource, .aboutNerdStats:
            return true
        default:
            return false
        }
    }

    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .whatToSend: WhatToSendScreen()
        case .typeCategory(let category): TypeCategoryScreen(category: category)
        case .dataResolution: DataResolutionScreen()
        case .backfillRun: BackfillScreen(stage: .running)
        case .whenToSend: WhenToSendScreen()
        case .more: MoreScreen()
        case .advanced: AdvancedScreen()
        case .notifications: NotificationSettingsScreen()
        case .exportData: ExportDataScreen()
        case .backupRestore: BackupRestoreScreen()
        case .logDetail(let id): LogDetailScreen(logID: id)
        case .about: AboutHomeScreen()
        case .aboutHelp: AboutHelpScreen()
        case .aboutSupport: AboutSupportScreen()
        case .aboutPrivacy: AboutPrivacyScreen()
        case .aboutOpenSource: AboutOpenSourceScreen()
        case .aboutNerdStats: AboutNerdStatsScreen()
        }
    }
}

/// Every page that opens as a sheet, each in its own NavigationStack. A sheet cannot push an
/// LDRoute: close it first with `navigator.dismissSheet { navigator.push(...) }`.
enum LDSheetRoute: Identifiable, Hashable {
    case addDestination
    /// `address` is the webhook URL to edit, nil for a new one.
    case webhookDestination(address: String?)
    case mqttDestination
    case backfill
    case payloadPreview
    case shortcutsHelp

    var id: Self { self }

    @MainActor @ViewBuilder
    var screen: some View {
        switch self {
        case .addDestination: AddDestinationScreen()
        case .webhookDestination(let address): WebhookDestinationScreen(address: address)
        case .mqttDestination: MqttDestinationScreen()
        case .backfill: BackfillScreen(stage: .choose)
        case .payloadPreview: PayloadPreviewScreen()
        case .shortcutsHelp: ShortcutsHelpScreen()
        }
    }
}

/// The navigation state, in the environment of every screen and sheet:
/// `@EnvironmentObject private var navigator: LDNavigator`.
@MainActor
final class LDNavigator: ObservableObject {
    static let healthTab = 0
    static let logsTab = 1

    @Published var healthPath: [LDRoute] = []
    @Published var logsPath: [LDRoute] = []
    @Published var sheet: LDSheetRoute?
    @Published private(set) var tabDirection = LDTabDirection.none

    @Published var selectedTab = LDNavigator.healthTab {
        didSet {
            guard selectedTab != oldValue else { return }
            tabDirection = selectedTab > oldValue ? .forward : .backward
            closeAbout(onTab: oldValue)
            settleDirection()
        }
    }

    /// Runs once the open sheet has gone: SwiftUI presents nothing else while it is closing.
    private var afterSheet: (() -> Void)?
    private var settling: Task<Void, Never>?

    /// Pushes a route on the tab in front.
    func push(_ route: LDRoute) {
        if selectedTab == Self.logsTab {
            logsPath.append(route)
        } else {
            healthPath.append(route)
        }
    }

    func present(_ route: LDSheetRoute) {
        sheet = route
    }

    /// Closes the sheet and runs `then` when it has gone, for what cannot start while a sheet is
    /// up, such as `pairing.startScan()` or a push.
    func dismissSheet(then: @escaping () -> Void = {}) {
        guard sheet != nil else {
            then()
            return
        }
        afterSheet = then
        sheet = nil
    }

    func sheetDismissed() {
        let then = afterSheet
        afterSheet = nil
        then?()
    }

    /// A pairing link lands on the Health screen itself, not on anything pushed or opened over it.
    func clearForPairing() {
        healthPath = []
        closeAbout(onTab: Self.logsTab)
        sheet = nil
    }

    /// Health, Logs, About, Health, Logs shows Logs, not About (P2-34): About closes on the tab
    /// you leave, also with its subpages. Other pushed pages stay where they were.
    private func closeAbout(onTab tab: Int) {
        if tab == Self.logsTab {
            Self.removeAbout(from: &logsPath)
        } else {
            Self.removeAbout(from: &healthPath)
        }
    }

    private static func removeAbout(from path: inout [LDRoute]) {
        if let first = path.firstIndex(where: \.isAbout) {
            path.removeSubrange(first...)
        }
    }

    /// Back to none once the slide is over, or the root screen would slide again on coming back
    /// from a pushed page.
    private func settleDirection() {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.tabDirection = .none
        }
    }

    #if DEBUG
    /// For screenshots of every page: -ld.tab 1 opens Logs, -ld.about YES opens About.
    func applyDebugArguments() {
        let arguments = UserDefaults.standard
        selectedTab = arguments.integer(forKey: "ld.tab")
        settling?.cancel()
        tabDirection = .none
        if arguments.bool(forKey: "ld.about") {
            push(.about)
        }
    }
    #endif
}
