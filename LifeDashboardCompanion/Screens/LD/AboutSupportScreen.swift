import SwiftUI

struct AboutSupportScreen: View {
    // The tip link is Debug only, but its text stays out of the #if: an export for translation
    // reads a Release build and would drop anything inside it.
    private static let tipTitle: LocalizedStringKey = "Buy me a coffee"
    private static let tipSubtitle: LocalizedStringResource = "The app stays free and open source; a coffee keeps releases quick"

    var body: some View {
        LDScreen {
            LDHeading("Support")
            LDNote("A rating or a star helps other people find the app.", top: 6)
            LDGap(12)
            LDCard {
                AboutLinkRow("Rate the app", value: Text(verbatim: "App Store"), url: AboutLinks.rate)
                AboutLinkRow("Star on GitHub", url: AboutLinks.repository)
                #if DEBUG
                // Only in builds run from Xcode, the iOS counterpart of the Android app's F-Droid and
                // GitHub builds. An archive for TestFlight or the App Store is a Release build and has
                // no tip link, which App Review would refuse outside the US (guideline 3.1.1).
                AboutLinkRow(Self.tipTitle, subtitle: Text(Self.tipSubtitle), url: AboutLinks.tip)
                #endif
            }
            .ldStaggerRise()
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
