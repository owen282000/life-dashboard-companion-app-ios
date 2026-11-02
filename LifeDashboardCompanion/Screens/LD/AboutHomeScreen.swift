import SwiftUI

struct AboutHomeScreen: View {
    var body: some View {
        LDScreen {
            LDHeading("About")
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
