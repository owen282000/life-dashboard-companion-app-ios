import SwiftUI

struct ShortcutsHelpScreen: View {
    var body: some View {
        LDScreen(background: LDTheme.sheet) {
            LDHeading("Exact times with Shortcuts.")
        }
        .navigationTitle("Shortcuts")
        .ldSheetToolbar(cancel: "Done")
    }
}
