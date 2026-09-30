import SwiftUI

/// The one road from a pairing link to the settings, whichever way the link arrived: the
/// in-app scanner, or a lifedashboard:// URL opened from the landing page. Lives at the root,
/// so the sheet shows over any tab and on a cold start.
@MainActor
final class PairingCoordinator: ObservableObject {
    struct Pending: Identifiable {
        let id = UUID()
        let link: PairingLink
    }

    @Published var scanning = false
    @Published var pending: Pending?
    @Published var problem: PairingProblem?
    /// Tells a screen with its own sheet open to close it: SwiftUI presents nothing from the
    /// root while a sheet further down is up.
    @Published private(set) var incoming = 0

    /// Held while the scanner closes; handed to the sheet once it has gone.
    private var scanned: PairingLink?

    func open(_ url: URL) {
        switch PairingLinks.parse(url.absoluteString) {
        case .link(let link):
            if scanning {
                scanned = link
                scanning = false
            } else {
                incoming += 1
                // One runloop for the other sheet to start closing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.pending = Pending(link: link)
                }
            }
        case .invalid(let problem):
            self.problem = problem
        case .notAPairingLink:
            break
        }
    }

    func startScan() {
        scanning = true
    }

    func scanned(_ link: PairingLink) {
        scanned = link
        scanning = false
    }

    func scannerDismissed() {
        guard let link = scanned else { return }
        scanned = nil
        pending = Pending(link: link)
    }
}

/// Where the user sees who is asking, at which address, and what pairing would change.
/// Nothing is written until Pair.
struct PairingSheet: View {
    let link: PairingLink

    @ObservedObject private var prefs = PreferencesManager.shared
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case confirm
        case checking
        case done(PairingPingOutcome)
    }

    @State private var phase: Phase = .confirm
    /// Taken when the sheet opens, so the lines do not flip once Pair has written.
    @State private var change: SectionChange
    @State private var hadHeaders: Bool
    @State private var enabledTypes: Int

    init(link: PairingLink) {
        self.link = link
        let prefs = PreferencesManager.shared
        _change = State(initialValue: PairingApply.preview(link, current: prefs.healthSection))
        _hadHeaders = State(initialValue: !prefs.healthWebhookHeaders.isEmpty)
        _enabledTypes = State(initialValue: prefs.healthEnabledDataTypes.count)
    }

    var body: some View {
        NavigationStack {
            Form {
                if phase == .confirm {
                    confirmContent
                } else {
                    resultContent
                }
            }
            .navigationTitle(phase == .confirm ? "Pairing" : "Paired")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(phase == .checking)
    }

    // MARK: - Confirm

    @ViewBuilder
    private var confirmContent: some View {
        Section {
            // The name is whatever the link says, so it reads as a claim, never as a title.
            Group {
                if let name = link.name {
                    Text("\(name) wants to receive your data at:")
                } else {
                    Text("A receiver wants your data at:")
                }
            }
                .font(.subheadline)
            Text(link.host)
                .font(.system(.title3, design: .monospaced))
            Text(link.url)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }

        Section {
            // Two lines can share an icon, so they are told apart by their place.
            ForEach(Array(changeLines.enumerated()), id: \.offset) { _, line in
                Label { Text(line.text) } icon: { Image(systemName: line.icon) }
                    .font(.subheadline)
                    .foregroundColor(line.color)
            }
        }

        Section {
            Group {
                if enabledTypes > 0 {
                    Text("\(enabledTypes) data types are switched on and go here from the next sync.")
                } else {
                    Text("No data types are switched on yet, so nothing is sent until you pick some.")
                }
            }
                .font(.subheadline)
            Text("Pairing only fills in the address and the secret. Which data types are sent, and when, stays your choice on the Health tab.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private struct Line {
        let text: LocalizedStringResource
        let icon: String
        let color: Color
    }

    private var changeLines: [Line] {
        var lines: [Line] = []
        if change.changesNothing {
            lines.append(Line(text: "Already paired. Nothing changes.", icon: "checkmark.circle", color: .secondary))
        } else if change.addsUrl {
            lines.append(Line(text: "Adds this address to your webhook URLs.", icon: "plus.circle", color: .primary))
        }
        if change.replacesSecret {
            lines.append(change.otherUrls > 0
                ? Line(text: "Replaces the signing secret for all your webhook URLs. A receiver that checks the old one will refuse your data.",
                       icon: "exclamationmark.triangle", color: .orange)
                : Line(text: "Replaces the signing secret.", icon: "key", color: .primary))
        }
        switch link.reach {
        case .secure:
            break
        case .homeNetwork:
            lines.append(Line(
                text: "Plain HTTP, allowed for an address on your own network. Your data is not encrypted on the way, and it only arrives while the phone is at home or on a VPN.",
                icon: "house", color: .secondary))
        case .publicPlainHttp:
            lines.append(Line(
                text: "This address is on the internet without encryption. Anyone along the way can read your health data. Use an https address.",
                icon: "exclamationmark.triangle", color: .orange))
        case .blockedByATS:
            lines.append(Line(
                text: "iOS only allows plain HTTP to IP addresses and .local names. In Home Assistant, use Reconfigure on the integration with the IP address or an https address, and scan the new code.",
                icon: "xmark.octagon", color: .red))
        }
        if hadHeaders && change.addsUrl {
            lines.append(Line(text: "Your custom headers are not sent to this address.", icon: "doc.text", color: .secondary))
        }
        return lines
    }

    // MARK: - Result

    @ViewBuilder
    private var resultContent: some View {
        Section {
            Text(link.host)
                .font(.system(.body, design: .monospaced))
            switch phase {
            case .done(let outcome):
                Label { outcomeText(outcome) } icon: { Image(systemName: outcome == .confirmed ? "checkmark.circle.fill" : "exclamationmark.circle") }
                    .foregroundColor(outcome == .confirmed ? .green : .orange)
                    .font(.subheadline)
                if outcome != .confirmed {
                    Button("Try again") { Task { await check() } }
                }
            default:
                HStack {
                    ProgressView()
                    Text("Checking the connection...")
                        .font(.subheadline)
                }
            }
        }
        Section {
            Text(enabledTypes > 0
                 ? "Tap Sync Now to send your data."
                 : "Next, switch on the data types you want to send.")
                .font(.subheadline)
        }
    }

    private func outcomeText(_ outcome: PairingPingOutcome) -> Text {
        switch outcome {
        case .confirmed:
            return Text("Home Assistant confirmed the pairing.")
        case .deliveredUnconfirmed:
            return Text("Delivered, but the Life Dashboard integration did not answer. Check that the entry for this phone still exists.")
        case .refused:
            return Text("Test ping failed: the receiver refused the signature. Scan the code again.")
        case .failed(let reason):
            let shown = AppDiagnostic.display(reason)
            return link.reach == .homeNetwork
                ? Text("Test ping failed: \(shown). If iOS asked about the local network, allow it in Settings > Privacy & Security > Local Network.")
                : Text("Test ping failed: \(shown)")
        }
    }

    // MARK: - Actions

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Between two text buttons the bar leaves little room: on a small iPhone with large
        // text even one word is cut, so the title shrinks a little before it is shortened.
        ToolbarItem(placement: .principal) {
            Text(phase == .confirm ? "Pairing" : "Paired")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
        }
        if phase == .confirm {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Pair") { pair() }
                    .disabled(link.reach == .blockedByATS)
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .disabled(phase == .checking)
            }
        }
    }

    private func pair() {
        let wasEmpty = prefs.healthWebhookUrls.isEmpty
        prefs.applyPairing(link)

        // At launch AppDelegate sets up background delivery only when an address exists, so a
        // first address that arrives by pairing has to do it here.
        if wasEmpty && !prefs.healthEnabledDataTypes.isEmpty {
            BackgroundSyncManager.shared.setupHealthKitObservers()
            BackgroundSyncManager.shared.replan()
        }

        Task { await check() }
    }

    /// One ping to the new address, in the foreground: it is also when iOS asks about the local
    /// network, which a background sync cannot do.
    private func check() async {
        phase = .checking
        let payload: [String: Any] = [
            "test": true,
            "message": "Test ping from Life Dashboard Companion",
            "timestamp": Date().iso8601String,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "source": "healthkit_ios"
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            phase = .done(.failed(AppDiagnostic.testPingNotBuilt.rawValue))
            return
        }
        let outcome = await WebhookManager.shared.probe(body: body, url: link.url, secret: link.secret)
        phase = .done(outcome)
    }
}
