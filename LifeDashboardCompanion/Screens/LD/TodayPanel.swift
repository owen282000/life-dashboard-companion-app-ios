import SwiftUI

/// A panel inside HomeScreen's scroll view, so it has no LDScreen of its own.
struct TodayPanel: View {
    var body: some View {
        LDSectionLabel("Today")
    }
}
