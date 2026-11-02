import SwiftUI

struct WebhookDestinationScreen: View {
    /// The webhook URL to edit, nil for a new one.
    let address: String?

    var body: some View {
        LDScreen(background: LDTheme.sheet) {
            LDHeading("Webhook")
        }
        .navigationTitle("Destination")
        .ldSheetToolbar(confirm: "Save")
    }
}
