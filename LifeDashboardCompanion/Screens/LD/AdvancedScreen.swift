import SwiftUI

struct AdvancedScreen: View {
    var body: some View {
        LDScreen {
            LDHeading("Advanced")
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
    }
}
