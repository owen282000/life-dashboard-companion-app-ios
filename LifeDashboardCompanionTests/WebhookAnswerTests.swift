import XCTest
@testable import LifeDashboardCompanion

/// The integration's answer, checked against the shared protocol examples. The two files in
/// `protocol/` are copied unchanged from `protocol/vectors/` in the Life Dashboard integration
/// (owen282000/life-dashboard-ha), where the Android app's tests and the integration's own read
/// the same bytes (version 1, as of integration commit 6ec8477). Refresh them from there, never
/// edit them here.
final class WebhookAnswerTests: XCTestCase {
    /// The `version` these tests were written for. A refreshed copy with another one fails
    /// here first, so new cases are looked at instead of passing unread.
    private let vectorsVersion = 1

    private func vectors(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "protocol"),
            "protocol/\(name).json is not in the test bundle"
        )
        let file = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(file["version"] as? Int, vectorsVersion, name)
        XCTAssertEqual(file["response_key_label"] as? String, WebhookSigner.responseKeyLabel, name)
        return file
    }

    private func cases(_ file: [String: Any]) throws -> [[String: Any]] {
        let list = try XCTUnwrap(file["cases"] as? [[String: Any]])
        XCTAssertFalse(list.isEmpty)
        return list
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text), text)
    }

    // MARK: - answers.json: what reaches the phone, and whether it is taken

    func testTheAnswerKeyIsTheOneInTheVectors() throws {
        let key = try XCTUnwrap(try vectors("answers")["response_key"] as? [String: String])
        let derived = WebhookSigner.responseKey(secret: try XCTUnwrap(key["secret"]))
        XCTAssertEqual(derived.map { String(format: "%02x", $0) }.joined(), key["hex"])
    }

    func testEveryAnswerInTheVectorsGetsItsVerdict() throws {
        var reasons = Set<String>()
        for item in try cases(try vectors("answers")) {
            let name = try XCTUnwrap(item["name"] as? String)
            let response = try XCTUnwrap(item["response"] as? [String: Any], name)
            let expect = try XCTUnwrap(item["expect"] as? [String: Any], name)
            XCTAssertEqual(response["status"] as? Int, 200, name)
            let headers = try XCTUnwrap(response["headers"] as? [String: String], name)

            let verdict = WebhookAnswer.check(
                body: Data(try XCTUnwrap(response["body"] as? String, name).utf8),
                signatureHeader: headers["X-Signature"],
                requestSignature: try XCTUnwrap(item["request_signature"] as? String, name),
                secret: try XCTUnwrap(item["secret"] as? String, name),
                now: try date(try XCTUnwrap(item["now"] as? String, name))
            )

            if try XCTUnwrap(expect["accept"] as? Bool, name) {
                XCTAssertEqual(verdict, .accepted(answer: try XCTUnwrap(expect["answer"] as? String, name)), name)
            } else {
                let reason = try XCTUnwrap(expect["reason"] as? String, name)
                reasons.insert(reason)
                XCTAssertEqual(
                    verdict,
                    .rejected(
                        try XCTUnwrap(WebhookAnswer.Rejection(rawValue: reason), name),
                        updateIntegration: try XCTUnwrap(expect["update_integration"] as? Bool, name)
                    ),
                    name
                )
            }
        }
        // The file covers these; the size and the count have their own tests below.
        XCTAssertEqual(reasons, ["unsigned", "signature", "protocol", "in_reply_to", "issued_at"])
    }

    /// The pairing check asks for the signature and the request it answers, not for the
    /// write-back protocol or the answer's age, so each vector has its own outcome there.
    func testThePairingCheckOnEveryAnswerInTheVectors() throws {
        for item in try cases(try vectors("answers")) {
            let name = try XCTUnwrap(item["name"] as? String)
            let response = try XCTUnwrap(item["response"] as? [String: Any], name)
            let expect = try XCTUnwrap(item["expect"] as? [String: Any], name)
            let headers = try XCTUnwrap(response["headers"] as? [String: String], name)

            let outcome = PairingPingOutcome.from(
                statusCode: response["status"] as? Int,
                body: Data(try XCTUnwrap(response["body"] as? String, name).utf8),
                answerSignature: headers["X-Signature"],
                requestSignature: try XCTUnwrap(item["request_signature"] as? String, name),
                secret: try XCTUnwrap(item["secret"] as? String, name),
                error: nil
            )

            let expected: PairingPingOutcome
            if expect["accept"] as? Bool == true {
                expected = .confirmed
            } else if expect["update_integration"] as? Bool == true {
                expected = .confirmedUnsigned
            } else if expect["reason"] as? String == "issued_at" {
                expected = .confirmed
            } else {
                expected = .deliveredUnconfirmed
            }
            XCTAssertEqual(outcome, expected, name)
        }
    }

    // MARK: - exchanges.json: a request, its signature and the integration's exact answer

    func testEveryRequestInTheVectorsGetsItsSignature() throws {
        var checked = 0
        for item in try cases(try vectors("exchanges")) {
            let name = try XCTUnwrap(item["name"] as? String)
            let expect = try XCTUnwrap(item["expect"] as? [String: Any], name)
            // A 401 is a request with a wrong signature or none: nothing to recompute.
            guard expect["status"] as? Int != 401 else { continue }
            let request = try XCTUnwrap(item["request"] as? [String: Any], name)
            let body = Data(try XCTUnwrap(request["body"] as? String, name).utf8)
            let secret = try XCTUnwrap(item["secret"] as? String, name)
            XCTAssertEqual(WebhookSigner.signatureHeader(for: body, secret: secret), request["signature"] as? String, name)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testEveryAnswerTheIntegrationGivesIsTaken() throws {
        let file = try vectors("exchanges")
        let integration = try XCTUnwrap(file["integration"] as? [String: String])
        let now = try date(try XCTUnwrap(integration["now"]))
        var signedBodies = 0
        for item in try cases(file) {
            let name = try XCTUnwrap(item["name"] as? String)
            let expect = try XCTUnwrap(item["expect"] as? [String: Any], name)
            guard expect["status"] as? Int == 200 else { continue }
            let request = try XCTUnwrap(item["request"] as? [String: Any], name)
            let secret = try XCTUnwrap(item["secret"] as? String, name)
            let answer = try XCTUnwrap(expect["answer"] as? String, name)
            let body = Data(try XCTUnwrap(expect["body"] as? String, name).utf8)
            let header = try XCTUnwrap(expect["x_signature"] as? String, name)
            let signedBody = try XCTUnwrap(expect["signed_body"] as? Bool, name)

            XCTAssertEqual(WebhookSigner.responseSignature(for: Data(answer.utf8), secret: secret), expect["answer_signature"] as? String, name)
            XCTAssertEqual(WebhookSigner.responseSignature(for: body, secret: secret), header, name)

            // With the header, and through Home Assistant Cloud, which drops it.
            for signatureHeader in signedBody ? [header, nil] : [header] {
                let verdict = WebhookAnswer.check(
                    body: body,
                    signatureHeader: signatureHeader,
                    requestSignature: try XCTUnwrap(request["signature"] as? String, name),
                    secret: secret,
                    now: now
                )
                XCTAssertEqual(verdict, .accepted(answer: answer), name)
            }
            if signedBody { signedBodies += 1 }
        }
        XCTAssertGreaterThan(signedBodies, 0)
    }

    func testTheTestPingAsksTheWayTheVectorsDo() throws {
        // The app builds its own payload; what it must share with the vectors is the field
        // the integration reads: writeback.answer = "body".
        let asks = try XCTUnwrap(try cases(try vectors("exchanges")).first { $0["name"] as? String == "test-ping-that-asks" })
        let request = try XCTUnwrap(asks["request"] as? [String: Any])
        let theirs = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(request["body"] as? String).utf8)) as? [String: Any])
        let ours = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(TestPing.body())) as? [String: Any])
        XCTAssertEqual(ours["writeback"] as? [String: String], theirs["writeback"] as? [String: String])
        XCTAssertEqual(ours["writeback"] as? [String: String], ["answer": WebhookAnswer.requestedForm])
    }

    // MARK: - The branches the vectors leave out

    private let secret = "key"
    private let request = "sha256=" + String(repeating: "1", count: 64)
    private let issued = "2026-11-20T12:00:00Z"

    private func plain(
        announced: String = "{\"version\":\"1.3.0\",\"writeback\":1,\"signed_body\":1}",
        issuedAt: String? = nil,
        pending: Int? = nil
    ) -> Data {
        var block = "\"in_reply_to\":\"\(request)\",\"issued_at\":\"\(issuedAt ?? issued)\",\"configured\":[]"
        if let pending {
            block += ",\"pending\":[" + Array(repeating: "{}", count: pending).joined(separator: ",") + "],\"more\":false"
        }
        return Data("{\"life_dashboard\":\(announced),\"writeback\":{\(block)}}".utf8)
    }

    private func signed(_ answer: Data, form: Any = 1, answerField: Any? = nil, signature: Any? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "life_dashboard_signed": form,
            "answer": answerField ?? String(bytes: answer, encoding: .utf8) ?? "",
            "signature": signature ?? WebhookSigner.responseSignature(for: answer, secret: secret)
        ])
    }

    private func check(_ body: Data, header: String? = nil, secondsLater: TimeInterval = 2) throws -> WebhookAnswer.Verdict {
        WebhookAnswer.check(
            body: body,
            signatureHeader: header,
            requestSignature: request,
            secret: secret,
            now: try date(issued).addingTimeInterval(secondsLater)
        )
    }

    private func rejected(_ reason: WebhookAnswer.Rejection, update: Bool = false) -> WebhookAnswer.Verdict {
        .rejected(reason, updateIntegration: update)
    }

    func testABodyOverTheLimitIsRefusedBeforeAnythingElse() throws {
        // A valid signature does not help: the size comes first.
        let padded = plain(announced: "{\"version\":\"1.3.0\",\"writeback\":1,\"pad\":\"\(String(repeating: "x", count: WebhookAnswer.maxBytes))\"}")
        XCTAssertGreaterThan(padded.count, WebhookAnswer.maxBytes)
        XCTAssertEqual(try check(padded, header: WebhookSigner.responseSignature(for: padded, secret: secret)), rejected(.tooLarge))
    }

    func testMoreThan200ReadingsAreRefused() throws {
        let most = plain(pending: WebhookAnswer.maxReadings)
        XCTAssertEqual(try check(try signed(most)), .accepted(answer: String(bytes: most, encoding: .utf8) ?? ""))
        XCTAssertEqual(try check(try signed(plain(pending: WebhookAnswer.maxReadings + 1))), rejected(.tooMany))
    }

    func testTheFormMustBeTheNumberOne() throws {
        for form in [true, 0, "1", NSNull()] as [Any] {
            XCTAssertEqual(try check(try signed(plain(), form: form)), rejected(.protocolVersion), "\(form)")
        }
    }

    func testASignedBodyNeedsItsAnswerAsTextAndASignature() throws {
        // The answer as an object instead of text: nothing was signed that can be checked.
        XCTAssertEqual(try check(try signed(plain(), answerField: ["life_dashboard": ["writeback": 1]])), rejected(.unsigned))
        // A signature that is not text never matches.
        XCTAssertEqual(try check(try signed(plain(), signature: 1)), rejected(.signature))
        XCTAssertEqual(try check(try signed(plain(), signature: NSNull())), rejected(.signature))
    }

    func testASignedBodyIsNeverAnOldIntegration() throws {
        // The form without a signature does not ask to update: it is not a plain answer.
        let body = Data("{\"life_dashboard_signed\":1,\"answer\":\"{}\"}".utf8)
        XCTAssertEqual(try check(body), rejected(.unsigned))
    }

    func testASignedAnswerThatIsNotAnObjectIsRefused() throws {
        XCTAssertEqual(try check(try signed(Data("[1,2]".utf8))), rejected(.protocolVersion))
        XCTAssertEqual(try check(try signed(Data("not json".utf8))), rejected(.protocolVersion))
    }

    func testWithoutAnySignatureOnlyAnOldIntegrationAsksForAnUpdate() throws {
        // Before 1.3.0: the announcement has no signed_body.
        XCTAssertEqual(try check(plain(announced: "{\"version\":\"1.2.0\",\"writeback\":1}")), rejected(.unsigned, update: true))
        XCTAssertEqual(try check(plain(announced: "{\"version\":\"1.2.0\",\"writeback\":1}"), header: ""), rejected(.unsigned, update: true))
        // From 1.3.0, or anything that is not the integration's answer: no update to ask for.
        XCTAssertEqual(try check(plain()), rejected(.unsigned))
        XCTAssertEqual(try check(Data()), rejected(.unsigned))
        XCTAssertEqual(try check(Data("{\"ok\":true}".utf8)), rejected(.unsigned))
        XCTAssertEqual(try check(Data("[]".utf8)), rejected(.unsigned))
        XCTAssertEqual(try check(Data("<html>".utf8)), rejected(.unsigned))
    }

    func testTheWriteBackProtocolMustBeOne() throws {
        for announced in ["{\"version\":\"9.0.0\",\"writeback\":2}", "{\"version\":\"0.6.0\"}", "{\"writeback\":true}", "1"] {
            XCTAssertEqual(try check(try signed(plain(announced: announced))), rejected(.protocolVersion), announced)
            let body = plain(announced: announced)
            let header = WebhookSigner.responseSignature(for: body, secret: secret)
            XCTAssertEqual(try check(body, header: header), rejected(.protocolVersion), announced)
        }
    }

    func testTheAnswerIsTakenUpToTenMinutesEitherWay() throws {
        let body = try signed(plain())
        let taken = WebhookAnswer.Verdict.accepted(answer: String(bytes: plain(), encoding: .utf8) ?? "")
        XCTAssertEqual(try check(body, secondsLater: 600), taken)
        XCTAssertEqual(try check(body, secondsLater: -600), taken)
        XCTAssertEqual(try check(body, secondsLater: 601), rejected(.issuedAt))
        // A phone whose clock runs behind sees an answer from the future.
        XCTAssertEqual(try check(body, secondsLater: -601), rejected(.issuedAt))
    }

    func testAnIssuedAtThatIsNotATimeIsRefused() throws {
        for issuedAt in ["", "yesterday", "2026-11-20"] {
            XCTAssertEqual(try check(try signed(plain(issuedAt: issuedAt))), rejected(.issuedAt), issuedAt)
        }
    }

    func testTheHeaderOfAPlainAnswerIsOverTheWholeBody() throws {
        let body = plain(announced: "{\"version\":\"1.2.0\",\"writeback\":1}")
        let header = WebhookSigner.responseSignature(for: body, secret: secret)
        XCTAssertEqual(try check(body, header: header), .accepted(answer: String(bytes: body, encoding: .utf8) ?? ""))
        // Signed with the secret itself, the key of the other direction.
        XCTAssertEqual(try check(body, header: WebhookSigner.signatureHeader(for: body, secret: secret)), rejected(.signature))
        XCTAssertEqual(try check(body, header: WebhookSigner.responseSignature(for: body, secret: "other")), rejected(.signature))
    }
}
