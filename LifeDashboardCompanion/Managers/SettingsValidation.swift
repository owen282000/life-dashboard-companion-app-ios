import Foundation

/// What the settings accept for a custom header and an MQTT broker, in one place: the Health
/// tab and the first-run setup refuse a bad value as it is entered, the settings import refuses
/// a file that carries one, and a delivery refuses to send a header iOS would mangle.
///
/// iOS does not refuse a bad header itself: a name with a space or a value with a line break
/// is left out of the request without a word, and a name with a colon goes out as another
/// header. A header that carries an API key would then be missing, and the server's 401 would
/// be all the user saw.
enum SettingsValidation {
    static let maxHeaderNameLength = 256
    static let maxHeaderValueLength = 8192
    static let maxHeaders = 32
    static let portRange = 1...65_535

    // MARK: - Custom headers

    enum HeaderProblem: Equatable {
        case emptyName
        case invalidName
        case emptyValue
        case invalidValue
        case valueTooLong
        case tooMany

        var message: String {
            switch self {
            case .emptyName:
                return String(localized: "Enter a header name")
            case .invalidName:
                return String(localized: "Not a valid header name: use letters, digits and hyphens, without spaces or colons")
            case .emptyValue:
                return String(localized: "Enter a header value")
            case .invalidValue:
                return String(localized: "A header value cannot contain line breaks or control characters")
            case .valueTooLong:
                return String(localized: "This header value is too long")
            case .tooMany:
                return String(localized: "No room for another custom header. Remove one first.")
            }
        }
    }

    /// RFC 9110's token: what an HTTP field name is made of.
    private static let tokenCharacters = CharacterSet(
        charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    )

    static func isValidHeaderName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.count <= maxHeaderNameLength &&
            name.unicodeScalars.allSatisfy { tokenCharacters.contains($0) }
    }

    /// No control character but a tab, and no line or paragraph separator: nothing that could
    /// end the header line, or that iOS would drop it for.
    static func isValidHeaderValue(_ value: String) -> Bool {
        value.count <= maxHeaderValueLength && !value.unicodeScalars.contains { scalar in
            scalar != "\t" && (scalar.properties.generalCategory == .control ||
                scalar == "\u{2028}" || scalar == "\u{2029}")
        }
    }

    /// What is wrong with a header typed on the Health tab, or nil when it can be added.
    /// `existing` are the headers already there; one with the same name is replaced, so it
    /// does not count against the limit.
    static func headerProblem(name: String, value: String, existing: [String: String] = [:]) -> HeaderProblem? {
        if name.isEmpty { return .emptyName }
        if !isValidHeaderName(name) { return .invalidName }
        if value.isEmpty { return .emptyValue }
        if value.count > maxHeaderValueLength { return .valueTooLong }
        if !isValidHeaderValue(value) { return .invalidValue }
        if existing[name] == nil && existing.count >= maxHeaders { return .tooMany }
        return nil
    }

    /// The first header, by name, that would not go out as configured, or nil. Headers saved
    /// before these rules existed can still be on the iPhone.
    static func firstInvalidHeader(_ headers: [String: String]) -> String? {
        headers.keys.sorted().first { !isValidHeaderName($0) || !isValidHeaderValue(headers[$0] ?? "") }
    }

    // MARK: - MQTT broker

    enum BrokerProblem: Equatable {
        case emptyHost
        case whitespace
        case scheme
        case portInHost
        case invalidHost
        case invalidPort

        var message: String {
            switch self {
            case .emptyHost:
                return String(localized: "Enter the broker's host name or IP address")
            case .whitespace:
                return String(localized: "A host name cannot contain spaces")
            case .scheme:
                return String(localized: "Enter only the host, without mqtt:// or another prefix")
            case .portInHost:
                return String(localized: "Enter the port in the Port field, not after the host")
            case .invalidHost:
                return String(localized: "Not a valid host name or IP address")
            case .invalidPort:
                return String(localized: "The port is a number from 1 to 65535")
            }
        }
    }

    /// The host as it is saved: trimmed, and an IPv6 address without the brackets a URL puts
    /// around it, which Network would read as a name.
    static func normalizedBrokerHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// What is wrong with a broker host, or nil for a host name, an IPv4 address or an IPv6
    /// address, with or without brackets.
    static func brokerHostProblem(_ host: String) -> BrokerProblem? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .emptyHost }
        if trimmed.contains(where: \.isWhitespace) { return .whitespace }
        if trimmed.contains("://") { return .scheme }
        let host = normalizedBrokerHost(trimmed)
        if isIPv6Address(host) || isIPv4Address(host) || isHostName(host) { return nil }
        if let colon = host.lastIndex(of: ":"), host.filter({ $0 == ":" }).count == 1,
           !host[host.index(after: colon)...].isEmpty, host[host.index(after: colon)...].allSatisfy(\.isASCIIDigit) {
            return .portInHost
        }
        return .invalidHost
    }

    /// The port as typed: nil when it is a number from 1 to 65535.
    static func brokerPortProblem(_ text: String) -> BrokerProblem? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.allSatisfy(\.isASCIIDigit), trimmed.count <= 5, let port = Int(trimmed),
              portRange.contains(port) else { return .invalidPort }
        return nil
    }

    /// RFC 1123's names, with the underscore some local setups use (a Docker service name).
    /// A name whose labels are all digits is a mistyped IPv4 address, not a name.
    static func isHostName(_ host: String) -> Bool {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !name.isEmpty, name.count <= 253 else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        let labelsAreValid = labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                label.allSatisfy { $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" || $0 == "_" }
        }
        return labelsAreValid && !labels.allSatisfy { $0.allSatisfy(\.isASCIIDigit) }
    }

    static func isIPv4Address(_ host: String) -> Bool {
        var address = in_addr()
        return host.allSatisfy { $0.isASCIIDigit || $0 == "." } && inet_pton(AF_INET, host, &address) == 1
    }

    /// An IPv6 address, with a zone for a link-local one (fe80::1%en0).
    static func isIPv6Address(_ host: String) -> Bool {
        let parts = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 && (parts[1].isEmpty || !parts[1].allSatisfy { $0.isASCIIDigit || $0.isASCIILetter }) {
            return false
        }
        var address = in6_addr()
        return host.contains(":") && inet_pton(AF_INET6, String(parts[0]), &address) == 1
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
