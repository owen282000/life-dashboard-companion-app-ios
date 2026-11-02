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
