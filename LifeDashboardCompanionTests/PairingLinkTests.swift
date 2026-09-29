import XCTest
@testable import LifeDashboardCompanion

final class PairingLinkTests: XCTestCase {

    private let webhookUrl = "http://192.168.10.138:8123/api/webhook/" + String(repeating: "a", count: 64)
    private let secret = String(repeating: "b", count: 64)

    /// The exact string the Home Assistant integration's pairing_url() produces, copied from its
    /// tests/test_pairing.py. Change one side and this fails, which is the point.
    private var knownGood: String {
        "https://owen282000.github.io/life-dashboard-companion-app/pair"
            + "#v=1"
            + "&url=http%3A%2F%2F192.168.10.138%3A8123%2Fapi%2Fwebhook%2F" + String(repeating: "a", count: 64)
            + "&secret=" + String(repeating: "b", count: 64)
            + "&name=Home%20Assistant"
    }

    private func ok(_ text: String?, file: StaticString = #filePath, line: UInt = #line) -> PairingLink? {
        guard case .link(let link) = PairingLinks.parse(text) else {
            XCTFail("expected a usable link, got \(PairingLinks.parse(text))", file: file, line: line)
            return nil
        }
        return link
    }

    private func problem(_ text: String) -> PairingProblem? {
        guard case .invalid(let problem) = PairingLinks.parse(text) else { return nil }
        return problem
    }

    private let minimal = "lifedashboard://pair#v=1&url=https%3A%2F%2Fa.b%2Fc&secret=xyz"

    // MARK: - The shared vectors

    func testReadsTheIntegrationsOwnLink() {
        let link = ok(knownGood)
        XCTAssertEqual(link?.url, webhookUrl)
        XCTAssertEqual(link?.secret, secret)
        XCTAssertEqual(link?.name, "Home Assistant")
        XCTAssertEqual(link?.host, "192.168.10.138:8123")
        XCTAssertEqual(link?.isPlainHttp, true)
    }

    func testReadsAndroidsVectorWithSources() {
        let link = ok(knownGood + "&sources=health_connect%2Cscreen_time")
        XCTAssertEqual(link?.url, webhookUrl)
    }

    func testTheOpenedUrlKeepsItsEscapes() {
        // What .onOpenURL hands over: absoluteString must not decode the fragment.
        let url = URL(string: knownGood.replacingOccurrences(
            of: "https://owen282000.github.io/life-dashboard-companion-app/pair",
            with: "lifedashboard://pair"
        ))
        XCTAssertEqual(ok(url?.absoluteString)?.url, webhookUrl)
    }

    // MARK: - Shapes that are ours

    func testReadsTheCustomSchemeForm() {
        let link = ok("lifedashboard://pair#v=1&url=https%3A%2F%2Fha.example.com%2Fhook&secret=xyz")
        XCTAssertEqual(link?.url, "https://ha.example.com/hook")
        XCTAssertEqual(link?.host, "ha.example.com")
        XCTAssertEqual(link?.isPlainHttp, false)
    }

    func testSchemeVariantsAreOurs() {
        for prefix in [
            "LIFEDASHBOARD://PAIR",
            "lifedashboard:pair",
            "lifedashboard:///pair",
            "lifedashboard://pair/",
            "https://owen282000.github.io/life-dashboard-companion-app/pair/",
            "HTTPS://OWEN282000.GITHUB.IO/life-dashboard-companion-app/PAIR"
        ] {
            XCTAssertNotNil(ok(prefix + "#v=1&url=https%3A%2F%2Fa.b%2Fc&secret=xyz"), prefix)
        }
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertNotNil(ok("  \n" + knownGood + " "))
    }

    // MARK: - Decoding

    func testAnEncodedAmpersandInsideTheUrlStaysPartOfIt() {
        let link = ok("lifedashboard://pair#v=1&url=https%3A%2F%2Fa.b%2Fhook%3Fx%3D1%26y%3D2&secret=xyz")
        XCTAssertEqual(link?.url, "https://a.b/hook?x=1&y=2")
    }

    func testASecretWithAwkwardCharactersSurvives() {
        let link = ok("lifedashboard://pair#v=1&url=https%3A%2F%2Fhooks.nabu.casa%2FgAAAAAB%2Babc&secret=x%2By%2Fz%3D")
        XCTAssertEqual(link?.url, "https://hooks.nabu.casa/gAAAAAB+abc")
        XCTAssertEqual(link?.secret, "x+y/z=")
    }

    func testALiteralPlusIsNotTurnedIntoASpace() {
        XCTAssertEqual(ok("lifedashboard://pair#v=1&url=https%3A%2F%2Fa.b%2Fc&secret=x+y")?.secret, "x+y")
    }

    func testALiteralSpaceInTheNameIsAccepted() {
        let link = ok("https://owen282000.github.io/life-dashboard-companion-app/pair#v=1"
            + "&url=https%3A%2F%2Fa.b%2Fc&secret=xyz&name=Home Assistant")
        XCTAssertEqual(link?.name, "Home Assistant")
    }

    func testARepeatedKeyKeepsTheLastValueWithoutCrashing() {
        XCTAssertEqual(ok("lifedashboard://pair#v=1&v=1&url=https%3A%2F%2Fa.b%2Fc&secret=a&secret=b")?.secret, "b")
    }

    func testAMalformedEscapeKeepsTheRawText() {
        XCTAssertEqual(ok(minimal + "&name=100%zz")?.name, "100%zz")
    }

    func testAnEncodedKeyIsDecoded() {
        XCTAssertNotNil(ok("lifedashboard://pair#%76=1&url=https%3A%2F%2Fa.b%2Fc&secret=xyz"))
    }

    func testATrailingNewlineOnTheSecretIsTrimmed() {
        XCTAssertEqual(ok("lifedashboard://pair#v=1&url=https%3A%2F%2Fa.b%2Fc&secret=xyz%0A")?.secret, "xyz")
    }

    // MARK: - Names

    func testNoNameMeansNil() {
        XCTAssertNil(ok(minimal)?.name)
        XCTAssertNil(ok(minimal + "&name=")?.name)
        XCTAssertNil(ok(minimal + "&name=%20%20")?.name)
    }

    func testALongNameIsTruncatedAndControlCharactersDropped() {
        let link = ok(minimal + "&name=" + String(repeating: "A", count: 80) + "%0A")
        XCTAssertEqual(link?.name?.count, 64)
    }

    func testBidiAndZeroWidthCharactersAreDroppedFromTheName() {
        // U+202E right-to-left override and U+200B zero-width space.
        XCTAssertEqual(ok(minimal + "&name=Home%E2%80%AE%E2%80%8BAssistant")?.name, "HomeAssistant")
    }

    // MARK: - Sources

    func testSourcesThatIncludeHealthAreFine() {
        XCTAssertNotNil(ok(minimal + "&sources=health_connect"))
        XCTAssertNotNil(ok(minimal + "&sources=health_connect%2Cmoon_phase"))
        XCTAssertNotNil(ok(minimal + "&sources=%20"))
    }

    func testAReceiverForScreenTimeOnlyIsOfNoUseOnAnIphone() {
        XCTAssertEqual(problem(minimal + "&sources=screen_time"), .noUsableSource)
        XCTAssertEqual(problem(minimal + "&sources=screen_time%2Cmoon_phase"), .noUsableSource)
        XCTAssertEqual(problem(minimal + "&sources=moon_phase"), .noUsableSource)
        XCTAssertEqual(problem(minimal + "&sources=%2C"), .noUsableSource)
    }

    // MARK: - Refusals

    func testAnotherVersionIsRefusedRatherThanGuessedAt() {
        XCTAssertEqual(problem("lifedashboard://pair#v=2&url=https%3A%2F%2Fa.b%2Fc&secret=xyz"), .unsupportedVersion)
        XCTAssertEqual(problem("lifedashboard://pair#url=https%3A%2F%2Fa.b%2Fc&secret=xyz"), .unsupportedVersion)
        XCTAssertEqual(problem("lifedashboard://pair#"), .unsupportedVersion)
    }

    func testAMissingHalfIsRefused() {
        XCTAssertEqual(problem("lifedashboard://pair#v=1&secret=xyz"), .incomplete)
        XCTAssertEqual(problem("lifedashboard://pair#v=1&url=https%3A%2F%2Fa.b%2Fc"), .incomplete)
        XCTAssertEqual(problem("lifedashboard://pair#v=1&url=https%3A%2F%2Fa.b%2Fc&secret="), .incomplete)
        XCTAssertEqual(problem("lifedashboard://pair"), .incomplete)
    }

    func testAnAddressTheAppCannotPostToIsRefused() {
        for url in [
            "ftp%3A%2F%2Fa.b%2Fc",
            "https%3A%2F%2Fa.b%2Fc%2Cd",
            "https%3A%2F%2Fa.b%2F%20c",
            "https%3A%2F%2Fa.b%2Fc%00",
            "https%3A%2F%2Fhomeassistant.local%40evil.example%2Fhook",
            "https%3A%2F%2Fh%C3%B6me.example%2Fhook",
            "https%3A%2F%2F" + String(repeating: "a", count: 2041)
        ] {
            XCTAssertEqual(problem("lifedashboard://pair#v=1&url=\(url)&secret=xyz"), .incomplete, url)
        }
    }

    func testAnOversizedSecretIsRefused() {
        let base = "lifedashboard://pair#v=1&url=https%3A%2F%2Fa.b%2Fc&secret="
        XCTAssertEqual(problem(base + String(repeating: "x", count: 513)), .incomplete)
        XCTAssertNotNil(ok(base + String(repeating: "x", count: 512)))
    }

    func testOtherLinksAreLeftAlone() {
        for text in [
            "https://example.com/pair#v=1&url=https%3A%2F%2Fa.b%2Fc&secret=xyz",
            "https://owen282000.github.io/other/pair#v=1&url=https%3A%2F%2Fa.b%2Fc&secret=xyz",
            "http://owen282000.github.io/life-dashboard-companion-app/pair#v=1&url=https%3A%2F%2Fa.b%2Fc&secret=xyz",
            "otherapp://pair#v=1&url=https%3A%2F%2Fa.b%2Fc&secret=xyz",
            "lifedashboard://other#v=1",
            "https://owen282000.github.io/life-dashboard-companion-app/",
            "WIFI:S:MyNetwork;T:WPA;P:hunter2;;",
            "just some text",
            "   ",
            ""
        ] {
            XCTAssertEqual(PairingLinks.parse(text), .notAPairingLink, text)
        }
        XCTAssertEqual(PairingLinks.parse(nil), .notAPairingLink)
    }

    // MARK: - Host

    func testTheHostIsShownWithAndWithoutPort() {
        XCTAssertEqual(PairingLink(url: "https://ha.example.com/hook", secret: "s", name: nil).host, "ha.example.com")
        XCTAssertEqual(PairingLink(url: "http://[fd00::1]:8123/x", secret: "s", name: nil).host, "[fd00::1]:8123")
        XCTAssertFalse(PairingLink(url: "http://my_ha:8123/x", secret: "s", name: nil).host.hasPrefix("null"))
    }

    // MARK: - The secret never prints

    func testTheSecretIsRedactedEverywhere() {
        let link = PairingLink(url: "https://a.b/c", secret: "topsecret123", name: "Home")
        var dumped = ""
        dump(link, to: &dumped)
        for text in [String(describing: link), String(reflecting: link), "\(link)", dumped,
                     String(describing: PairingParse.link(link)), String(describing: [link])] {
            XCTAssertFalse(text.contains("topsecret123"), text)
        }
    }

    // MARK: - What iOS lets through over plain HTTP

    func testReachFollowsAppTransportSecurity() {
        let cases: [(String, PairingReach)] = [
            ("https://ha.example.com/hook", .secure),
            ("HTTPS://ha.lan/hook", .secure),
            ("http://192.168.1.10:8123/x", .homeNetwork),
            ("http://10.0.0.2/x", .homeNetwork),
            ("http://172.20.1.1/x", .homeNetwork),
            ("http://100.64.1.2/x", .homeNetwork),
            ("http://127.0.0.1:8123/x", .homeNetwork),
            ("http://[fd00::1]:8123/x", .homeNetwork),
            ("http://[fe80::1]/x", .homeNetwork),
            ("http://homeassistant.local:8123/x", .homeNetwork),
            ("http://homeassistant.local.:8123/x", .homeNetwork),
            ("http://homeassistant:8123/x", .homeNetwork),
            ("http://localhost:8123/x", .homeNetwork),
            ("http://84.12.3.4:8123/x", .publicPlainHttp),
            ("http://100.63.1.2/x", .publicPlainHttp),
            ("http://172.32.0.1/x", .publicPlainHttp),
            ("http://[2001:db8::1]/x", .publicPlainHttp),
            ("http://ha.lan:8123/x", .blockedByATS),
            ("http://ha.home.arpa/x", .blockedByATS),
            ("http://homeassistant.fritz.box/x", .blockedByATS),
            ("http://ha.tailnet.ts.net/x", .blockedByATS),
            ("http://myha.duckdns.org:8123/x", .blockedByATS),
            ("http://127.0.0.1.nip.io:8123/x", .blockedByATS)
        ]
        for (url, expected) in cases {
            XCTAssertEqual(PairingReach.of(url), expected, url)
        }
    }
}
