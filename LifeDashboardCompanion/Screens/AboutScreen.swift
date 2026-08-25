import SwiftUI

struct AboutScreen: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.accentColor)
                        .accessibilityHidden(true)
                    Text("Life Dashboard Companion")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Version \(version) (\(build))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)

                VStack(alignment: .leading, spacing: 12) {
                    Label("Privacy", systemImage: "lock.fill")
                        .font(.headline)
                    Text("This app does not collect any data itself. Health data goes only to the webhook URLs you configure, and settings stay on this device. Webhook secrets are stored in the iOS Keychain.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                VStack(alignment: .leading, spacing: 12) {
                    Label("Links", systemImage: "link")
                        .font(.headline)
                    Link(destination: URL(string: "https://github.com/owen282000/life-dashboard-companion-app-ios")!) {
                        Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.subheadline)
                    }
                    Link(destination: URL(string: "https://github.com/owen282000/life-dashboard-companion-app")!) {
                        Label("Android companion app", systemImage: "candybarphone")
                            .font(.subheadline)
                    }
                    Link(destination: URL(string: "https://github.com/owen282000/life-dashboard-companion-app-ios/blob/main/LICENSE")!) {
                        Label("MIT License", systemImage: "doc.text")
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                Text("Made by Owen Vogelaar for the self-hosted and quantified self community.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .padding()
        }
    }
}
