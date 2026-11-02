import SwiftUI

struct MqttDestinationScreen: View {
    var body: some View {
        LDScreen(background: LDTheme.sheet) {
            LDHeading("MQTT broker")
        }
        .navigationTitle("MQTT")
        .ldSheetToolbar(confirm: "Save")
    }
}
