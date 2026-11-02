import SwiftUI

struct AboutHelpScreen: View {
    var body: some View {
        LDScreen {
            LDHeading("Help")
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
