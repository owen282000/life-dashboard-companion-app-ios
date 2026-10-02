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
                failed: { id, _ in
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
        XCTAssertEqual(delivery, WebhookManager.Delivery(outcome: .failed, error: AppDiagnostic.invalidURL.rawValue, urlCount: 1))
        for row in LogStore.shared.load() where row.url.isEmpty { LogStore.shared.delete(id: row.id) }

        let body = SyncFailureNotifier.failureBody(streak: 3, lastError: delivery.error.map(AppDiagnostic.display))
        XCTAssertTrue(body.hasSuffix("Last error: Invalid URL"), body)
        XCTAssertFalse(SyncFailureNotifier.failureBody(streak: 3, lastError: nil).contains("Last error"))
    }

    // MARK: - Partial delivery notification

    func testThePartialStreakCountsMissesEndsOnAFullDeliveryAndIgnoresFailures() {
        let missed = ["https://down.example/hook"]
        typealias Streak = SyncFailureNotifier.PartialStreak
        XCTAssertEqual(Streak.next(0, delivered: true, missedUrls: missed), 1)
        XCTAssertEqual(Streak.next(2, delivered: true, missedUrls: missed), 3)
        XCTAssertEqual(Streak.next(4, delivered: true, missedUrls: []), 0)
        // A total failure is the failure streak's: the partial one stays where it was.
        XCTAssertEqual(Streak.next(2, delivered: false, missedUrls: []), 2)
        XCTAssertEqual(Streak.next(0, delivered: false, missedUrls: []), 0)
    }

    func testThePartialNotificationComesAtTheThresholdAndItsMultiples() {
        typealias Streak = SyncFailureNotifier.PartialStreak
        let notified = (1...9).filter { Streak.notifies($0, threshold: 3, enabled: true) }
        XCTAssertEqual(notified, [3, 6, 9])
        XCTAssertFalse(Streak.notifies(3, threshold: 3, enabled: false), "only with failure notifications on")
        XCTAssertFalse(Streak.notifies(0, threshold: 3, enabled: true))
        XCTAssertTrue(Streak.notifies(1, threshold: 0, enabled: true), "a threshold below 1 counts as 1")
    }

    func testThePartialNotificationNamesHostsOnly() {
        let hosts = WebhookHosts.list(["https://down.example/api/webhook/secret-id?token=t", "http://10.0.0.2:1880/hook"])
        let body = SyncFailureNotifier.partialBody(count: 3, hosts: hosts)
        XCTAssertFalse(body.contains("secret-id") || body.contains("token") || body.contains("/hook"), body)
        XCTAssertTrue(body.contains("down.example, 10.0.0.2"), body)
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
            payload: Data("{}".utf8), urls: ["https://example.com/hook"],
            logType: LogType.healthConnect.rawValue, dataType: "health_connect", recordCount: 1
        ))
        let file = directory.appendingPathComponent("\(item.id).json")
        // The simulator keeps no protection class, so this checks only on a device.
        if let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        }
        XCTAssertEqual(store.dequeueAll().map(\.id), [item.id])
    }

    func testAPayloadIsKeptHoweverManyAttemptsItHad() throws {
        let store = PendingSyncStore(directory: try temporaryDirectory())
        let item = try XCTUnwrap(store.enqueue(
            payload: Data("{}".utf8), urls: ["https://example.com/hook"],
            logType: LogType.healthConnect.rawValue, dataType: "health_connect", recordCount: 4
        ))
        for _ in 0..<25 { store.updateAttempt(id: item.id, error: "HTTP 502", statusCode: 502) }
        XCTAssertEqual(store.dequeueAll().map(\.attemptCount), [25])
        XCTAssertFalse(item.expired(at: item.createdAt.addingTimeInterval(7 * 86_400)))
        XCTAssertTrue(item.expired(at: item.createdAt.addingTimeInterval(7 * 86_400 + 1)))
    }

    func testAPayloadThatIsBeingSentIsNotCountedAsWaiting() throws {
        let store = PendingSyncStore(directory: try temporaryDirectory())
        let item = try XCTUnwrap(store.enqueue(
            payload: Data("{}".utf8), urls: ["https://example.com/hook"],
            logType: LogType.healthConnect.rawValue, dataType: "health_connect", recordCount: 1
        ))
        store.beginSending(id: item.id)
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(store.dequeueAll().count, 1, "a drain still sees it")
        store.endSending(id: item.id)
        XCTAssertEqual(store.pendingCount, 1)
    }

    func testAQueueFileFromAnEarlierVersionIsReadAndLosesItsHeadersWhenWrittenAgain() throws {
        let directory = try temporaryDirectory()
        let store = PendingSyncStore(directory: directory)
        _ = store.pendingCount
        let old = """
        {"id":"OLD","createdAt":\(Date().timeIntervalSinceReferenceDate),"payload":"e30=","urls":["https://example.com/hook"],
        "headers":{"Authorization":"Bearer old-key"},"logType":"HEALTH_CONNECT","dataType":"health_connect",
        "recordCount":2,"attemptCount":20}
        """
        let file = directory.appendingPathComponent("OLD.json")
        try Data(old.utf8).write(to: file)

        XCTAssertEqual(store.dequeueAll().map(\.id), ["OLD"], "20 attempts no longer drop it")
        store.updateAttempt(id: "OLD", error: "HTTP 401", statusCode: 401)
        let written = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(written.contains("old-key"))
        // Still there, empty, for 1.4.1 after a downgrade, which requires the field.
        let object = try JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any]
        XCTAssertEqual((object?["headers"] as? [String: String])?.isEmpty, true)
    }

    func testADamagedQueueFileIsRemoved() throws {
        let directory = try temporaryDirectory()
        let store = PendingSyncStore(directory: directory)
        _ = store.pendingCount
        try Data("not json".utf8).write(to: directory.appendingPathComponent("BAD.json"))
        XCTAssertTrue(store.dequeueAll().isEmpty)
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testADroppedPayloadSaysWhyInTheLog() throws {
        let store = PendingSyncStore(directory: try temporaryDirectory())
        let item = try XCTUnwrap(store.enqueue(
            payload: Data("{\"steps\":[]}".utf8), urls: ["https://a.example/hook", "https://b.example/hook"],
            logType: LogType.healthConnect.rawValue, dataType: "health_connect", recordCount: 9
        ))
        let undelivered = PendingSyncStore.droppedLog(for: item, reason: .undelivered)
        XCTAssertEqual(undelivered.errorMessage, "Not delivered for a week, dropped from the queue")
        XCTAssertEqual(undelivered.url, "https://a.example/hook, https://b.example/hook")
        XCTAssertEqual(undelivered.recordCount, 9)
        XCTAssertEqual(undelivered.rawPayload, "{\"steps\":[]}")
        XCTAssertNil(undelivered.statusCode)
        XCTAssertFalse(undelivered.success)

        let refused = PendingSyncStore.droppedLog(for: item, reason: .refused(413))
        XCTAssertEqual(refused.errorMessage, "Refused for a week (HTTP 413), dropped from the queue")
        XCTAssertEqual(refused.statusCode, 413)
        XCTAssertEqual(AppDiagnostic.display(refused.errorMessage ?? ""), "Refused for a week (HTTP 413), dropped from the queue")
        XCTAssertEqual(AppDiagnostic.display(undelivered.errorMessage ?? ""), "Not delivered for a week, dropped from the queue")
        XCTAssertTrue(SyncFailureNotifier.droppedBody(count: 2).hasPrefix("2 undelivered syncs"))
    }

    // MARK: - Draining

    private final class Receiver: @unchecked Sendable {
        var now = Date()
        var answers: [String: WebhookManager.Outcome] = [:]
        var headers = ["Authorization": "Bearer old-key"]
        var configured = ["https://new.example/hook"]
        var posted: [QueuedPost] = []
        var removed: [String] = []
        var attempts: [String] = []
        var dropped: [(String, QueueDrop)] = []

        var drain: QueueDrain {
            QueueDrain(
                now: now,
                urls: { self.configured },
                headers: { self.headers },
                post: { item, urls, headers in
                    self.posted.append(QueuedPost(id: item.id, urls: urls, headers: headers))
                    // The key is rotated while the queue drains.
                    self.headers = ["Authorization": "Bearer new-key"]
                    let outcome = self.answers[item.id] ?? .delivered
                    return WebhookManager.Delivery(outcome: outcome, statusCode: outcome == .refused ? 400 : nil)
                },
                remove: { self.removed.append($0.id) },
                attempt: { item, _ in self.attempts.append(item.id) },
                delivered: { _, _ in },
                dropped: { self.dropped.append(($0.id, $1)) }
            )
        }
    }

    private func item(_ id: String, age days: Double = 0) -> PendingSyncItem {
        PendingSyncItem(
            id: id, createdAt: Date().addingTimeInterval(-days * 86_400), payload: Data("{}".utf8),
            urls: ["https://old.example/hook"],
            logType: LogType.healthConnect.rawValue, dataType: "health_connect", recordCount: 1, attemptCount: 0
        )
    }

    func testEveryRetryGoesWhereAndWithWhatIsConfiguredNow() async {
        let receiver = Receiver()
        await receiver.drain.run([item("a"), item("b")])
        XCTAssertEqual(receiver.posted.map(\.headers["Authorization"]), ["Bearer old-key", "Bearer new-key"])
        XCTAssertEqual(receiver.posted.map(\.urls), [["https://new.example/hook"], ["https://new.example/hook"]])
        XCTAssertEqual(receiver.removed, ["a", "b"])
    }

    func testWithoutAWebhookEveryItemWaits() async {
        let receiver = Receiver()
        receiver.configured = []
        await receiver.drain.run([item("a", age: 8)])
        XCTAssertTrue(receiver.posted.isEmpty)
        XCTAssertTrue(receiver.removed.isEmpty)
    }

    func testARefusedPayloadIsSkippedAndTheRestGoesThrough() async {
        let receiver = Receiver()
        receiver.answers = ["a": .refused]
        await receiver.drain.run([item("a"), item("b")])
        XCTAssertEqual(receiver.posted.map(\.id), ["a", "b"])
        XCTAssertEqual(receiver.attempts, ["a"])
        XCTAssertEqual(receiver.removed, ["b"], "the refused one stays queued")
    }

    func testAFailureStopsTheDrainAndAnInterruptionCountsNoAttempt() async {
        let failing = Receiver()
        failing.answers = ["a": .failed]
        await failing.drain.run([item("a"), item("b")])
        XCTAssertEqual(failing.posted.map(\.id), ["a"])
        XCTAssertEqual(failing.attempts, ["a"])

        let cut = Receiver()
        cut.answers = ["a": .interrupted, "b": .interrupted]
        await cut.drain.run([item("a", age: 8), item("b")])
        XCTAssertEqual(cut.posted.map(\.id), ["a"])
        XCTAssertTrue(cut.attempts.isEmpty)
        XCTAssertTrue(cut.removed.isEmpty, "a cut-off attempt drops nothing, however old")
    }

    func testAPayloadOlderThanAWeekStillGetsOneTryAndGoesWhenItFails() async {
        let late = Receiver()
        await late.drain.run([item("old", age: 8)])
        XCTAssertEqual(late.removed, ["old"])
        XCTAssertTrue(late.dropped.isEmpty, "delivered after all")

        let down = Receiver()
        down.answers = ["old": .failed, "older": .failed]
        await down.drain.run([item("older", age: 9), item("old", age: 8)])
        XCTAssertEqual(down.dropped.map(\.0), ["older"], "one per pass")
        XCTAssertEqual(down.dropped.first?.1, .undelivered)
        XCTAssertTrue(down.attempts.isEmpty)

        let refusing = Receiver()
        refusing.answers = ["old": .refused]
        await refusing.drain.run([item("old", age: 8), item("new")])
        XCTAssertEqual(refusing.dropped.map(\.0), ["old"])
        XCTAssertEqual(refusing.dropped.first?.1, .refused(400))
        XCTAssertEqual(refusing.removed, ["old", "new"])
    }

    // MARK: - Refusals

    /// Answers every request with the status code in its host name, "status-400.test".
    final class StatusStub: URLProtocol {
        override static func canInit(with request: URLRequest) -> Bool {
            request.url?.host?.hasSuffix(".test") == true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let host = request.url?.host ?? ""
            let code = Int(host.dropFirst("status-".count).prefix(3)) ?? 500
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func post(_ codes: [Int]) async -> WebhookManager.Delivery {
        URLProtocol.registerClass(StatusStub.self)
        defer { URLProtocol.unregisterClass(StatusStub.self) }
        let urls = codes.map { "https://status-\($0)-\(UUID().uuidString.prefix(8)).test/hook" }
        let delivery = await WebhookManager.shared.post(
            body: Data("{}".utf8), urls: urls, headers: [:],
            logType: .healthConnect, dataType: "health_connect", recordCount: 1
        )
        for row in LogStore.shared.load() where urls.contains(row.url) { LogStore.shared.delete(id: row.id) }
        return delivery
    }

    func testAPayloadIsRefusedOnlyWhenEveryFailedAddressRefusedIt() async {
        let refused = await post([400, 422])
        XCTAssertEqual(refused.outcome, .refused)
        XCTAssertEqual(refused.statusCode, 422)
        XCTAssertEqual(refused.error, "HTTP 422")

        // One address refusing and one failing otherwise is a plain failure: wait for that one.
        let mixed = await post([413, 404])
        XCTAssertEqual(mixed.outcome, .failed)
        let unauthorized = await post([401])
        XCTAssertEqual(unauthorized.outcome, .failed)
        let oneTookIt = await post([400, 204])
        XCTAssertEqual(oneTookIt.outcome, .delivered)
    }

    func testAPostThatOneOfTwoAddressesMissedNamesThatOne() async {
        let partly = await post([404, 204])
        XCTAssertEqual(partly.outcome, .delivered, "what counts as delivered does not change")
        XCTAssertEqual(partly.urlCount, 2)
        XCTAssertEqual(partly.missedUrls.count, 1)
        XCTAssertTrue(partly.missedUrls[0].hasPrefix("https://status-404-"), partly.missedUrls[0])
        XCTAssertTrue(partly.reach.partial)
        XCTAssertEqual(partly.reach.delivered, 1)

        let everywhere = await post([204, 200])
        XCTAssertEqual(everywhere.missedUrls, [])
        XCTAssertEqual(everywhere.urlCount, 2)
        XCTAssertFalse(everywhere.reach.partial)

        // Nobody took it: a failure, which the queue keeps, not a miss.
        let nowhere = await post([404, 404])
        XCTAssertEqual(nowhere.outcome, .failed)
        XCTAssertEqual(nowhere.missedUrls, [])
    }
}

/// One post the drain made, as the test receiver saw it.
private struct QueuedPost {
    let id: String
    let urls: [String]
    let headers: [String: String]
}
