import XCTest
@testable import LifeDashboardCompanion

final class PairingApplyTests: XCTestCase {

    private let link = PairingLink(url: "http://192.168.1.10:8123/api/webhook/abc", secret: "new-secret", name: "Home Assistant")
    private let mine = "https://my.server/hook"

    private func destination(_ url: String, secret: String = "", headers: [String: String] = [:]) -> WebhookDestination {
        WebhookDestination(id: WebhookDestinations.stableId(url), url: url, secret: secret, headers: headers)
    }

    // MARK: - Apply

    func testAFreshInstallGetsTheAddressWithItsSecretAndNoHeaders() {
        let next = PairingApply.applied(link, to: [])
        XCTAssertEqual(next.map(\.url), [link.url])
        XCTAssertEqual(next.first?.secret, "new-secret")
        XCTAssertEqual(next.first?.headers, [:])
    }

    func testAnotherReceiverKeepsItsOwnSecretAndHeaders() {
        let other = destination(mine, secret: "old", headers: ["Authorization": "Bearer key"])
        let next = PairingApply.applied(link, to: [other])
        XCTAssertEqual(next.map(\.url), [mine, link.url])
        XCTAssertEqual(next[0], other)
        XCTAssertEqual(next[1].secret, "new-secret")
        XCTAssertEqual(next[1].headers, [:])
    }

    func testPairingTheSameAddressAgainReplacesOnlyItsSecret() {
        let paired = destination(link.url, secret: "old", headers: ["X-Typed": "kept"])
        let next = PairingApply.applied(link, to: [paired])
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].id, paired.id)
        XCTAssertEqual(next[0].secret, "new-secret")
        XCTAssertEqual(next[0].headers, ["X-Typed": "kept"])
    }

    // MARK: - Preview

    func testPreviewOfAFreshInstall() {
        let change = PairingApply.preview(link, current: [])
        XCTAssertTrue(change.addsUrl)
        XCTAssertFalse(change.replacesSecret)
        XCTAssertEqual(change.otherUrls, 0)
    }

    func testPreviewNextToAnotherReceiverReplacesNothing() {
        // Since every address has its own secret, the other one's secret is never replaced.
        let change = PairingApply.preview(link, current: [destination(mine, secret: "old")])
        XCTAssertTrue(change.addsUrl)
        XCTAssertFalse(change.replacesSecret)
        XCTAssertEqual(change.otherUrls, 1)
    }

    func testPreviewWhenAlreadyPaired() {
        XCTAssertTrue(PairingApply.preview(link, current: [destination(link.url, secret: "new-secret")]).changesNothing)
    }

    func testPreviewOfANewSecretForTheSameAddress() {
        let change = PairingApply.preview(link, current: [destination(mine), destination(link.url, secret: "old")])
        XCTAssertFalse(change.addsUrl)
        XCTAssertTrue(change.replacesSecret)
        XCTAssertEqual(change.otherUrls, 1)
    }

    func testABlankSecretCountsAsNone() {
        XCTAssertFalse(PairingApply.preview(link, current: [destination(link.url, secret: "  ")]).replacesSecret)
    }

    // MARK: - Destinations

    func testTheSettingsOfBeforeBecomeDestinationsWithoutAnyChange() {
        let list = WebhookDestinations.derived(
            urls: [mine, link.url], secret: "shared", headers: ["Authorization": "Bearer key"], urlsWithoutHeaders: [link.url]
        )
        XCTAssertEqual(list.map(\.secret), ["shared", "shared"])
        XCTAssertEqual(list.map(\.headers), [["Authorization": "Bearer key"], [:]])
        // The same ids on every read, until the list is stored.
        XCTAssertEqual(list.map(\.id), WebhookDestinations.derived(urls: [mine, link.url], secret: "", headers: [:], urlsWithoutHeaders: []).map(\.id))
    }

    func testANewAddressGetsTheDefaultSecretAndARemovedOneGoes() {
        let kept = destination(mine, secret: "mine", headers: ["K": "V"])
        let next = WebhookDestinations.synced([kept, destination(link.url, secret: "gone")], urls: [mine, "https://new/hook"], newSecret: "default")
        XCTAssertEqual(next[0], kept)
        XCTAssertEqual(next[1].url, "https://new/hook")
        XCTAssertEqual(next[1].secret, "default")
        XCTAssertEqual(next[1].headers, [:])
    }

    func testTheSectionKeysAreOnlyWhatEveryAddressShares() {
        let same = WebhookDestinations.sectionKeys([destination(mine, secret: "s", headers: ["K": "V"]), destination(link.url, secret: "s")])
        XCTAssertEqual(same.secret, "s")
        XCTAssertEqual(same.headers, ["K": "V"])
        XCTAssertEqual(same.urlsWithoutHeaders, [link.url])

        // Different secrets or headers: none, and every address listed, so an older reader sends
        // no receiver's credentials to another.
        let different = WebhookDestinations.sectionKeys([destination(mine, secret: "a", headers: ["K": "1"]), destination(link.url, secret: "b", headers: ["K": "2"])])
        XCTAssertEqual(different.secret, "")
        XCTAssertEqual(different.headers, [:])
        XCTAssertEqual(different.urlsWithoutHeaders, [mine, link.url])

        XCTAssertEqual(WebhookDestinations.sectionKeys([destination(mine)]).urlsWithoutHeaders, [])
    }

    func testAGeneratedSecretIs64HexCharacters() {
        let secret = WebhookDestinations.generatedSecret()
        XCTAssertEqual(secret.count, 64)
        XCTAssertTrue(secret.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(secret, WebhookDestinations.generatedSecret())
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

    // MARK: - What the sheet calls done

    func testAPlainOkIsDoneAtAnyReceiverButHomeAssistant() {
        let stack = PairingLink(url: "https://stack.example.com/webhook/iphone", secret: "s", name: "Life Dashboard Stack")
        let ownWebhook = PairingLink(url: "https://n8n.example.com/webhook/abc", secret: "s", name: nil)
        let cloud = PairingLink(url: "https://hooks.nabu.casa/gAAAAAB", secret: "s", name: "Home Assistant")

        XCTAssertTrue(PairingPingOutcome.deliveredUnconfirmed.isDone(at: stack))
        XCTAssertTrue(PairingPingOutcome.deliveredUnconfirmed.isDone(at: ownWebhook))
        // At Home Assistant it can be a deleted entry, so the sheet offers Try again.
        XCTAssertFalse(PairingPingOutcome.deliveredUnconfirmed.isDone(at: link))
        XCTAssertFalse(PairingPingOutcome.deliveredUnconfirmed.isDone(at: cloud))

        for receiver in [stack, ownWebhook, link, cloud] {
            XCTAssertTrue(PairingPingOutcome.confirmed.isDone(at: receiver), receiver.url)
            XCTAssertFalse(PairingPingOutcome.refused.isDone(at: receiver), receiver.url)
            XCTAssertFalse(PairingPingOutcome.failed("HTTP 500").isDone(at: receiver), receiver.url)
        }
    }
}
