import SwiftUI

struct AboutNerdStatsScreen: View {
    var body: some View {
        LDScreen {
            LDHeading("You found the secret.")
        }
        .navigationTitle("Nerd Stats")
        .navigationBarTitleDisplayMode(.inline)
    }
}
