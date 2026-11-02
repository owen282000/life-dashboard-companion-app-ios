import SwiftUI

struct AboutPrivacyScreen: View {
    var body: some View {
        LDScreen {
            LDHeading("Privacy")
            LDNote(Text(PrivacyPolicyText.intro), top: 6)

            section("What the app reads", PrivacyPolicyText.reads)
            section("What the app writes", PrivacyPolicyText.writes)
            section("Permissions", PrivacyPolicyText.permissions)
            section("Where it goes", PrivacyPolicyText.destinations)
            section("What the developer can receive", PrivacyPolicyText.developer)
            section("What stays on this iPhone", PrivacyPolicyText.stays)
            section("Your control", PrivacyPolicyText.control)
            section("Controller and contact", PrivacyPolicyText.contact)

            LDGap(16)
            Link("Read the full privacy policy", destination: AboutLinks.privacy)
                .buttonStyle(LDButtonStyle(.ghost))
                .padding(.horizontal, LDTheme.cardInset)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Markdown, for the links in the contact section.
    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ text: LocalizedStringResource) -> some View {
        LDSectionLabel(title)
        LDNote(Text(AttributedString(localized: text)), top: 0)
            .tint(LDTheme.accentText)
    }
}
