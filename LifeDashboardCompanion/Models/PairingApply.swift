import Foundation

/// What the health webhook settings hold, as far as pairing cares.
struct SectionWebhook: Equatable, Sendable {
    var urls: [String]
    var secret: String
    /// URLs that get none of the custom headers: the ones pairing added.
    var urlsWithoutHeaders: Set<String>

    /// Typed in by hand: listed once, and from then on it gets the custom headers. That is the
    /// documented way to send them to an address that pairing added.
    func withTypedUrl(_ url: String) -> SectionWebhook {
        var copy = self
        if !copy.urls.contains(url) { copy.urls.append(url) }
        copy.urlsWithoutHeaders.remove(url)
        return copy
    }
}

/// What pairing would change, so the sheet can say it before anything happens.
struct SectionChange: Equatable, Sendable {
    let addsUrl: Bool
    let replacesSecret: Bool
    /// How many other addresses are signed with the secret pairing replaces.
    let otherUrls: Int

    var changesNothing: Bool { !addsUrl && !replacesSecret }
}

/// Turning a pairing link into settings, as pure values so every rule has a test.
///
/// The rules match Android's PairingApply. The address is appended, never replaced: someone
/// feeding a second receiver keeps it. The secret is replaced, because the app signs with one
/// secret and the new receiver would refuse the old one. And an address pairing adds gets none
/// of the custom headers: those were typed for the receivers already there, and a link can come
/// from anyone, so an API key never follows a scanned code to its host.
enum PairingApply {
    static func preview(_ link: PairingLink, current: SectionWebhook) -> SectionChange {
        let secret = current.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        return SectionChange(
            addsUrl: !current.urls.contains(link.url),
            replacesSecret: !secret.isEmpty && secret != link.secret,
            otherUrls: current.urls.filter { $0 != link.url }.count
        )
    }

    static func applied(_ link: PairingLink, to current: SectionWebhook) -> SectionWebhook {
        let adds = !current.urls.contains(link.url)
        return SectionWebhook(
            urls: adds ? current.urls + [link.url] : current.urls,
            secret: link.secret,
            urlsWithoutHeaders: adds ? current.urlsWithoutHeaders.union([link.url]) : current.urlsWithoutHeaders
        )
    }

    /// The custom headers one URL gets. Fail closed: only a URL that is configured now and was
    /// not added by pairing gets them, so neither a paired address nor one removed since a
    /// payload was queued ever receives an API key typed for the others.
    static func headers(
        for url: String,
        custom: [String: String],
        configuredUrls: [String],
        urlsWithoutHeaders: Set<String>
    ) -> [String: String] {
        guard configuredUrls.contains(url), !urlsWithoutHeaders.contains(url) else { return [:] }
        return custom
    }

    /// The addresses a queued payload may still go to: removing an address stops delivery to it
    /// at once, instead of for the week a queued item lives.
    static func deliverable(_ queued: [String], configuredUrls: [String]) -> [String] {
        queued.filter { configuredUrls.contains($0) }
    }
}

/// How the test ping after pairing went.
enum PairingPingOutcome: Equatable, Sendable {
    /// The integration answered this request, which it only does after checking the signature
    /// with its own copy of the secret.
    case confirmed
    /// Something answered 2xx, but not the integration. Home Assistant answers 200 to a webhook
    /// id it does not know, so this is what a deleted entry looks like.
    case deliveredUnconfirmed
    /// 401: the receiver does not have this secret.
    case refused
    case failed(String)

    /// The integration's answer names the request's own X-Signature in writeback.in_reply_to.
    /// Its X-Signature header is checked when it is there; Home Assistant Cloud's relay passes
    /// only Content-Type back, so it cannot be required.
    static func from(
        statusCode: Int?,
        body: Data,
        answerSignature: String?,
        requestSignature: String,
        secret: String,
        error: String?
    ) -> PairingPingOutcome {
        guard let statusCode else { return .failed(error ?? "No response") }
        if statusCode == 401 { return .refused }
        guard (200...299).contains(statusCode) else { return .failed("HTTP \(statusCode)") }

        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["life_dashboard"] is [String: Any],
              let writeback = json["writeback"] as? [String: Any],
              let inReplyTo = writeback["in_reply_to"] as? String,
              WebhookSigner.constantTimeEqual(inReplyTo, requestSignature)
        else { return .deliveredUnconfirmed }

        if let answerSignature,
           !WebhookSigner.constantTimeEqual(answerSignature, WebhookSigner.responseSignature(for: body, secret: secret)) {
            return .deliveredUnconfirmed
        }
        return .confirmed
    }
}

// MARK: - Storage

extension PreferencesManager {
    var healthSection: SectionWebhook {
        SectionWebhook(
            urls: healthWebhookUrls,
            secret: healthSigningSecret,
            urlsWithoutHeaders: healthUrlsWithoutHeaders
        )
    }

    /// Writes a confirmed pairing: the header exclusion first, so a sync that reads in between
    /// never sends headers to the new host, then the secret, so the new host is never posted to
    /// with the old one, then the address.
    @MainActor
    func applyPairing(_ link: PairingLink) {
        let next = PairingApply.applied(link, to: healthSection)
        healthUrlsWithoutHeaders = next.urlsWithoutHeaders
        healthSigningSecret = next.secret
        if next.urls != healthWebhookUrls {
            healthWebhookUrls = next.urls
        }
    }

    @MainActor
    func addTypedHealthWebhookUrl(_ url: String) {
        let next = healthSection.withTypedUrl(url)
        healthUrlsWithoutHeaders = next.urlsWithoutHeaders
        if next.urls != healthWebhookUrls {
            healthWebhookUrls = next.urls
        }
    }

    /// Forgets the mark of an address that is no longer listed. Called whenever the list
    /// changes; the marks setter itself never prunes, or the marks-first write would lose its mark.
    func pruneUrlsWithoutHeaders() {
        let marks = healthUrlsWithoutHeaders
        let kept = marks.intersection(healthWebhookUrls)
        if kept != marks { healthUrlsWithoutHeaders = kept }
    }
}
