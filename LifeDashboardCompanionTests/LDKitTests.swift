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
        case .whatToSend, .typeCategory, .dataResolution, .backfillRun, .whenToSend, .more, .advanced,
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
            (.aboutNerdStats, "AboutNerdStatsScreen"),
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
            (.shortcutsHelp, "ShortcutsHelpScreen"),
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
            .whatToSend, .dataResolution, .backfillRun, .whenToSend, .more, .advanced, .notifications,
            .exportData, .backupRestore, .about, .aboutHelp, .aboutSupport, .aboutPrivacy,
            .aboutOpenSource, .aboutNerdStats,
        ] + LDTypeCategory.allCases.map(LDRoute.typeCategory) {
            XCTAssertTrue(plain.values.contains(.push(route)), "\(route)")
        }
        for sheet: LDSheetRoute in [
            .addDestination, .webhookDestination(address: nil), .mqttDestination, .backfill, .payloadPreview, .shortcutsHelp,
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

    func testAllTypesLeavesCycleTrackingOff() {
        let all = LDTypeCategory.typesOutsideCycle
        XCTAssertTrue(all.isDisjoint(with: LDTypeCategory.cycleTracking.types))
        XCTAssertEqual(all.count + LDTypeCategory.cycleTracking.types.count, HealthDataType.allCases.count)
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
