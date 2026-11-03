import UIKit
import XCTest
@testable import LifeDashboardCompanion

final class LDKitTests: XCTestCase {
    /// A wrong name falls back to the system font without a word, in every screen at once.
    func testEveryFontNameResolvesToItsOwnFont() {
        for name in LDFontName.all {
            XCTAssertEqual(UIFont(name: name, size: 14)?.fontName, name)
        }
    }

    func testEveryHealthTypeHasOneCategory() {
        let types = LDTypeCategory.allCases.flatMap(\.types)
        XCTAssertEqual(Set(types), Set(HealthDataType.allCases))
        XCTAssertEqual(types.count, HealthDataType.allCases.count)
    }

    /// Health, Logs, About, Health, Logs: Logs shows Logs, not About (P2-34).
    @MainActor
    func testAboutClosesOnTheTabYouLeaveAndOtherPagesStay() {
        let navigator = LDNavigator()
        navigator.healthPath = [.more, .about, .aboutHelp]
        navigator.logsPath = [.logDetail(id: "1")]

        navigator.selectedTab = LDNavigator.logsTab
        XCTAssertEqual(navigator.healthPath, [.more])
        XCTAssertEqual(navigator.logsPath, [.logDetail(id: "1")])
        XCTAssertEqual(navigator.tabDirection, .forward)
    }

    // MARK: - Every route is a real screen

    /// The screen at the end of a route's view builder: each branch of its switch is a nested
    /// `_ConditionalContent`, whose value holds the branch taken in an enum.
    private func screenName(_ view: Any) -> String {
        var current = view
        while true {
            let name = String(describing: type(of: current))
            guard name.hasPrefix("_ConditionalContent") || name == "Storage",
                  let branch = Mirror(reflecting: current).children.first?.value else { return name }
            current = branch
        }
    }

    /// Adding a case to LDRoute stops the build here, until the case is in the table below too.
    private func listed(_ route: LDRoute) {
        switch route {
        case .whatToSend, .typeCategory, .notAvailableYet, .dataResolution, .backfillRun, .whenToSend, .more, .advanced,
             .notifications, .exportData, .backupRestore, .logDetail, .about, .aboutHelp, .aboutSupport,
             .aboutPrivacy, .aboutOpenSource, .aboutNerdStats:
            break
        }
    }

    private func listed(_ route: LDSheetRoute) {
        switch route {
        case .addDestination, .webhookDestination, .mqttDestination, .backfill, .payloadPreview, .shortcutsHelp:
            break
        }
    }

    @MainActor
    func testEveryRouteOpensItsOwnScreen() {
        let routes: [(LDRoute, String)] = LDTypeCategory.allCases.map { (.typeCategory($0), "TypeCategoryScreen") } + [
            (.whatToSend, "WhatToSendScreen"),
            (.notAvailableYet, "NotAvailableYetScreen"),
            (.dataResolution, "DataResolutionScreen"),
            (.backfillRun, "BackfillScreen"),
            (.whenToSend, "WhenToSendScreen"),
            (.more, "MoreScreen"),
            (.advanced, "AdvancedScreen"),
            (.notifications, "NotificationSettingsScreen"),
            (.exportData, "ExportDataScreen"),
            (.backupRestore, "BackupRestoreScreen"),
            (.logDetail(id: "1"), "LogDetailScreen"),
            (.about, "AboutHomeScreen"),
            (.aboutHelp, "AboutHelpScreen"),
            (.aboutSupport, "AboutSupportScreen"),
            (.aboutPrivacy, "AboutPrivacyScreen"),
            (.aboutOpenSource, "AboutOpenSourceScreen"),
            (.aboutNerdStats, "AboutNerdStatsScreen")
        ]
        for (route, screen) in routes {
            listed(route)
            XCTAssertEqual(screenName(route.destination), screen, "\(route)")
        }

        let sheets: [(LDSheetRoute, String)] = [
            (.addDestination, "AddDestinationScreen"),
            (.webhookDestination(address: nil), "WebhookDestinationScreen"),
            (.webhookDestination(address: "https://example.com/hook"), "WebhookDestinationScreen"),
            (.mqttDestination, "MqttDestinationScreen"),
            (.backfill, "BackfillScreen"),
            (.payloadPreview, "PayloadPreviewScreen"),
            (.shortcutsHelp, "ShortcutsHelpScreen")
        ]
        for (sheet, screen) in sheets {
            listed(sheet)
            XCTAssertEqual(screenName(sheet.screen), screen, "\(sheet)")
        }
    }

    /// Screenshots of every page go through -ld.route, so a page it cannot open goes unseen.
    @MainActor
    func testTheDebugRouteNamesReachEveryRoute() {
        let plain = LDDebugRoute.plain
        for route: LDRoute in [
            .whatToSend, .notAvailableYet, .dataResolution, .backfillRun, .whenToSend, .more, .advanced, .notifications,
            .exportData, .backupRestore, .about, .aboutHelp, .aboutSupport, .aboutPrivacy,
            .aboutOpenSource, .aboutNerdStats
        ] + LDTypeCategory.allCases.map(LDRoute.typeCategory) {
            XCTAssertTrue(plain.values.contains(.push(route)), "\(route)")
        }
        for sheet: LDSheetRoute in [
            .addDestination, .webhookDestination(address: nil), .mqttDestination, .backfill, .payloadPreview, .shortcutsHelp
        ] {
            XCTAssertTrue(plain.values.contains(.sheet(sheet)), "\(sheet)")
        }
        XCTAssertNil(LDDebugRoute.named("nothing", logs: [], webhookUrls: []))
        XCTAssertEqual(
            LDDebugRoute.named("webhookDestination", logs: [], webhookUrls: ["https://example.com/hook"]),
            .sheet(.webhookDestination(address: "https://example.com/hook"))
        )
    }

    /// A screen that is only its heading, the shape every page had before it was built, or a word
    /// that says one still is. Reads the sources, which a simulator test can reach on this Mac.
    func testNoScreenIsStillAStub() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LifeDashboardCompanion/Screens")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("The sources are not on this machine")
        }
        let headingOnly = try NSRegularExpression(pattern: #"LDScreen(\([^)]*\))?\s*\{\s*LDHeading\("[^"]*"\)\s*\}"#)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var checked = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            XCTAssertNil(headingOnly.firstMatch(in: source, range: range), "\(file.lastPathComponent) is only a heading")
            for word in ["stub", "placeholder screen", "coming soon", "not built"] {
                XCTAssertNil(source.range(of: word, options: .caseInsensitive), "\(file.lastPathComponent) says \(word)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 25)
    }

    // MARK: - Decisions that must stay

    /// App Review guideline 2.3.10: the iOS app names no other platform or store.
    func testNoScreenMentionsAnotherPlatform() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LifeDashboardCompanion")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw XCTSkip("The sources are not on this machine")
        }
        let literal = try NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*(?i:android|google play|play\.google)(?:[^"\\\n]|\\.)*""#)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let range = NSRange(line.startIndex..., in: line)
                XCTAssertNil(literal.firstMatch(in: line, range: range), "\(file.lastPathComponent): \(line)")
            }
        }
    }

    @MainActor
    func testOnlyTheTwoPresetsCountAsAPreset() {
        XCTAssertTrue(WhatToSendSelection.isPreset(OnboardingView.essentials))
        XCTAssertTrue(WhatToSendSelection.isPreset(Set(HealthDataType.allCases)))
        XCTAssertFalse(WhatToSendSelection.isPreset([]))
        XCTAssertFalse(WhatToSendSelection.isPreset(OnboardingView.essentials.union([.hydration])))
    }

    func testNotAvailableYetNamesAreUniqueAndNeverATypeTheAppSends() {
        let names = (LDTypeCategory.allCases.flatMap(\.notAvailableYet) + LDNotAvailableGroup.allCases.flatMap(\.names))
            .map { String(localized: $0) }
        XCTAssertEqual(names.count, Set(names).count)
        let built = Set(HealthDataType.allCases.map { String(localized: $0.displayName) })
        XCTAssertTrue(built.isDisjoint(with: names))
    }

    /// A category without a single type reads as a promise, which App Review can refuse. Those
    /// names go on the Not available yet page, under a group.
    func testEveryCategoryHasTypesAndEveryGroupHasNames() {
        for category in LDTypeCategory.allCases {
            XCTAssertFalse(category.types.isEmpty, "\(category) would be a category without a type")
        }
        for group in LDNotAvailableGroup.allCases {
            XCTAssertFalse(group.names.isEmpty, "\(group) would be an empty section")
        }
        XCTAssertEqual(LDNotAvailableGroup.nameCount, LDNotAvailableGroup.allCases.map(\.names.count).reduce(0, +))
    }

    /// A dot only goes between two parts on one line, so a part that does not fit starts the next
    /// line without one, also when a single part is as wide as the line.
    func testSeparatedTextBreaksBetweenPartsWithoutADot() {
        XCTAssertEqual(LDSeparatedLayout.lines(parts: [80, 60, 40], dot: 20, width: 300), [[0, 1, 2]])
        XCTAssertEqual(LDSeparatedLayout.lines(parts: [80, 60, 40], dot: 20, width: 219), [[0, 1], [2]])
        XCTAssertEqual(LDSeparatedLayout.lines(parts: [80, 60, 40], dot: 20, width: 159), [[0], [1, 2]])
        XCTAssertEqual(LDSeparatedLayout.lines(parts: [80, 60, 40], dot: 20, width: 100), [[0], [1], [2]])
        XCTAssertEqual(LDSeparatedLayout.lines(parts: [100, 40], dot: 20, width: 100), [[0], [1]])
        XCTAssertEqual(LDSeparatedLayout.lines(parts: [50], dot: 0, width: 100), [[0]])
        XCTAssertEqual("a · b".ldKeepingSeparators, "a\u{00A0}· b")
    }

    /// Equal while it fits, by label when it does not, on more lines at the largest text sizes.
    func testFooterButtonsKeepTheirLabelOnOneLine() {
        func widths(_ ideal: [CGFloat], in width: CGFloat) -> [[CGFloat]] {
            LDFooterLayout.lines(ideal: ideal, width: width, spacing: 8).map { $0.map(\.width) }
        }
        XCTAssertEqual(widths([100, 80, 70], in: 340), [[108, 108, 108]])
        XCTAssertEqual(widths([136, 111, 82], in: 345), [[136, 111, 82]])
        XCTAssertEqual(widths([136, 111, 82], in: 351), [[138, 113, 84]])
        XCTAssertEqual(widths([200, 120, 100], in: 340), [[206, 126], [340]])
        XCTAssertEqual(widths([400, 400], in: 340), [[340], [340]])
        XCTAssertEqual(widths([50], in: 340), [[340]])
    }

    /// VoiceOver hears how a delivery went before anything else, also on a row that only shows a code.
    func testALogRowSaysHowItWentFirst() {
        let failed = WebhookLog(
            url: "https://example.com/hook",
            statusCode: 502,
            success: false,
            errorMessage: "HTTP 502",
            recordCount: 3,
            logType: .healthConnect
        )
        XCTAssertTrue(failed.ldSpokenRow.hasPrefix(String(localized: "Failed") + ", 502, example.com, "), failed.ldSpokenRow)
        XCTAssertFalse(failed.ldSpokenRow.contains("·"))

        let delivered = WebhookLog(url: "https://example.com/hook", statusCode: 200, success: true, recordCount: 3, logType: .healthConnect)
        XCTAssertTrue(delivered.ldSpokenRow.hasPrefix(String(localized: "Delivered") + ", 200, example.com, "), delivered.ldSpokenRow)
    }

    @MainActor
    func testAPairingLinkClearsWhatIsOpenOverHealth() {
        let navigator = LDNavigator()
        navigator.healthPath = [.whatToSend]
        navigator.logsPath = [.about]
        navigator.sheet = .addDestination

        navigator.clearForPairing()
        XCTAssertEqual(navigator.healthPath, [])
        XCTAssertEqual(navigator.logsPath, [])
        XCTAssertNil(navigator.sheet)
    }
}
