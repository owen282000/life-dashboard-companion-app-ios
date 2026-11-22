import Foundation

/// The check of the Life Dashboard integration's answer to a signed POST, in the order the
/// Android app and the integration's own reference check (tests/phone.py) use, so the shared
/// examples in LifeDashboardCompanionTests/protocol give the same verdict on every platform.
///
/// The signature reaches the phone in one of two places. From integration 1.3.0, when the
/// request asks with `"writeback": {"answer": "body"}`, it sits inside the body:
/// `{"life_dashboard_signed": 1, "answer": "<the answer as text>", "signature": "sha256=..."}`.
/// Home Assistant Cloud passes on only the status, the body and Content-Type, so that is the
/// only form that survives a cloudhook. An older integration signs in the X-Signature header.
/// An answer without a valid signature in either place is never taken.
enum WebhookAnswer {
    /// What the app asks for in the `writeback` block of its request.
    static let requestedForm = "body"

    static let maxBytes = 262_144
    static let maxReadings = 200
    static let maxAge: TimeInterval = 600

    /// Why an answer is not taken. The raw values are the reasons in the shared examples.
    enum Rejection: String, Sendable {
        case tooLarge = "too_large"
        case unsigned
        case signature
        case protocolVersion = "protocol"
        case inReplyTo = "in_reply_to"
        case issuedAt = "issued_at"
        case tooMany = "too_many"
    }

    enum Verdict: Equatable, Sendable {
        /// Taken, with the answer as the text that was signed.
        case accepted(answer: String)
        /// `updateIntegration` marks a plain answer without any signature whose announcement
        /// lacks `signed_body`: an integration before 1.3.0 behind a route that drops the
        /// header. That block is unsigned, so it is good for a message and nothing else.
        case rejected(Rejection, updateIntegration: Bool)

        fileprivate static func no(_ reason: Rejection) -> Verdict {
            .rejected(reason, updateIntegration: false)
        }
    }

    /// An answer once its signature has been checked, or why it has none that counts.
    enum Opened {
        /// The text that was signed, and that text read as JSON.
        case signed(text: String, answer: [String: Any]?)
        case rejected(Rejection, updateIntegration: Bool)
    }

    /// Finds the signature, inside the body or in the header, and checks it. Nothing in the
    /// answer is believed before this says `signed`.
    static func open(body: Data, signatureHeader: String?, secret: String) -> Opened {
        guard body.count <= maxBytes else { return .rejected(.tooLarge, updateIntegration: false) }

        let outer = object(body)
        if let outer, let form = outer["life_dashboard_signed"] {
            // The signed body: the signature inside decides, over the answer's text as it
            // stands. The header, if it arrived at all, is not looked at.
            guard isOne(form) else { return .rejected(.protocolVersion, updateIntegration: false) }
            guard let text = outer["answer"] as? String, let signature = outer["signature"] else {
                return .rejected(.unsigned, updateIntegration: false)
            }
            guard matches(signature, body: Data(text.utf8), secret: secret) else {
                return .rejected(.signature, updateIntegration: false)
            }
            return .signed(text: text, answer: object(Data(text.utf8)))
        }
        guard let signatureHeader, !signatureHeader.isEmpty else {
            let announced = outer?["life_dashboard"] as? [String: Any]
            return .rejected(.unsigned, updateIntegration: announced.map { $0["signed_body"] == nil } ?? false)
        }
        guard matches(signatureHeader, body: body, secret: secret) else {
            return .rejected(.signature, updateIntegration: false)
        }
        return .signed(text: String(bytes: body, encoding: .utf8) ?? "", answer: outer)
    }

    /// The whole decision on the body of a 200, as the Android app makes it before it writes a
    /// measurement. Stops at the first fault: size, signature, protocol, `in_reply_to`,
    /// `issued_at`, count. The iPhone app writes nothing into Apple Health, so only the
    /// pairing check reads an answer and it goes by `open` and `namesRequest`; this is here so
    /// the shared examples hold both apps to one reading of the protocol.
    static func check(
        body: Data,
        signatureHeader: String?,
        requestSignature: String,
        secret: String,
        now: Date
    ) -> Verdict {
        let text: String
        let answer: [String: Any]?
        switch open(body: body, signatureHeader: signatureHeader, secret: secret) {
        case .signed(let signedText, let signedAnswer):
            text = signedText
            answer = signedAnswer
        case .rejected(let reason, let updateIntegration):
            return .rejected(reason, updateIntegration: updateIntegration)
        }

        guard let announced = answer?["life_dashboard"] as? [String: Any], isOne(announced["writeback"]) else {
            return .no(.protocolVersion)
        }
        guard namesRequest(answer, requestSignature) else { return .no(.inReplyTo) }
        let block = answer?["writeback"] as? [String: Any]
        guard let issuedAt = (block?["issued_at"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }),
              abs(now.timeIntervalSince(issuedAt)) <= maxAge
        else { return .no(.issuedAt) }
        if let pending = block?["pending"] as? [Any], pending.count > maxReadings { return .no(.tooMany) }
        return .accepted(answer: text)
    }

    /// Whether `writeback.in_reply_to` is the X-Signature the app put on this very request, so
    /// an answer to an earlier request cannot be played back.
    static func namesRequest(_ answer: [String: Any]?, _ requestSignature: String) -> Bool {
        guard let block = answer?["writeback"] as? [String: Any],
              let inReplyTo = block["in_reply_to"] as? String
        else { return false }
        return WebhookSigner.constantTimeEqual(inReplyTo, requestSignature)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The number 1. JSON's `true` reads as an NSNumber too, and is not a version.
    private static func isOne(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == 1
    }

    private static func matches(_ signature: Any, body: Data, secret: String) -> Bool {
        guard let signature = signature as? String else { return false }
        return WebhookSigner.constantTimeEqual(signature, WebhookSigner.responseSignature(for: body, secret: secret))
    }
}
