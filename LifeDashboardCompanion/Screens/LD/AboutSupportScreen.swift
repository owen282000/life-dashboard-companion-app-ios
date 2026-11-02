import SwiftUI

struct AboutSupportScreen: View {
    var body: some View {
        LDScreen {
            LDHeading("Support")
            LDNote("A rating or a star helps other people find the app.", top: 6)
            LDGap(12)
            LDCard {
                AboutLinkRow("Rate the app", value: Text(verbatim: "App Store"), url: AboutLinks.rate)
                AboutLinkRow("Star on GitHub", url: AboutLinks.repository)
            }
            .ldStaggerRise()
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
