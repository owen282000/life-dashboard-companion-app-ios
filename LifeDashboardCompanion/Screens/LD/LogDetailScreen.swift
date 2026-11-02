import SwiftUI

struct LogDetailScreen: View {
    /// WebhookLog.id of the row to show.
    let logID: String

    var body: some View {
        LDScreen {
            LDHeading("Delivery")
        }
        .navigationTitle("Delivery")
        .navigationBarTitleDisplayMode(.inline)
    }
}
