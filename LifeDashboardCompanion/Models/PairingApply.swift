import Foundation

import CryptoKit

/// One webhook address with its own signing secret and headers, as on Android since 1.28.0
/// (P2-13). Pairing a second receiver no longer replaces the secret the first one checks, and an
/// API key typed for one address never goes to another. Stored whole in the Keychain, since the
/// secret and the headers are credentials; the id is Android's, so a backup maps one to one.
struct WebhookDestination: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var url: String
    var secret: String
    var headers: [String: String]

    var host: String { URLComponents(string: url)?.host ?? url }
}

/// The one-secret settings of 1.9.0 that a list comes down to, for a reader without destinations.
struct SectionKeys: Equatable, Sendable {
    let secret: String
    let headers: [String: String]
    let urlsWithoutHeaders: Set<String>
}

/// The rules for the list, as pure values so each has a test.
enum WebhookDestinations {
    /// An id that stays the same for the same address, so destinations derived from the 1.9.0
    /// settings keep theirs from one read to the next until the list is stored.
    static func stableId(_ url: String) -> String {
        let digest = Array(SHA256.hash(data: Data(url.utf8)))
        let uuid = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                               digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
        return uuid.uuidString.lowercased()
    }

    /// The settings of 1.9.0 and earlier as destinations: every address the section's secret,
    /// and the section's headers unless pairing added it. Nothing changes for anyone on update.
    static func derived(urls: [String], secret: String, headers: [String: String], urlsWithoutHeaders: Set<String>) -> [WebhookDestination] {
        urls.map { url in
            WebhookDestination(id: stableId(url), url: url, secret: secret,
                               headers: urlsWithoutHeaders.contains(url) ? [:] : headers)
        }
    }

    /// The list for `urls`, in their order: an address it has keeps its secret and headers, a
    /// removed one goes, and a new one starts with `newSecret` and no headers, as on Android.
    static func synced(_ current: [WebhookDestination], urls: [String], newSecret: String) -> [WebhookDestination] {
        urls.map { url in
            current.first { $0.url == url }
                ?? WebhookDestination(id: UUID().uuidString.lowercased(), url: url, secret: newSecret, headers: [:])
        }
    }

    /// What the one-secret settings of 1.9.0, and a backup reader without destinations, get:
    /// the secret only when every address has the same one, and the headers only when every
    /// address with headers has the same ones, the others listed as getting none. When they
    /// differ, nothing: an older reader then gets a 401 instead of sending one receiver's
    /// credentials to another.
    static func sectionKeys(_ list: [WebhookDestination]) -> SectionKeys {
        let secrets = Set(list.map(\.secret))
        let secret = secrets.count == 1 ? secrets.first! : ""
        let withHeaders = list.filter { !$0.headers.isEmpty }
        let shared = Set(withHeaders.map(\.headers)).count == 1 ? withHeaders.first!.headers : [:]
        let without = Set(list.filter { shared.isEmpty || $0.headers != shared }.map(\.url))
        return SectionKeys(secret: secret, headers: shared, urlsWithoutHeaders: withHeaders.isEmpty ? [] : without)
    }

    /// A random secret for Generate: 32 bytes as hex, as `openssl rand -hex 32` makes them.
    static func generatedSecret() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }
}

/// What pairing would change, so the sheet can say it before anything happens.
struct SectionChange: Equatable, Sendable {
    let addsUrl: Bool
    /// The address is there already, with another secret, which pairing replaces.
    let replacesSecret: Bool
    /// The other addresses, which keep their own secret and headers.
    let otherUrls: Int

    var changesNothing: Bool { !addsUrl && !replacesSecret }
}

/// Turning a pairing link into settings, as pure values so every rule has a test.
///
/// The rules match Android's since 1.28.0. The address is appended, never replaced: someone
/// feeding a second receiver keeps it. The secret goes to that address alone, so the others keep
/// theirs. And an address pairing adds gets no headers: a link can come from anyone, so an API
/// key typed for another receiver never follows a scanned code to its host.
enum PairingApply {
    static func preview(_ link: PairingLink, current: [WebhookDestination]) -> SectionChange {
        let existing = current.first { $0.url == link.url }
        let secret = existing?.secret.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SectionChange(
            addsUrl: existing == nil,
            replacesSecret: !secret.isEmpty && secret != link.secret,
            otherUrls: current.filter { $0.url != link.url }.count
        )
    }

    static func applied(_ link: PairingLink, to current: [WebhookDestination]) -> [WebhookDestination] {
        guard let index = current.firstIndex(where: { $0.url == link.url }) else {
            return current + [WebhookDestination(id: UUID().uuidString.lowercased(), url: link.url, secret: link.secret, headers: [:])]
        }
        var next = current
        next[index].secret = link.secret
        return next
    }
}

/// How the test ping after pairing went.
enum PairingPingOutcome: Equatable, Sendable {
    /// The receiver answered this request the way the Home Assistant integration does, which it
    /// only does after checking the signature with its own copy of the secret.
    case confirmed
    /// Something answered 2xx without that answer. For most receivers (an older stack, n8n, a
    /// webhook of your own) that is all they ever send. Home Assistant answers 200 to a webhook
    /// id it does not know, so there it is also what a deleted entry looks like.
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
        guard let statusCode else { return .failed(error ?? AppDiagnostic.noResponse.rawValue) }
        if statusCode == 401 { return .refused }
        guard (200...299).contains(statusCode) else { return .failed(error ?? AppDiagnostic.http(statusCode)) }

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

    /// Whether the sheet shows the pairing as done. A plain 2xx is done everywhere but at Home
    /// Assistant, where it can be a deleted entry and the sheet offers Try again.
    func isDone(at link: PairingLink) -> Bool {
        switch self {
        case .confirmed: return true
        case .deliveredUnconfirmed: return !link.looksLikeHomeAssistant
        case .refused, .failed: return false
        }
    }
}

// MARK: - Storage

extension PreferencesManager {
    /// Writes a confirmed pairing: the destination first, so the new address is never posted to
    /// without its secret, then the address. The mark says pairing added it (the setup's tick).
    @MainActor
    func applyPairing(_ link: PairingLink) {
        if !healthWebhookUrls.contains(link.url) { healthUrlsWithoutHeaders.insert(link.url) }
        healthDestinations = PairingApply.applied(link, to: healthDestinations)
        let urls = healthDestinations.map(\.url)
        if urls != healthWebhookUrls { healthWebhookUrls = urls }
    }

    /// Typed in by hand: listed once, with the default secret and no headers, as on Android.
    @MainActor
    func addTypedHealthWebhookUrl(_ url: String) {
        guard !healthWebhookUrls.contains(url) else { return }
        healthUrlsWithoutHeaders.remove(url)
        healthWebhookUrls.append(url)
    }

    /// The edits from an address's sheet, by id.
    @MainActor
    func updateDestination(_ destination: WebhookDestination) {
        guard let index = healthDestinations.firstIndex(where: { $0.id == destination.id }) else { return }
        healthDestinations[index] = destination
    }

    /// Forgets the mark of an address that is no longer listed. Called whenever the list changes.
    func pruneUrlsWithoutHeaders() {
        let marks = healthUrlsWithoutHeaders
        let kept = marks.intersection(healthWebhookUrls)
        if kept != marks { healthUrlsWithoutHeaders = kept }
    }
}
