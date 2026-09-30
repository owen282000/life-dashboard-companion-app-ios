import XCTest
@testable import LifeDashboardCompanion

final class OutboxTests: XCTestCase {

    // MARK: - Write-ahead

    /// One sync of records through `WriteAhead`, against a queue and an anchor held in memory.
    /// `dies` ends the process after that many steps: nothing past it happens, as when iOS
    /// ends the app.
    private final class Phone: @unchecked Sendable {
        let records: Set<Int>
        var queued: [String: Set<Int>] = [:]
        var anchorPast: Set<Int> = []
        var delivered: Set<Int> = []
        var queueWrites = true
        var steps: [String] = []
        var dies: Int?
        var attempts: [String: Int] = [:]

        init(records: Set<Int>) { self.records = records }

        private func step(_ name: String) -> Bool {
            if let dies, steps.count >= dies { return false }
            steps.append(name)
            return true
        }

        func writeAhead(post outcome: WebhookManager.Outcome) -> WriteAhead {
            WriteAhead(
                enqueue: {
                    guard self.step("enqueue"), self.queueWrites else { return nil }
                    self.queued["item"] = self.records
                    return "item"
                },
                commit: {
                    guard self.step("commit") else { return }
                    self.anchorPast = self.records
                },
                post: {
                    guard self.step("post") else { return WebhookManager.Delivery(outcome: .interrupted) }
                    if outcome.delivered { self.delivered.formUnion(self.records) }
                    return WebhookManager.Delivery(outcome: outcome)
                },
                delivered: { id in
                    guard self.step("dequeue") else { return }
                    self.queued[id] = nil
                },
                failed: { id in
                    guard self.step("attempt") else { return }
                    self.attempts[id, default: 0] += 1
                }
            )
        }

        /// Every record is delivered, still queued, or not yet past the anchor.
        var nothingLost: Bool {
            let queuedRecords = queued.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
            return records.allSatisfy { delivered.contains($0) || queuedRecords.contains($0) || !anchorPast.contains($0) }
        }
    }

    func testTheQueueIsWrittenBeforeTheAnchorMovesAndEmptiedAfterTheDelivery() async {
        let phone = Phone(records: [1, 2, 3])
        let outcome = await phone.writeAhead(post: .delivered).run()

        XCTAssertEqual(outcome.outcome, .delivered)
        XCTAssertEqual(phone.steps, ["enqueue", "commit", "post", "dequeue"])
        XCTAssertTrue(phone.queued.isEmpty)
        XCTAssertEqual(phone.anchorPast, [1, 2, 3])
    }

    func testAnAppEndedAtAnyStepLosesNoRecord() async {
        for outcome in [WebhookManager.Outcome.delivered, .failed, .interrupted] {
            for dies in 0...4 {
                let phone = Phone(records: [1, 2, 3])
                phone.dies = dies
                _ = await phone.writeAhead(post: outcome).run()
                XCTAssertTrue(phone.nothingLost, "\(outcome), ended after \(dies) steps: \(phone.steps)")
            }
        }
    }

    func testAFailedDeliveryStaysQueuedAndCountsAnAttempt() async {
        let phone = Phone(records: [1])
        let outcome = await phone.writeAhead(post: .failed).run()

        XCTAssertEqual(outcome.outcome, .failed)
        XCTAssertEqual(phone.queued["item"], [1])
        XCTAssertEqual(phone.attempts["item"], 1)
        XCTAssertEqual(phone.anchorPast, [1])
    }

    func testAnInterruptedDeliveryStaysQueuedWithoutAnAttempt() async {
        let phone = Phone(records: [1])
        let outcome = await phone.writeAhead(post: .interrupted).run()

        XCTAssertEqual(outcome.outcome, .interrupted)
        XCTAssertEqual(phone.queued["item"], [1])
        XCTAssertNil(phone.attempts["item"])
    }

    func testWithoutAQueueTheAnchorMovesOnlyPastWhatArrived() async {
        let failed = Phone(records: [1, 2])
        failed.queueWrites = false
        _ = await failed.writeAhead(post: .failed).run()
        XCTAssertTrue(failed.anchorPast.isEmpty, "read again by the next sync")
        XCTAssertTrue(failed.nothingLost)

        let delivered = Phone(records: [1, 2])
        delivered.queueWrites = false
        _ = await delivered.writeAhead(post: .delivered).run()
        XCTAssertEqual(delivered.steps, ["enqueue", "post", "commit"])
        XCTAssertEqual(delivered.anchorPast, [1, 2])
    }

    // MARK: - Failure notification

    func testAFailedPostSaysWhyAndTheNotificationShowsIt() async {
        let delivery = await WebhookManager.shared.post(
            body: Data("{}".utf8), urls: [""], headers: [:],
            logType: .healthConnect, dataType: "health_connect", recordCount: 1
        )
        XCTAssertEqual(delivery, WebhookManager.Delivery(outcome: .failed, error: AppDiagnostic.invalidURL.rawValue))
        for row in LogStore.shared.load() where row.url.isEmpty { LogStore.shared.delete(id: row.id) }

        let body = SyncFailureNotifier.failureBody(streak: 3, lastError: delivery.error.map(AppDiagnostic.display))
        XCTAssertTrue(body.hasSuffix("Last error: Invalid URL"), body)
        XCTAssertFalse(SyncFailureNotifier.failureBody(streak: 3, lastError: nil).contains("Last error"))
    }

    // MARK: - Queue files

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAQueuedPayloadIsEncryptedAtRestAndComesBackOut() throws {
        let directory = try temporaryDirectory()
        let store = PendingSyncStore(directory: directory)
        let item = try XCTUnwrap(store.enqueue(
            payload: Data("{}".utf8), urls: ["https://example.com/hook"], headers: [:],
            logType: LogType.healthConnect.rawValue, dataType: "health_connect", recordCount: 1
        ))
        let file = directory.appendingPathComponent("\(item.id).json")
        // The simulator keeps no protection class, so this checks only on a device.
        if let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        }
        XCTAssertEqual(store.dequeueAll().map(\.id), [item.id])
    }
}
