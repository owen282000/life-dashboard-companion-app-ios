import SwiftUI

struct MoreScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    var body: some View {
        LDScreen {
            LDHeading("More")
            LDGap(12)
            LDCard {
                LDRow(
                    "Advanced",
                    value: advancedSummary,
                    valueColor: prefs.clientCertificate?.needsAttention() == true ? LDTheme.warning : LDTheme.muted
                )
                .ldLink(to: .advanced)
                LDRow("Notifications", value: notificationsSummary)
                    .ldLink(to: .notifications)
            }
            .ldStaggerRise(0)
            LDGap(10)
            LDCard {
                LDRow("Export data", value: Text("CSV, JSON"))
                    .ldLink(to: .exportData)
                LDRow("Backup and restore", value: Text("Settings"))
                    .ldLink(to: .backupRestore)
            }
            .ldStaggerRise(1)
            LDSectionLabel("Appearance")
            LDSegmented(selection: $prefs.appTheme, segments: [
                LDSegment(AppTheme.system, "System"),
                LDSegment(AppTheme.light, "Light"),
                LDSegment(AppTheme.dark, "Dark"),
            ], label: "Appearance")
            .ldStaggerRise(2)
            LDGap(14)
            LDCard {
                LDRow("About", value: Text(verbatim: version))
                    .ldLink(to: .about)
            }
            .ldStaggerRise(3)
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var advancedSummary: Text {
        switch (prefs.includeDailyTotals, prefs.clientCertificate != nil) {
        case (true, false): return Text("Daily totals")
        case (false, false): return Text("No daily totals")
        case (true, true): return Text("Daily totals, client certificate")
        case (false, true): return Text("No daily totals, client certificate")
        }
    }

    private var notificationsSummary: Text {
        prefs.failureNotificationsEnabled
            ? Text("After \(prefs.failureNotificationThreshold) failures")
            : Text("Off")
    }
}
