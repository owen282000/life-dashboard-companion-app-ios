import HealthKit
import XCTest
@testable import LifeDashboardCompanion

/// The deletion step against a scripted source and a real store in a temporary directory.
final class DeletionReaderTests: XCTestCase {

    private enum Step {
        case page([String], anchor: UInt8?)
        case error(Error)
    }

    /// Answers each query with the next scripted step, and remembers the anchors it was asked for.
    private final class FakeSource: DeletedObjectSource, @unchecked Sendable {
        private let lock = NSLock()
        private var script: [String: [Step]]
        private(set) var askedAnchors: [String: [Data?]] = [:]

        init(_ script: [String: [Step]]) {
            self.script = script
        }

        var calls: Int { lock.withLock { askedAnchors.values.map(\.count).reduce(0, +) } }

        func deletedPage(sampleTypeIdentifier: String, anchor: Data?, limit: Int, timeout: Duration) async throws -> DeletedPage {
            let step: Step? = lock.withLock {
                askedAnchors[sampleTypeIdentifier, default: []].append(anchor)
                guard var steps = script[sampleTypeIdentifier], !steps.isEmpty else { return nil }
                let next = steps.removeFirst()
                script[sampleTypeIdentifier] = steps
                return next
            }
            switch step {
            case .page(let uuids, let anchor)?:
                return DeletedPage(uuids: uuids, anchor: anchor.map { Data([$0]) })
            case .error(let error)?:
                throw error
            case nil:
                // Past the script: nothing new, the anchor stays where it is.
                return DeletedPage(uuids: [], anchor: anchor)
            }
        }
    }

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    private let weight = DeletionTarget(dataType: .weight, sampleTypeIdentifier: HKQuantityType(.bodyMass).identifier)
    private let water = DeletionTarget(dataType: .hydration, sampleTypeIdentifier: HKQuantityType(.dietaryWater).identifier)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        suiteName = "deletion-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> DeletionStore {
        DeletionStore(directory: directory, defaults: defaults)
    }

    private func reader(_ source: FakeSource, store: DeletionStore, maxPages: Int = 20, now: Date = Date()) -> DeletionReader {
        var reader = DeletionReader(source: source, store: store)
        reader.maxPages = maxPages
        reader.now = { now }
        return reader
    }

    private func pendingUuids(_ store: DeletionStore) async -> [String] {
        await store.snapshot()?.pending.map(\.record.uuid).sorted() ?? []
    }

    /// Registers `target` with an empty history, so it tracks from anchor `anchor`.
    private func registered(_ target: DeletionTarget, anchor: UInt8, store: DeletionStore) async {
        let source = FakeSource([target.sampleTypeIdentifier: [.page([], anchor: anchor)]])
        _ = await reader(source, store: store).read(targets: [target], budget: .seconds(20))
    }

    // MARK: - Registration

    func testRegistrationPassesOldDeletionsWithoutReportingThem() async {
        let store = makeStore()
        let source = FakeSource([weight.sampleTypeIdentifier: [.page(["OLD1", "OLD2"], anchor: 3), .page([], anchor: 3)]])

        let outcome = await reader(source, store: store).read(targets: [weight], budget: .seconds(20))

        XCTAssertEqual(outcome, .done(unavailable: []), "A start is not a gap")
        let pending = await pendingUuids(store)
        XCTAssertTrue(pending.isEmpty)
        let state = await store.target(weight.key)
        XCTAssertEqual(state?.phase, .tracking)
        XCTAssertEqual(state?.anchor, Data([3]))
    }

    func testAnInterruptedRegistrationKeepsDiscardingNextTime() async {
        let store = makeStore()
        let first = FakeSource([weight.sampleTypeIdentifier: [.page(["OLD1"], anchor: 1), .page(["OLD2"], anchor: 2)]])
        _ = await reader(first, store: store, maxPages: 1).read(targets: [weight], budget: .seconds(20))
        let midway = await store.target(weight.key)
        XCTAssertEqual(midway?.phase, .registering)

        let second = FakeSource([weight.sampleTypeIdentifier: [.page(["OLD2"], anchor: 2), .page([], anchor: 2)]])
        let outcome = await reader(second, store: store).read(targets: [weight], budget: .seconds(20))

        XCTAssertEqual(outcome, .done(unavailable: []))
        XCTAssertEqual(second.askedAnchors[weight.sampleTypeIdentifier]?.first, Data([1]))
        let pending = await pendingUuids(store)
        XCTAssertTrue(pending.isEmpty)
    }

    func testRegistrationWithoutAnAnchorStaysRegistering() async {
        // Tracking from no anchor would report everything HealthKit remembers as new.
        let store = makeStore()
        let source = FakeSource([weight.sampleTypeIdentifier: [.page([], anchor: nil)]])
        _ = await reader(source, store: store).read(targets: [weight], budget: .seconds(20))
        let state = await store.target(weight.key)
        XCTAssertEqual(state?.phase, .registering)
    }

    // MARK: - Tracking

    func testTrackingReportsEveryPageUntilAnEmptyOne() async {
        let store = makeStore()
        await registered(weight, anchor: 0, store: store)
        let source = FakeSource([weight.sampleTypeIdentifier: [.page(["A", "B"], anchor: 5), .page(["C"], anchor: 6), .page([], anchor: 6)]])

        let outcome = await reader(source, store: store).read(targets: [weight], budget: .seconds(20))

        XCTAssertEqual(outcome, .done(unavailable: []))
        let pending = await pendingUuids(store)
        XCTAssertEqual(pending, ["A", "B", "C"])
        XCTAssertEqual(source.askedAnchors[weight.sampleTypeIdentifier], [Data([0]), Data([5]), Data([6])])
        let state = await store.snapshot()
        XCTAssertEqual(state?.pending.first?.record.type, "weight")
        XCTAssertEqual(state?.targets[weight.key]?.anchor, Data([6]))
    }

    func testEachPageIsStoredWithItsAnchorSoAStopLosesNothing() async {
        let store = makeStore()
        await registered(weight, anchor: 0, store: store)
        let failing = FakeSource([weight.sampleTypeIdentifier: [.page(["A"], anchor: 5), .error(DeletionReadError.failed("boom"))]])
        let outcome = await reader(failing, store: store).read(targets: [weight], budget: .seconds(20))
        XCTAssertEqual(outcome, .done(unavailable: ["weight"]))

        // A new store on the same file sees page one and its anchor together.
        let reopened = makeStore()
        let pending = await pendingUuids(reopened)
        XCTAssertEqual(pending, ["A"])
        let state = await reopened.target(weight.key)
        XCTAssertEqual(state?.anchor, Data([5]))
    }

    func testAnswerWithoutAnAnchorKeepsTheStoredOne() async {
        let store = makeStore()
        await registered(weight, anchor: 4, store: store)
        let source = FakeSource([weight.sampleTypeIdentifier: [.page([], anchor: nil)]])
        _ = await reader(source, store: store).read(targets: [weight], budget: .seconds(20))
        let state = await store.target(weight.key)
        XCTAssertEqual(state?.anchor, Data([4]))
    }

    func testDeletionsWithoutProgressStopTheTarget() async {
        let store = makeStore()
        await registered(weight, anchor: 4, store: store)
        let source = FakeSource([weight.sampleTypeIdentifier: [.page(["A"], anchor: 4)]])
        let outcome = await reader(source, store: store).read(targets: [weight], budget: .seconds(20))
        XCTAssertEqual(outcome, .done(unavailable: ["weight"]))
        XCTAssertEqual(source.calls, 1)
    }

    func testThePageCapNamesTheTargetAndTheNextSyncContinues() async {
        let store = makeStore()
        await registered(weight, anchor: 0, store: store)
        let source = FakeSource([weight.sampleTypeIdentifier: [.page(["A"], anchor: 1), .page(["B"], anchor: 2)]])
        let outcome = await reader(source, store: store, maxPages: 2).read(targets: [weight], budget: .seconds(20))
        XCTAssertEqual(outcome, .done(unavailable: ["weight"]))
        let state = await store.target(weight.key)
        XCTAssertEqual(state?.anchor, Data([2]))
    }

    // MARK: - Bounds and errors

    func testATimeoutKeepsTheAnchorNamesTheTypeAndLaterTypesStillRun() async {
        let store = makeStore()
        await registered(weight, anchor: 2, store: store)
        await registered(water, anchor: 3, store: store)
        let source = FakeSource([
            weight.sampleTypeIdentifier: [.error(BoundedCall.TimedOut())],
            water.sampleTypeIdentifier: [.page(["W"], anchor: 9), .page([], anchor: 9)]
        ])

        let outcome = await reader(source, store: store).read(targets: [water, weight], budget: .seconds(20))

        XCTAssertEqual(outcome, .done(unavailable: ["weight"]))
        let state = await store.target(weight.key)
        XCTAssertEqual(state?.anchor, Data([2]))
        XCTAssertEqual(state?.consecutiveErrors, 0, "Slow is not refused")
        let pending = await pendingUuids(store)
        XCTAssertEqual(pending, ["W"])
    }

    func testASpentBudgetAsksNothingAndNamesTrackingTypes() async {
        let store = makeStore()
        await registered(weight, anchor: 2, store: store)
        let source = FakeSource([:])
        let outcome = await reader(source, store: store).read(targets: [weight, water], budget: .zero)
        XCTAssertEqual(outcome, .done(unavailable: ["weight"]), "Water never started tracking, so it has no gap")
        XCTAssertEqual(source.calls, 0)
    }

    func testALockedPhoneNamesNothing() async {
        let store = makeStore()
        await registered(weight, anchor: 2, store: store)
        let source = FakeSource([weight.sampleTypeIdentifier: [.error(DeletionReadError.databaseInaccessible)]])
        let outcome = await reader(source, store: store).read(targets: [weight], budget: .seconds(20))
        XCTAssertEqual(outcome, .skipped)
        let unavailable = await store.snapshot()?.unavailable
        XCTAssertEqual(unavailable, [:])
    }

    func testARefusedAnchorStartsOverAfterThreeErrors() async {
        let store = makeStore()
        await registered(weight, anchor: 2, store: store)
        for round in 1...3 {
            let source = FakeSource([weight.sampleTypeIdentifier: [.error(DeletionReadError.failed("refused"))]])
            let outcome = await reader(source, store: store).read(targets: [weight], budget: .seconds(20))
            XCTAssertEqual(outcome, .done(unavailable: ["weight"]), "round \(round)")
        }
        let state = await store.target(weight.key)
        XCTAssertEqual(state?.phase, .registering)
        XCTAssertNil(state?.anchor)
    }

    // MARK: - Staleness and lost state

    func testATypeUnreadForAWeekIsNamedOnce() async {
        let store = makeStore()
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let first = FakeSource([weight.sampleTypeIdentifier: [.page([], anchor: 1)]])
        _ = await reader(first, store: store, now: start).read(targets: [weight], budget: .seconds(20))

        let later = start.addingTimeInterval(8 * 86_400)
        let outcome = await reader(FakeSource([:]), store: store, now: later).read(targets: [weight], budget: .seconds(20))
        XCTAssertEqual(outcome, .done(unavailable: ["weight"]))

        let again = await reader(FakeSource([:]), store: store, now: later).read(targets: [weight], budget: .seconds(20))
        XCTAssertEqual(again, .done(unavailable: []))
    }

    func testAFirstStartNamesNothingButLostStateNamesEveryType() async {
        let store = makeStore()
        await registered(weight, anchor: 1, store: store)
        XCTAssertTrue(defaults.bool(forKey: DeletionStore.startedKey))

        try? FileManager.default.removeItem(at: directory)
        let restored = makeStore()
        let outcome = await reader(FakeSource([:]), store: restored).read(targets: [weight, water], budget: .seconds(20))
        XCTAssertEqual(outcome, .done(unavailable: ["weight", "hydration"]))
    }

    func testADamagedFileIsSetAsideAndEveryTypeNamed() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("state.json"))
        let outcome = await reader(FakeSource([:]), store: makeStore()).read(targets: [weight], budget: .seconds(20))
        XCTAssertEqual(outcome, .done(unavailable: ["weight"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.corrupt.json").path))
    }

    func testTheStateDirectoryIsLeftOutOfBackups() async throws {
        let store = makeStore()
        await registered(weight, anchor: 1, store: store)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    // MARK: - Carrying

    func testDeliveryRemovesOnlyWhatThePayloadCarried() async throws {
        let store = makeStore()
        try await store.commitPage(target: weight.key, anchor: Data([1]), phase: .tracking, deletions: [DeletedRecord(type: "weight", uuid: "A")], completedAt: nil)
        try await store.markUnavailable(["heart_rate"])
        let generation = await store.generation
        let plan = await store.plan(readIds: [:], readGeneration: generation)

        // Another sync stores a deletion and names heart rate again before this one is delivered.
        try await store.commitPage(target: weight.key, anchor: Data([2]), phase: .tracking, deletions: [DeletedRecord(type: "weight", uuid: "B")], completedAt: nil)
        try await store.markUnavailable(["heart_rate"])

        await store.remove(plan.carried)
        let state = await store.snapshot()
        XCTAssertEqual(state?.pending.map(\.record.uuid), ["B"])
        XCTAssertNotNil(state?.unavailable["heart_rate"])
    }

    func testAStaleDeletionLeavesTheStoreWhenPlanned() async throws {
        let store = makeStore()
        try await store.commitPage(target: weight.key, anchor: Data([1]), phase: .tracking, deletions: [DeletedRecord(type: "weight", uuid: "A")], completedAt: nil)
        let generation = await store.generation
        let plan = await store.plan(readIds: ["weight": ["A"]], readGeneration: generation)
        XCTAssertTrue(plan.summary.isEmpty)
        let pending = await pendingUuids(store)
        XCTAssertTrue(pending.isEmpty)
    }
}
