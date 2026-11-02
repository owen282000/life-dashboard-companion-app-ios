import SwiftUI

struct BackfillScreen: View {
    /// Choosing a length is a sheet, the running backfill a pushed page (`LDRoute.backfillRun`).
    enum Stage {
        case choose, running
    }

    let stage: Stage

    var body: some View {
        switch stage {
        case .choose:
            LDScreen(background: LDTheme.sheet) {
                LDHeading("Backfill")
            }
            .navigationTitle("Backfill")
            .ldSheetToolbar()
        case .running:
            LDScreen {
                LDHeading("Backfill")
            }
            .navigationTitle("Backfill")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
