import SwiftUI

struct PayloadPreviewScreen: View {
    var body: some View {
        LDScreen(background: LDTheme.sheet) {
            LDHeading("Preview payload")
        }
        .navigationTitle("Preview")
        .ldSheetToolbar(cancel: "Done")
    }
}
