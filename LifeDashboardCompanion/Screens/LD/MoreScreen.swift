import SwiftUI

struct MoreScreen: View {
    var body: some View {
        LDScreen {
            LDHeading("More")
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
    }
}
