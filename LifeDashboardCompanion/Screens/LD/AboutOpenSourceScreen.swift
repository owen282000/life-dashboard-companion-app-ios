import SwiftUI

struct AboutOpenSourceScreen: View {
    var body: some View {
        LDScreen {
            LDHeading("Open source")
            LDNote("You can read every line this app runs.", top: 6)
            LDGap(12)
            LDCard {
                AboutLinkRow("View on GitHub", url: AboutLinks.repository)
                AboutLinkRow("Licence", value: Text(verbatim: "MIT"), url: AboutLinks.licence)
                AboutLinkRow("Website", url: AboutLinks.website)
            }
            .ldStaggerRise()
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
