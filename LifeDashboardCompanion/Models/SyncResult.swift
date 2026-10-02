import Foundation

enum HealthSyncResult {
    case noData
    case success(syncCounts: [HealthDataType: Int], reach: DeliveryReach = DeliveryReach())
    case failure(error: String)
}

/// Which webhooks a delivered sync reached: all of `total` but the `missed` ones. A post counts
/// as delivered once one webhook took it, so a missed one gets nothing queued; the result line
/// and the partial streak say so instead.
struct DeliveryReach: Equatable, Sendable {
    var missed: Set<String> = []
    var total = 0

    /// Some webhooks took it and some did not.
    var partial: Bool { !missed.isEmpty && total > missed.count }
    var delivered: Int { total - missed.count }

    /// The rounds of one sync: a webhook that missed any of them missed part of the sync.
    func merged(with other: DeliveryReach) -> DeliveryReach {
        DeliveryReach(missed: missed.union(other.missed), total: max(total, other.total))
    }
}

/// How the app names a webhook in a sentence: by its host alone. The path and the query can
/// hold a webhook id or a token, so they never reach a notification or a sheet.
enum WebhookHosts {
    static func host(of url: String) -> String {
        if let host = URLComponents(string: url)?.host, !host.isEmpty {
            return host
        }
        // Not a URL Foundation reads: cut it by hand, keeping what lies between the scheme and
        // the first path, query or fragment character, without user info or port.
        var rest = Substring(url)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        if let end = rest.firstIndex(where: { "/?#".contains($0) }) { rest = rest[..<end] }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if !rest.hasPrefix("["), let colon = rest.firstIndex(of: ":") { rest = rest[..<colon] }
        return String(rest)
    }

    /// The hosts of `urls` in their order, each once, joined with ", ".
    static func list(_ urls: [String]) -> String {
        var seen = Set<String>()
        return urls.map(host(of:)).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ", ")
    }
}
