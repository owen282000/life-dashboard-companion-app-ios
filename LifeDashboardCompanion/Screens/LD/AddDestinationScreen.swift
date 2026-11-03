import SwiftUI

/// Where a destination starts: a pairing code, an address typed by hand, or the MQTT broker. The
/// next step is a screen of its own, so each row closes this sheet first.
struct AddDestinationScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared
    @EnvironmentObject private var navigator: LDNavigator
    @EnvironmentObject private var pairing: PairingCoordinator

    @State private var address = ""
    @State private var problem: WebhookAddress.Problem?

    var body: some View {
        LDScreen(background: LDTheme.sheet) {
            LDHeading("Add a destination.")
            LDGap(12)
            LDButton("Scan a pairing code") {
                navigator.dismissSheet { pairing.startScan() }
            }
            LDNote("For any receiver that shows one, such as Home Assistant, the Life Dashboard Stack or your own server.")

            LDSectionLabel("Your own server")
            LDCard {
                LDFieldRow("Webhook URL", text: $address, verbatimPrompt: WebhookAddress.example)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: address) { problem = nil }
                if let problem {
                    DestinationFieldError(message: Text(problem.message))
                }
            }
            LDGap(10)
            LDButton("Add webhook", kind: .ghost, action: addWebhook)
                .disabled(trimmedAddress.isEmpty)

            LDSectionLabel("MQTT")
            LDCard {
                LDRow("MQTT broker", subtitle: Text("With Home Assistant Discovery"), value: mqttStatus)
                    .ldButton {
                        navigator.dismissSheet { navigator.present(.mqttDestination) }
                    }
            }
        }
        .navigationTitle("Add destination")
        .ldSheetToolbar()
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var mqttStatus: Text {
        guard prefs.mqttEnabled else { return Text("Off") }
        let host = prefs.mqttHost.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? Text("On: no broker set") : Text("On: \(host)")
    }

    /// Listed right away, as before this sheet existed, so Send test works on the next screen.
    private func addWebhook() {
        let url = trimmedAddress
        if let found = WebhookAddress.problem(url, listed: prefs.healthWebhookUrls) {
            problem = found
            AccessibilityNotification.Announcement(String(localized: found.message)).post()
            return
        }
        prefs.addTypedHealthWebhookUrl(url)
        navigator.dismissSheet { navigator.present(.webhookDestination(address: url)) }
    }
}

/// An address typed by hand: what a pairing code's address has to be, and what iOS would refuse on
/// every request anyway.
enum WebhookAddress {
    static let example = "https://your-webhook.com/health"

    enum Problem: Equatable {
        case notAnAddress
        case blockedByATS
        case alreadyListed

        var message: LocalizedStringResource {
            switch self {
            case .notAnAddress:
                return "Enter a full address that starts with https:// or http://."
            case .blockedByATS:
                return "iOS only allows plain HTTP to IP addresses and .local names. Use an IP address or an https address."
            case .alreadyListed:
                return "This address is already on your list."
            }
        }
    }

    static func problem(_ text: String, listed: [String]) -> Problem? {
        guard isUsable(text) else { return .notAnAddress }
        if listed.contains(text) { return .alreadyListed }
        return PairingReach.of(text) == .blockedByATS ? .blockedByATS : nil
    }

    /// The same rules as PairingLinks for the address in a code.
    private static func isUsable(_ url: String) -> Bool {
        guard url.utf16.count <= PairingLinks.maxUrl,
              !url.contains(where: { $0.isWhitespace || $0 == "," }),
              let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              host.allSatisfy(\.isASCII)
        else { return false }
        return true
    }
}

/// The line under a field that says what is wrong with it, as a row of its card.
struct DestinationFieldError: View {
    let message: Text

    var body: some View {
        Label {
            message
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(LDType.rowSubtitle)
        .foregroundStyle(LDTheme.warning)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
    }
}
