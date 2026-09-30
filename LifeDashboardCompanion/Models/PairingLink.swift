import Foundation

/// A scanned or opened pairing code: an address to post to and the secret to sign with.
///
/// Deliberately nothing else. What is synced, and on what schedule, stays a choice made on
/// the phone: a code must never silently start sending heart rate and sleep somewhere.
///
/// The one value in the app that holds a secret outside the Keychain, so every way of
/// printing it (print, interpolation, dump, a failing test) shows the secret redacted.
struct PairingLink: Equatable, Sendable {
    let url: String
    let secret: String
    /// What the receiver calls itself. A claim, not an identity: anyone can write a link.
    let name: String?

    /// Host and port, for the sheet. The user recognises their own machine by this.
    var host: String {
        guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else {
            return url
        }
        let shown = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        if let port = components.port {
            return "\(shown):\(port)"
        }
        return shown
    }

    var isPlainHttp: Bool {
        url.lowercased().hasPrefix("http://")
    }

    var reach: PairingReach { PairingReach.of(url) }
}

extension PairingLink: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "PairingLink(url: \(url), secret: <redacted>, name: \(name ?? "nil"))"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: ["url": url, "secret": "<redacted>", "name": name as Any])
    }
}

/// What iOS will let the app do with an address, decided before anything is saved.
///
/// Android has a switch that allows plain HTTP. iOS has none at runtime: App Transport
/// Security is fixed in Info.plist, and this app allows plain HTTP only through
/// NSAllowsLocalNetworking. So the sheet predicts instead of offering a switch, with the rules
/// ATS applies: an IP address is never checked, a .local name or a name without a dot counts
/// as local, and every other http:// name is refused by the system on every request.
enum PairingReach: Equatable, Sendable {
    /// https.
    case secure
    /// Plain HTTP to the home network: a private IP address, a .local name, or a single name.
    case homeNetwork
    /// Plain HTTP to a public IP address. iOS allows it, but anyone on the way can read it.
    case publicPlainHttp
    /// Plain HTTP to a name like ha.lan or home.duckdns.org, which iOS refuses outright.
    case blockedByATS

    static func of(_ url: String) -> PairingReach {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "http" else { return .secure }
        var host = (components.host ?? "").lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }

        if let octets = ipv4Octets(host) {
            return isPrivate(octets) ? .homeNetwork : .publicPlainHttp
        }
        if host.contains(":") {
            return isPrivateIPv6(host) ? .homeNetwork : .publicPlainHttp
        }
        if !host.contains(".") || host.hasSuffix(".local") {
            return .homeNetwork
        }
        return .blockedByATS
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard (1...3).contains(part.count),
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), value <= 255 else { return nil }
            return value
        }
        return octets.count == 4 ? octets : nil
    }

    /// RFC 1918, loopback, link-local, and the carrier-grade range Tailscale hands out.
    private static func isPrivate(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254), (172, 16...31), (100, 64...127):
            return true
        default:
            return false
        }
    }

    /// Loopback, unique local (fc00::/7) and link-local (fe80::/10).
    private static func isPrivateIPv6(_ host: String) -> Bool {
        let address = host.split(separator: "%").first.map(String.init) ?? host
        if address == "::1" { return true }
        let firstGroup = address.split(separator: ":", omittingEmptySubsequences: false).first ?? ""
        guard let value = Int(firstGroup, radix: 16) else { return false }
        return (value & 0xFE00) == 0xFC00 || (value & 0xFFC0) == 0xFE80
    }
}

/// Why a link that is ours cannot be used. Each has its own message.
enum PairingProblem: Equatable, Sendable {
    /// A newer format. The app needs updating, not the user's patience.
    case unsupportedVersion
    /// No address, no secret, or an address the app cannot post to.
    case incomplete
    /// A receiver that accepts nothing this app can send.
    case noUsableSource

    var message: LocalizedStringResource {
        switch self {
        case .unsupportedVersion:
            return "This code was made by a newer version. Update the app and scan again."
        case .incomplete:
            return "This code is missing its address or its secret."
        case .noUsableSource:
            return "This receiver does not accept anything this app can send."
        }
    }
}

/// The outcome of reading a link: usable, ours but unusable, or not ours at all.
enum PairingParse: Equatable, Sendable {
    case link(PairingLink)
    case invalid(PairingProblem)
    /// Not a pairing link. The scanner keeps scanning; an opened URL is ignored.
    case notAPairingLink
}

/// Reading the pairing links a receiver hands out.
///
/// Two shapes carry the same payload: the https link the Home Assistant integration puts in
/// its QR code, and a lifedashboard:// URL, which the landing page opens the app with. The
/// payload lives in the fragment after the #, because a browser never sends that to a server
/// (RFC 3986 section 3.5), so the secret stays on the phone even when the link goes through a
/// web page.
///
/// The same format and rules as PairingLink.kt in the Android app, and the generator is
/// pairing.py in the integration: the tests carry its known-good vector.
enum PairingLinks {
    static let pairHost = "owen282000.github.io"
    static let pairPath = "/life-dashboard-companion-app/pair"
    static let scheme = "lifedashboard"
    static let schemeHost = "pair"

    /// The only format this build understands.
    static let version = "1"

    /// The section id this app sends as. A code that lists its sources must include it; the
    /// id names the Health section on both platforms, not Health Connect itself.
    static let healthSource = "health_connect"

    static let maxUrl = 2048
    static let maxSecret = 512
    static let maxName = 64

    static func parse(_ text: String?) -> PairingParse {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notAPairingLink }

        // Split the fragment off by hand. URL.fragment and URLComponents.fragment both decode,
        // which would turn an encoded & inside the webhook URL into a separator, and a link
        // copied out of an address bar can carry a literal space that URLComponents refuses.
        let address: Substring
        let rawFragment: Substring?
        if let hash = trimmed.firstIndex(of: "#") {
            address = trimmed[..<hash]
            rawFragment = trimmed[trimmed.index(after: hash)...]
        } else {
            address = Substring(trimmed)
            rawFragment = nil
        }

        guard isOurs(String(address)) else { return .notAPairingLink }
        guard let rawFragment else { return .invalid(.incomplete) }

        let fields = fields(rawFragment)
        guard fields["v"] == version else { return .invalid(.unsupportedVersion) }

        let url = (fields["url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = (fields["secret"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsableUrl(url), isUsableSecret(secret) else { return .invalid(.incomplete) }

        guard acceptsHealth(fields["sources"]) else { return .invalid(.noUsableSource) }

        return .link(PairingLink(url: url, secret: secret, name: name(fields["name"])))
    }

    private static func isOurs(_ address: String) -> Bool {
        guard let colon = address.firstIndex(of: ":") else { return false }
        let scheme = address[..<colon].lowercased()
        var rest = address[address.index(after: colon)...]

        switch scheme {
        case "https":
            guard rest.hasPrefix("//") else { return false }
            rest = rest.dropFirst(2)
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            let authority = rest[..<slash].lowercased()
            var path = String(rest[slash...])
            while path.hasSuffix("/") { path.removeLast() }
            return authority == pairHost && path.lowercased() == pairPath
        case self.scheme:
            // lifedashboard://pair, and the form without the authority slashes.
            var target = String(rest)
            while target.hasPrefix("/") { target.removeFirst() }
            while target.hasSuffix("/") { target.removeLast() }
            return target.lowercased() == schemeHost
        default:
            return false
        }
    }

    /// Split on & and the first =, decode after. A repeated key keeps its last value, as on
    /// Android, and never traps the way Dictionary(uniqueKeysWithValues:) would.
    private static func fields(_ rawFragment: Substring) -> [String: String] {
        var result: [String: String] = [:]
        for part in rawFragment.split(separator: "&") {
            guard let equals = part.firstIndex(of: "="), equals != part.startIndex else { continue }
            result[decode(part[..<equals])] = decode(part[part.index(after: equals)...])
        }
        return result
    }

    /// Percent-decoding that leaves a literal + alone: a pairing link is not a form body. A
    /// malformed escape keeps the raw text rather than dropping the field.
    private static func decode(_ value: Substring) -> String {
        String(value).removingPercentEncoding ?? String(value)
    }

    private static func isUsableUrl(_ url: String) -> Bool {
        guard url.utf16.count <= maxUrl,
              !url.contains(where: { $0.isWhitespace }),
              !url.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              // Android stores its URL list comma-joined, and the same code serves both apps.
              !url.contains(","),
              let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              // No look-alike: https://homeassistant.local@evil.example goes to evil.example.
              components.user == nil, components.password == nil,
              host.allSatisfy(\.isASCII)
        else { return false }
        return true
    }

    private static func isUsableSecret(_ secret: String) -> Bool {
        !secret.isEmpty && secret.utf16.count <= maxSecret && !secret.contains(where: { $0.isWhitespace })
    }

    /// Control and format characters (bidi overrides, zero-width) go, so a name cannot pose as
    /// something it is not.
    private static func name(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(maxName))
        return short.isEmpty ? nil : short
    }

    /// An absent or blank field means the receiver takes everything; unknown ids are ignored.
    /// iOS has only the Health section, so a code for Screen Time alone is of no use here.
    private static func acceptsHealth(_ raw: String?) -> Bool {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        return raw.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == healthSource }
    }
}
