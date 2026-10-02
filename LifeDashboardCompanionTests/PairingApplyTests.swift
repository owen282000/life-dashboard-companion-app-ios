import XCTest
@testable import LifeDashboardCompanion

final class PairingApplyTests: XCTestCase {

    private let link = PairingLink(url: "http://192.168.1.10:8123/api/webhook/abc", secret: "new-secret", name: "Home Assistant")
    private let mine = "https://my.server/hook"

    private func section(_ urls: [String], secret: String = "", marks: Set<String> = []) -> SectionWebhook {
        SectionWebhook(urls: urls, secret: secret, urlsWithoutHeaders: marks)
    }

    // MARK: - Apply

    func testAFreshInstallGetsTheAddressTheSecretAndTheMark() {
        let next = PairingApply.applied(link, to: section([]))
        XCTAssertEqual(next.urls, [link.url])
        XCTAssertEqual(next.secret, "new-secret")
        XCTAssertEqual(next.urlsWithoutHeaders, [link.url])
    }

    func testAnExistingReceiverIsKeptAndTheSecretReplaced() {
        let next = PairingApply.applied(link, to: section([mine], secret: "old"))
        XCTAssertEqual(next.urls, [mine, link.url])
        XCTAssertEqual(next.secret, "new-secret")
        XCTAssertEqual(next.urlsWithoutHeaders, [link.url])
    }

    func testTheSameAddressIsNotAddedTwiceAndKeepsItsHeaders() {
        let next = PairingApply.applied(link, to: section([link.url], secret: "old"))
        XCTAssertEqual(next.urls, [link.url])
        XCTAssertTrue(next.urlsWithoutHeaders.isEmpty)
    }

    // MARK: - Preview

    func testPreviewOfAFreshInstall() {
        let change = PairingApply.preview(link, current: section([]))
        XCTAssertTrue(change.addsUrl)
        XCTAssertFalse(change.replacesSecret)
        XCTAssertEqual(change.otherUrls, 0)
    }

    func testPreviewNextToAnotherReceiverWithAnotherSecret() {
        let change = PairingApply.preview(link, current: section([mine], secret: "old"))
        XCTAssertTrue(change.addsUrl)
        XCTAssertTrue(change.replacesSecret)
        XCTAssertEqual(change.otherUrls, 1)
    }

    func testPreviewWhenAlreadyPaired() {
        XCTAssertTrue(PairingApply.preview(link, current: section([link.url], secret: "new-secret")).changesNothing)
    }

    func testPreviewOfTheSameSecretOnANewAddress() {
        let change = PairingApply.preview(link, current: section([mine], secret: "new-secret"))
        XCTAssertTrue(change.addsUrl)
        XCTAssertFalse(change.replacesSecret)
    }

    func testThePreviewNamesTheOtherAddressesOnlyWhenTheSecretIsReplaced() {
        let replaced = PairingApply.preview(link, current: section([mine, link.url], secret: "old"))
        XCTAssertEqual(replaced.othersSignedWithNewSecret, [mine])
        XCTAssertEqual(WebhookHosts.list(replaced.othersSignedWithNewSecret), "my.server")

        // Same secret, or none before: nothing the other addresses get changes.
        XCTAssertEqual(PairingApply.preview(link, current: section([mine], secret: "new-secret")).othersSignedWithNewSecret, [])
        XCTAssertEqual(PairingApply.preview(link, current: section([mine])).othersSignedWithNewSecret, [])
        // Only the paired address: no other to name.
        XCTAssertEqual(PairingApply.preview(link, current: section([link.url], secret: "old")).othersSignedWithNewSecret, [])
    }

    // MARK: - Hosts

    func testAHostNeverCarriesThePathOrTheQuery() {
        XCTAssertEqual(WebhookHosts.host(of: "https://ha.example.com:8123/api/webhook/abc123?token=secret#frag"), "ha.example.com")
        XCTAssertEqual(WebhookHosts.host(of: "https://user:pass@n8n.example.org/webhook/xyz"), "n8n.example.org")
        XCTAssertEqual(WebhookHosts.host(of: "http://[fd00::1]:8123/api/webhook/abc"), "[fd00::1]")
        // Not a URL Foundation reads: cut by hand, still without path, query, user or port.
        for odd in ["http://my host:8123/api/webhook/abc?token=secret", "my host/api/webhook/abc?token=secret"] {
            let host = WebhookHosts.host(of: odd)
            XCTAssertEqual(host, "my host", odd)
            XCTAssertFalse(host.contains("/") || host.contains("?") || host.contains("abc") || host.contains("secret"), odd)
        }
    }

    func testSeveralHostsAreJoinedOnceEach() {
        XCTAssertEqual(WebhookHosts.list([
            "https://a.example/hook/1?k=v", "https://b.example/hook", "https://a.example/hook/2"
        ]), "a.example, b.example")
        XCTAssertEqual(WebhookHosts.list([]), "")
    }

    func testABlankSecretCountsAsNone() {
        XCTAssertFalse(PairingApply.preview(link, current: section([mine], secret: "  ")).replacesSecret)
    }

    // MARK: - Headers

    func testAPairedAddressGetsNoCustomHeaders() {
        let next = PairingApply.applied(link, to: section([mine]))
        let custom = ["Authorization": "Bearer key"]
        XCTAssertEqual(PairingApply.headers(for: mine, custom: custom, configuredUrls: next.urls, urlsWithoutHeaders: next.urlsWithoutHeaders), custom)
        XCTAssertEqual(PairingApply.headers(for: link.url, custom: custom, configuredUrls: next.urls, urlsWithoutHeaders: next.urlsWithoutHeaders), [:])
    }

    func testAnAddressNoLongerListedGetsNoCustomHeaders() {
        // A queued payload can still name an address the user removed since.
        XCTAssertEqual(PairingApply.headers(for: "https://removed/hook", custom: ["K": "V"], configuredUrls: [mine], urlsWithoutHeaders: []), [:])
    }

    func testTypingAPairedAddressLiftsItsMarkWithoutADuplicate() {
        let next = section([mine, link.url], marks: [link.url]).withTypedUrl(link.url)
        XCTAssertEqual(next.urls, [mine, link.url])
        XCTAssertTrue(next.urlsWithoutHeaders.isEmpty)
    }

    func testTypingANewAddressAppendsItUnmarked() {
        let next = section([mine]).withTypedUrl("https://other/hook")
        XCTAssertEqual(next.urls, [mine, "https://other/hook"])
        XCTAssertTrue(next.urlsWithoutHeaders.isEmpty)
    }

    // MARK: - The ping after pairing

    private let requestSignature = "sha256=" + String(repeating: "1", count: 64)

    /// Framed like the integration's frame_answer: compact JSON, answer signed with the derived key.
    private func answer(inReplyTo: String) -> Data {
        let json = "{\"life_dashboard\":{\"version\":\"0.7.0\",\"writeback\":1},"
            + "\"writeback\":{\"in_reply_to\":\"\(inReplyTo)\",\"issued_at\":\"2026-09-30T10:00:00Z\",\"configured\":[]}}"
        return Data(json.utf8)
    }

    private func outcome(status: Int?, body: Data, header: String?, error: String? = nil) -> PairingPingOutcome {
        PairingPingOutcome.from(
            statusCode: status,
            body: body,
            answerSignature: header,
            requestSignature: requestSignature,
            secret: "key",
            error: error
        )
    }

    func testTheIntegrationsSignedAnswerConfirms() {
        let body = answer(inReplyTo: requestSignature)
        let header = WebhookSigner.responseSignature(for: body, secret: "key")
        XCTAssertEqual(outcome(status: 200, body: body, header: header), .confirmed)
    }

    func testAnAnswerWithoutItsHeaderStillConfirms() {
        // Home Assistant Cloud relays only Content-Type back to the phone.
        XCTAssertEqual(outcome(status: 200, body: answer(inReplyTo: requestSignature), header: nil), .confirmed)
    }

    func testAWrongAnswerSignatureDoesNotConfirm() {
        let wrong = "sha256=" + String(repeating: "0", count: 64)
        XCTAssertEqual(outcome(status: 200, body: answer(inReplyTo: requestSignature), header: wrong), .deliveredUnconfirmed)
    }

    func testAnAnswerToAnotherRequestDoesNotConfirm() {
        XCTAssertEqual(outcome(status: 200, body: answer(inReplyTo: "sha256=other"), header: nil), .deliveredUnconfirmed)
    }

    func testAnEmptyOkIsWhatAnUnknownWebhookLooksLike() {
        XCTAssertEqual(outcome(status: 200, body: Data(), header: nil), .deliveredUnconfirmed)
        XCTAssertEqual(outcome(status: 200, body: Data("{\"ok\":true}".utf8), header: nil), .deliveredUnconfirmed)
    }

    func testRefusalsAndFailures() {
        XCTAssertEqual(outcome(status: 401, body: Data(), header: nil), .refused)
        XCTAssertEqual(outcome(status: 500, body: Data(), header: nil), .failed("HTTP 500"))
        XCTAssertEqual(outcome(status: nil, body: Data(), header: nil, error: "offline"), .failed("offline"))
    }
}
