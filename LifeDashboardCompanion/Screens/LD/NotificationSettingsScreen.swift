import SwiftUI

struct NotificationSettingsScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared

    var body: some View {
        LDScreen {
            LDHeading("Notifications")
            LDGap(12)
            LDCard {
                LDToggleRow("Notify after failed syncs", isOn: Binding(
                    get: { prefs.failureNotificationsEnabled },
                    set: { enabled in
                        prefs.failureNotificationsEnabled = enabled
                        if enabled {
                            SyncFailureNotifier.shared.requestFullAuthorization()
                        }
                    }
                ))
            }
            .ldStaggerRise(0)

            if prefs.failureNotificationsEnabled {
                LDSectionLabel("After consecutive failures")
                LDSegmented(selection: $prefs.failureNotificationThreshold, segments: [
                    LDSegment(3, title: Text(verbatim: "3")),
                    LDSegment(5, title: Text(verbatim: "5")),
                    LDSegment(10, title: Text(verbatim: "10"))
                ], label: "Failure threshold")
                .ldStaggerRise(1)
                LDNote("You also hear about it when not every destination gets your data, and when data was lost.", top: 10, size: 13)
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}
