import XCTest
@testable import LifeDashboardCompanion

final class BackgroundChancesTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_789_380_000)

    private func chance(_ trigger: SyncTrigger, _ outcome: BackgroundChance.Outcome, minute: Double) -> BackgroundChance {
        let moment = start.addingTimeInterval(minute * 60)
        return BackgroundChance(trigger: trigger.rawValue, outcome: outcome, first: moment, last: moment)
    }

    func testWakeupsWhileLockedBecomeOneEntryWithACount() {
        var entries: [BackgroundChance] = []
        for minute in 0..<12 {
            entries = BackgroundChanceLog.adding(chance(.observer, .locked, minute: Double(minute) * 10), to: entries)
        }

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].count, 12)
        XCTAssertEqual(entries[0].first, start)
        XCTAssertEqual(entries[0].last, start.addingTimeInterval(110 * 60))
    }

    func testAnotherTriggerOrOutcomeStartsANewEntry() {
        var entries: [BackgroundChance] = []
        entries = BackgroundChanceLog.adding(chance(.observer, .notDue, minute: 0), to: entries)
        entries = BackgroundChanceLog.adding(chance(.appRefresh, .notDue, minute: 1), to: entries)
        entries = BackgroundChanceLog.adding(chance(.appRefresh, .locked, minute: 2), to: entries)
        entries = BackgroundChanceLog.adding(chance(.observer, .notDue, minute: 3), to: entries)

        XCTAssertEqual(entries.map(\.outcome), [.notDue, .locked, .notDue, .notDue])
        XCTAssertEqual(entries.map(\.trigger), ["observer", "appRefresh", "appRefresh", "observer"])
    }

    func testEveryRunAndEveryCutOffKeepsAnEntryOfItsOwn() {
        var entries: [BackgroundChance] = []
        for outcome in [BackgroundChance.Outcome.synced, .synced, .failed, .failed, .cancelled, .cancelled] {
            entries = BackgroundChanceLog.adding(chance(.processing, outcome, minute: 0), to: entries)
        }
        XCTAssertEqual(entries.count, 6)
    }

    func testTheListKeepsTheNewestFifty() {
        var entries: [BackgroundChance] = []
        for minute in 0..<70 {
            entries = BackgroundChanceLog.adding(chance(.appRefresh, .synced, minute: Double(minute)), to: entries)
        }
        XCTAssertEqual(entries.count, BackgroundChanceLog.maxEntries)
        XCTAssertEqual(entries.first?.last, start.addingTimeInterval(69 * 60))
        XCTAssertEqual(entries.last?.last, start.addingTimeInterval(20 * 60))
    }

    func testEveryOutcomeOfTheCoordinatorHasAName() {
        XCTAssertEqual(BackgroundChance.Outcome(.ran(success: true)), .synced)
        XCTAssertEqual(BackgroundChance.Outcome(.ran(success: false)), .failed)
        XCTAssertEqual(BackgroundChance.Outcome(.notDue), .notDue)
        XCTAssertEqual(BackgroundChance.Outcome(.notConfigured), .notConfigured)
        XCTAssertEqual(BackgroundChance.Outcome(.locked), .locked)
        XCTAssertEqual(BackgroundChance.Outcome(.cancelled), .cancelled)
    }

    func testTheStoreKeepsWhatItRecordsAndClearsIt() throws {
        let suite = "BackgroundChancesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BackgroundChanceStore(defaults: defaults)

        store.record(.unlock, .synced, at: start, seconds: 3.5)
        store.record(.observer, .locked, at: start.addingTimeInterval(60))
        store.record(.observer, .locked, at: start.addingTimeInterval(120))

        let entries = BackgroundChanceStore(defaults: defaults).load()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].outcome, .locked)
        XCTAssertEqual(entries[0].count, 2)
        XCTAssertEqual(entries[1].syncTrigger, .unlock)
        XCTAssertEqual(entries[1].seconds, 3.5)

        store.clear()
        XCTAssertTrue(store.load().isEmpty)
    }

    func testAnEntryFromANewerBuildStillDecodes() throws {
        let json = #"[{"id":"7C1F9A5E-0000-4000-8000-000000000001","trigger":"somethingNew","outcome":"synced","first":0,"last":0,"count":1}]"#
        let entries = try JSONDecoder().decode([BackgroundChance].self, from: Data(json.utf8))
        XCTAssertNil(entries[0].syncTrigger)
        XCTAssertEqual(entries[0].trigger, "somethingNew")
    }
}
