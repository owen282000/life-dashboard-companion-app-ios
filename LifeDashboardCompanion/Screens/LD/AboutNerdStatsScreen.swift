import SwiftUI

struct AboutNerdStatsScreen: View {
    private let records = UserDefaults.standard.integer(forKey: "stats_lifetime_records")
    private let deliveries = UserDefaults.standard.integer(forKey: "stats_total_deliveries")
    private let largestPayload = UserDefaults.standard.integer(forKey: "stats_largest_payload")
    private let firstSync = UserDefaults.standard.object(forKey: "stats_first_sync") as? Date

    var body: some View {
        LDScreen {
            LDHeading("You found the secret")
            PulseLine(variant: deliveries == 0 ? .flat : .normal)

            if deliveries == 0 {
                LDNote("No syncs yet. Come back when your data has started flowing.", top: 4)
            } else {
                LDKeyValueList(stats)
                    .ldStaggerRise()
                if let days {
                    // Two keys that the old card showed as a label and its value, translated apart.
                    LDNote(
                        Text(verbatim: "\(String(localized: "That is")) \(String(localized: "\(days) days of quantified you"))"),
                        color: LDTheme.accentTextSoft,
                        top: 12
                    )
                    .ldStaggerRise(1)
                }
            }
        }
        .navigationTitle("Nerd Stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var stats: [LDKeyValue] {
        var stats = [
            LDKeyValue("Records delivered", Text(records.formatted())),
            LDKeyValue("Successful deliveries", Text(deliveries.formatted()))
        ]
        if largestPayload > 0 {
            stats.append(LDKeyValue(
                "Largest payload",
                Text(ByteCountFormatter.string(fromByteCount: Int64(largestPayload), countStyle: .file))
            ))
        }
        if let firstSync {
            stats.append(LDKeyValue("Syncing since", Text(firstSync.formatted(date: .abbreviated, time: .omitted))))
        }
        return stats
    }

    private var days: Int? {
        firstSync.map { max(1, Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 1) }
    }
}
