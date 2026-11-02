import SwiftUI

struct AddDestinationScreen: View {
    var body: some View {
        LDScreen(background: LDTheme.sheet) {
            LDHeading("Add a destination.")
        }
        .navigationTitle("Add destination")
        .ldSheetToolbar()
    }
}
