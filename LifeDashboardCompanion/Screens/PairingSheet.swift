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
    @EnvironmentObject private var navigator: LDNavigator
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboarding_completed") private var onboardingCompleted = false

    private enum Phase: Equatable {
        case confirm
        case checking
        case done(PairingPingOutcome)
    }

    @State private var phase: Phase = .confirm
    /// Taken when the sheet opens, so the lines do not flip once Pair has written.
    @State private var change: SectionChange
    @State private var enabledTypes: Int

    init(link: PairingLink) {
        self.link = link
        let prefs = PreferencesManager.shared
        _change = State(initialValue: PairingApply.preview(link, current: prefs.healthDestinations))
        _enabledTypes = State(initialValue: prefs.healthEnabledDataTypes.count)
        #if DEBUG
        // For screenshots: -ld.pairPhase opens the result, without writing or sending anything.
        switch UserDefaults.standard.string(forKey: "ld.pairPhase") {
        case "checking": _phase = State(initialValue: .checking)
        case "confirmed": _phase = State(initialValue: .done(.confirmed))
        case "unconfirmed": _phase = State(initialValue: .done(.deliveredUnconfirmed))
        case "refused": _phase = State(initialValue: .done(.refused))
        case "failed": _phase = State(initialValue: .done(.failed("HTTP 502")))
        default: break
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .confirm:
                    confirmContent
                case .checking:
                    result(nil)
                case .done(let outcome):
                    result(outcome)
                }
            }
            .navigationTitle(phase == .confirm ? "Pairing" : "Paired")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(LDTheme.sheet)
        .interactiveDismissDisabled(phase == .checking)
    }

    // MARK: - Confirm

    private var confirmContent: some View {
        LDScreen(background: LDTheme.sheet) {
            // A question without the link's name in it: the name reads as a claim, never as a title.
            LDHeading("Pair with this receiver?")
            Group {
                if let name = link.name {
                    LDNote(Text("\(name) wants to receive your data at:"), top: 10)
                } else {
                    LDNote("A receiver wants your data at:", top: 10)
                }
            }
            Text(verbatim: link.host)
                .font(LDType.monoField)
                .foregroundStyle(LDTheme.accentTextSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.horizontal, LDTheme.textInset)
            Text(verbatim: link.url)
                .font(LDType.monoValue)
                .foregroundStyle(LDTheme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
                .padding(.horizontal, LDTheme.textInset)

            LDGap(6)
            // Two lines can share an icon, so they are told apart by their place.
            ForEach(Array(changeLines.enumerated()), id: \.offset) { _, line in
                PairingChangeLine(line: line)
            }

            Group {
                if enabledTypes > 0 {
                    LDNote(Text("\(enabledTypes) data types are switched on and go here from the next sync."), top: 14)
                } else {
                    LDNote("No data types are switched on yet, so nothing is sent until you pick some.", top: 14)
                }
            }
            LDNote("Pairing only fills in the address and the secret. Which data types are sent, and when, stays your choice on the Health tab.", size: 13)

            LDGap(16)
            LDButton("Pair", action: pair)
                .disabled(link.reach == .blockedByATS)
            LDGap(8)
            LDButton("Cancel", kind: .ghost) { dismiss() }
        }
    }

    fileprivate struct Line {
        enum Tone { case plain, muted, warning }

        let text: LocalizedStringResource
        let icon: String
        let tone: Tone
    }

    private var changeLines: [Line] {
        var lines: [Line] = []
        if change.changesNothing {
            lines.append(Line(text: "Already paired. Nothing changes.", icon: "checkmark.circle", tone: .muted))
        } else if change.addsUrl {
            lines.append(Line(text: "Adds this address to your webhook URLs.", icon: "plus.circle", tone: .plain))
        }
        if change.replacesSecret {
            lines.append(Line(text: "Replaces the signing secret of this address.", icon: "key", tone: .plain))
        }
        // Since 1.10.0 every address has its own secret and headers, so a second receiver no
        // longer changes what the first one gets.
        if change.otherUrls > 0 && !change.changesNothing {
            lines.append(Line(text: "Your other addresses keep their own signing secret and headers.", icon: "checkmark.shield", tone: .muted))
        }
        switch link.reach {
        case .secure:
            break
        case .homeNetwork:
            lines.append(Line(
                text: "Plain HTTP, allowed for an address on your own network. Your data is not encrypted on the way, and it only arrives while the phone is at home or on a VPN.",
                icon: "house", tone: .muted))
        case .publicPlainHttp:
            lines.append(Line(
                text: "This address is on the internet without encryption. Anyone along the way can read your health data. Use an https address.",
                icon: "exclamationmark.triangle", tone: .warning))
        case .blockedByATS:
            lines.append(Line(
                text: link.looksLikeHomeAssistant
                    ? "iOS only allows plain HTTP to IP addresses and .local names. In Home Assistant, use Reconfigure on the integration with the IP address or an https address, and scan the new code."
                    : "iOS only allows plain HTTP to IP addresses and .local names. Make a new pairing code on the receiver with the IP address or an https address, and scan that.",
                icon: "xmark.octagon", tone: .warning))
        }
        return lines
    }

    // MARK: - Result

    private func result(_ outcome: PairingPingOutcome?) -> some View {
        PairedResultView(
            link: link,
            outcome: outcome,
            enabledTypes: enabledTypes,
            canPickTypes: onboardingCompleted,
            onTryAgain: { Task { await check() } },
            onPickTypes: {
                dismiss()
                navigator.dismissSheet { navigator.push(.whatToSend) }
            },
            onDone: { dismiss() }
        )
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
        guard let body = TestPing.body() else {
            phase = .done(.failed(AppDiagnostic.testPingNotBuilt.rawValue))
            return
        }
        let outcome = await WebhookManager.shared.probe(body: body, url: link.url, secret: link.secret)
        phase = .done(outcome)
    }
}

/// One line of what pairing would change. What the user has to act on gets the warning card.
private struct PairingChangeLine: View {
    let line: PairingSheet.Line

    var body: some View {
        switch line.tone {
        case .plain, .muted:
            Label { Text(line.text) } icon: { Image(systemName: line.icon) }
                .font(LDType.note)
                .foregroundStyle(line.tone == .plain ? LDTheme.text : LDTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.horizontal, LDTheme.textInset)
        case .warning:
            Label {
                Text(line.text).foregroundStyle(LDTheme.warningBody)
            } icon: {
                Image(systemName: line.icon).foregroundStyle(LDTheme.warning)
            }
            .font(LDType.note)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(LDTheme.warningSurface, in: RoundedRectangle(cornerRadius: LDTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LDTheme.cardRadius, style: .continuous)
                    .strokeBorder(LDTheme.warningBorder, lineWidth: 1)
            }
            .padding(.top, 10)
            .padding(.horizontal, LDTheme.cardInset)
        }
    }
}
