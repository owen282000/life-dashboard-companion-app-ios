import os
import XCTest
@testable import LifeDashboardCompanion

final class WebhookRedirectTests: XCTestCase {

    // MARK: - The rule

    private func follows(_ from: String, _ to: String) -> Bool {
        WebhookRedirect.followable(from: URL(string: from)!, to: URL(string: to)!) != nil
    }

    func testOnlyTheSameHostAndPortIsFollowed() {
        let hook = "https://ha.example.com/api/webhook/abc"
        XCTAssertTrue(follows(hook, "https://ha.example.com/api/webhook/def"))
        XCTAssertTrue(follows(hook, "https://HA.Example.com:443/other"), "case and the default port do not matter")
        XCTAssertFalse(follows(hook, "https://auth.example.com/login"), "another host is the login page")
        XCTAssertFalse(follows(hook, "https://ha.example.com:8443/api"))
        XCTAssertFalse(follows(hook, "http://ha.example.com/api"), "never down from https to http")
        XCTAssertFalse(follows(hook, "ftp://ha.example.com/api"))

        XCTAssertTrue(follows("http://ha.local/hook", "https://ha.local/hook"), "http on 80 up to https on 443")
        XCTAssertTrue(follows("http://ha.local:8123/hook", "https://ha.local:8123/hook"))
        XCTAssertFalse(follows("http://ha.local:8123/hook", "https://ha.local/hook"))
        XCTAssertFalse(follows("http://192.168.1.10/hook", "http://192.168.1.11/hook"))

        // Unicode case folding would make these the same host; they are not.
        XCTAssertFalse(follows("https://strasse.example/hook", "https://stra%C3%9Fe.example/hook"))
        XCTAssertFalse(follows("https://k.example/hook", "https://%E2%84%AA.example/hook"))
    }

    func testTheDelegateResendsTheOriginalPostAndStopsAfterFive() async {
        let hook = URL(string: "https://ha.example.com/hook")!
        var original = URLRequest(url: hook)
        original.httpMethod = "POST"
        original.httpBody = Self.body
        original.setValue("sha256=abc", forHTTPHeaderField: "X-Signature")
        let delegate = WebhookTaskDelegate(request: original)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original)

        func redirect(_ from: String, to target: String) async -> URLRequest? {
            let response = HTTPURLResponse(url: URL(string: from)!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            var proposed = URLRequest(url: URL(string: target)!)
            proposed.httpMethod = "GET"
            return await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: proposed)
        }

        let crossHost = await redirect(hook.absoluteString, to: "https://auth.example.com/login")
        XCTAssertNil(crossHost)
        let downgrade = await redirect(hook.absoluteString, to: "http://ha.example.com/hook")
        XCTAssertNil(downgrade)
        XCTAssertFalse(delegate.stoppedAtLimit, "declined for where it points, not for how many")

        for step in 1...WebhookRedirect.maxRedirects {
            let next = await redirect("https://ha.example.com/\(step - 1)", to: "https://ha.example.com/\(step)")
            XCTAssertEqual(next?.url?.absoluteString, "https://ha.example.com/\(step)")
            XCTAssertEqual(next?.httpMethod, "POST")
            XCTAssertEqual(next?.httpBody, Self.body)
            XCTAssertEqual(next?.value(forHTTPHeaderField: "X-Signature"), "sha256=abc")
        }
        let sixth = await redirect("https://ha.example.com/5", to: "https://ha.example.com/6")
        XCTAssertNil(sixth)
        XCTAssertTrue(delegate.stoppedAtLimit)
    }

    func testTheLoggedHostStaysEncoded() {
        let response = HTTPURLResponse(
            url: URL(string: "https://ha.example.com/hook")!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://a%0Ab.example/login"]
        )!
        XCTAssertEqual(
            WebhookRedirect.failureMessage(response, overLimit: false),
            AppDiagnostic.redirectNotFollowed(302, host: "a%0Ab.example")
        )
        let noLocation = HTTPURLResponse(url: URL(string: "https://ha.example.com/hook")!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [:])!
        XCTAssertEqual(WebhookRedirect.failureMessage(noLocation, overLimit: false), AppDiagnostic.redirectNotFollowed(302, host: nil))
    }

    func testARedirectLineNamesItsTargetAndIsTranslatedWhenShown() {
        let crossHost = AppDiagnostic.redirectNotFollowed(302, host: "auth.example.com")
        XCTAssertEqual(
            crossHost,
            "HTTP 302: redirect to auth.example.com not followed, so nothing was sent there. Only a redirect on the same host is followed; enter the final address as the webhook URL."
        )
        // The tests run in English, so a recognised line reads the same as it was stored.
        XCTAssertEqual(AppDiagnostic.display(crossHost), crossHost)
        let noTarget = AppDiagnostic.redirectNotFollowed(301, host: nil)
        XCTAssertEqual(AppDiagnostic.display(noTarget), noTarget)
        let tooMany = AppDiagnostic.tooManyRedirects(307, host: "ha.example.com")
        XCTAssertEqual(AppDiagnostic.display(tooMany), tooMany)
        XCTAssertEqual(AppDiagnostic.display("HTTP 302"), "HTTP 302")
    }

    // MARK: - Through URLSession

    func testASameHostRedirectKeepsThePostAndItsBody() async {
        for status in [301, 302, 303, 307, 308] {
            let host = Self.host()
            RedirectStub.route("https://\(host)/old", status: status, location: "/new")
            RedirectStub.route("https://\(host)/new", status: 200)

            let delivery = await post(to: "https://\(host)/old")

            XCTAssertEqual(delivery.outcome, .delivered, "HTTP \(status)")
            let arrived = RedirectStub.requests(to: host).last
            XCTAssertEqual(arrived?.url, "https://\(host)/new", "HTTP \(status)")
            XCTAssertEqual(arrived?.method, "POST", "HTTP \(status)")
            XCTAssertEqual(arrived?.body, Self.body, "HTTP \(status)")
            XCTAssertEqual(arrived?.headers["Content-Type"], "application/json", "HTTP \(status)")
        }
    }

    func testARedirectToAnotherHostFailsAndTheLoginPageIsNeverAsked() async {
        let host = Self.host()
        let login = Self.host()
        RedirectStub.route("https://\(host)/hook", status: 302, location: "https://\(login)/login?rd=hook")
        RedirectStub.route("https://\(login)/login?rd=hook", status: 200)

        let delivery = await post(to: "https://\(host)/hook")

        XCTAssertEqual(delivery.outcome, .failed, "not delivered, and not a refusal: the queue keeps it")
        XCTAssertEqual(delivery.statusCode, 302)
        XCTAssertEqual(delivery.error, AppDiagnostic.redirectNotFollowed(302, host: login))
        XCTAssertTrue(RedirectStub.requests(to: login).isEmpty, "nothing went to the login page")
        XCTAssertEqual(RedirectStub.requests(to: host).count, 1, "a redirect is not retried")
    }

    func testMoreThanFiveRedirectsFail() async {
        let host = Self.host()
        for step in 0...WebhookRedirect.maxRedirects {
            RedirectStub.route("https://\(host)/\(step)", status: 307, location: "/\(step + 1)")
        }
        RedirectStub.route("https://\(host)/\(WebhookRedirect.maxRedirects + 1)", status: 200)

        let delivery = await post(to: "https://\(host)/0")

        XCTAssertEqual(delivery.outcome, .failed)
        XCTAssertEqual(delivery.error, AppDiagnostic.tooManyRedirects(307, host: host))
        XCTAssertEqual(RedirectStub.requests(to: host).count, WebhookRedirect.maxRedirects + 1)

        // Exactly five still arrive.
        let five = Self.host()
        for step in 0..<WebhookRedirect.maxRedirects {
            RedirectStub.route("https://\(five)/\(step)", status: 308, location: "/\(step + 1)")
        }
        RedirectStub.route("https://\(five)/\(WebhookRedirect.maxRedirects)", status: 204)
        let fiveDelivery = await post(to: "https://\(five)/0")
        XCTAssertEqual(fiveDelivery.outcome, .delivered)
    }

    func testThePairingCheckFollowsTheSameRuleAndKeepsItsSignature() async {
        let host = Self.host()
        RedirectStub.route("https://\(host)/api/webhook/a", status: 308, location: "/api/webhook/b")
        RedirectStub.route("https://\(host)/api/webhook/b", status: 200)
        let outcome = await probe("https://\(host)/api/webhook/a")
        XCTAssertEqual(outcome, .deliveredUnconfirmed)
        let arrived = RedirectStub.requests(to: host).last
        XCTAssertEqual(arrived?.url, "https://\(host)/api/webhook/b")
        XCTAssertEqual(arrived?.headers["X-Signature"], WebhookSigner.signatureHeader(for: Self.body, secret: "secret"))
        XCTAssertEqual(arrived?.body, Self.body)

        let proxied = Self.host()
        let login = Self.host()
        RedirectStub.route("https://\(proxied)/api/webhook/a", status: 302, location: "https://\(login)/")
        RedirectStub.route("https://\(login)/", status: 200)
        let refused = await probe("https://\(proxied)/api/webhook/a")
        XCTAssertEqual(refused, .failed(AppDiagnostic.redirectNotFollowed(302, host: login)))
        XCTAssertTrue(RedirectStub.requests(to: login).isEmpty)
    }

    // MARK: - Helpers

    private static let body = Data(#"{"records":1}"#.utf8)

    private static func host() -> String { "h\(UUID().uuidString.prefix(8).lowercased()).redirect-stub" }

    private let webhooks: WebhookManager = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStub.self]
        return WebhookManager(configuration: configuration)
    }()

    private func post(to url: String) async -> WebhookManager.Delivery {
        let delivery = await webhooks.post(
            body: Self.body, urls: [url], headers: [:],
            logType: .healthConnect, dataType: "health_connect", recordCount: 1
        )
        for row in LogStore.shared.load() where row.url == url { LogStore.shared.delete(id: row.id) }
        return delivery
    }

    private func probe(_ url: String) async -> PairingPingOutcome {
        let outcome = await webhooks.probe(body: Self.body, url: url, secret: "secret")
        for row in LogStore.shared.load() where row.url == url { LogStore.shared.delete(id: row.id) }
        return outcome
    }
}

/// Answers each request with the status and Location routed to its URL, 404 when there is
/// none, and records what arrived, body included.
final class RedirectStub: URLProtocol {
    struct Arrival: Sendable {
        let url: String
        let method: String?
        let headers: [String: String]
        let body: Data?
    }

    private struct State {
        var routes: [String: (status: Int, location: String?)] = [:]
        var arrivals: [Arrival] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func route(_ url: String, status: Int, location: String? = nil) {
        state.withLock { $0.routes[url] = (status, location) }
    }

    static func requests(to host: String) -> [Arrival] {
        state.withLock { $0.arrivals.filter { URL(string: $0.url)?.host == host } }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".redirect-stub") == true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let arrival = Arrival(
            url: url.absoluteString,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.read)
        )
        let route = Self.state.withLock { state in
            state.arrivals.append(arrival)
            return state.routes[url.absoluteString]
        }
        var fields: [String: String] = [:]
        if let location = route?.location { fields["Location"] = location }
        let response = HTTPURLResponse(url: url, statusCode: route?.status ?? 404, httpVersion: "HTTP/1.1", headerFields: fields)!
        if let location = route?.location, let target = URL(string: location, relativeTo: url)?.absoluteURL {
            var next = request
            next.url = target
            // What URLSession itself would do to the method, so the test shows the delegate undoing it.
            if [301, 302, 303].contains(response.statusCode) {
                next.httpMethod = "GET"
                next.httpBody = nil
            }
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // Over the network a redirect the delegate declines ends the task with the 3xx
            // itself; a protocol has to hand that response over, or the task waits for its timeout.
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
