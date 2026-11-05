import SwiftUI

struct AboutHelpScreen: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

    var body: some View {
        LDScreen {
            LDHeading("Help")
            LDGap(12)
            LDCard {
                AboutLinkRow("Setup guide", value: Text("Website"), url: AboutLinks.website)
                AboutLinkRow("Documentation", value: Text(verbatim: "GitHub"), url: AboutLinks.documentation)
                AboutLinkRow("What's new", value: Text(verbatim: version), url: AboutLinks.changelog)
                AboutLinkRow("Report a problem", url: AboutLinks.feedback)
                AboutLinkRow("Questions", value: Text("Mail"), url: AboutLinks.support)
            }
            .ldStaggerRise()
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
