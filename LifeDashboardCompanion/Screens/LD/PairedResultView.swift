import SwiftUI

/// What the one ping after Pair found, inside PairingSheet: pairing has already been written by
/// then, so a failure here says the receiver did not answer, not that nothing changed.
struct PairedResultView: View {
    let link: PairingLink
    /// Nil while the ping is under way.
    let outcome: PairingPingOutcome?
    /// Taken when the sheet opened.
    let enabledTypes: Int
    /// During the first-run setup the next step is its own, and no page can open over it.
    let canPickTypes: Bool
    let onTryAgain: () -> Void
    let onPickTypes: () -> Void
    let onDone: () -> Void

    private var isDone: Bool {
        outcome?.isDone(at: link) ?? false
    }

    private var showsPickTypes: Bool {
        outcome != nil && enabledTypes == 0 && canPickTypes
    }

    private var pulse: PulseLine.Variant {
        guard outcome != nil else { return .flat }
        return isDone ? .normal : .warning
    }

    var body: some View {
        LDScreen(background: LDTheme.sheet) {
            if outcome == nil {
                LDHeading("Paired")
            } else if isDone {
                LDHeading("Connected.")
            } else {
                LDHeading("Not connected yet.")
            }
            PulseLine(variant: pulse)
                .id(pulse)

            Text(verbatim: link.host)
                .font(LDType.monoField)
                .foregroundStyle(LDTheme.text)
                .ldCode()
                .padding(.horizontal, LDTheme.textInset)
            if let outcome {
                LDNote(outcomeText(outcome), color: isDone ? LDTheme.accentTextSoft : LDTheme.warning, top: 4)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(LDTheme.accentTextSoft)
                    Text("Checking the connection...")
                        .font(LDType.note)
                        .foregroundStyle(LDTheme.secondary)
                }
                .padding(.top, 4)
                .padding(.horizontal, LDTheme.textInset)
            }
            // Not while it failed: the next step is then Try again.
            if outcome == nil || isDone {
                LDNote(enabledTypes > 0
                       ? "Tap Sync Now to send your data."
                       : "Next, switch on the data types you want to send.")
            }

            LDGap(16)
            if outcome != nil && !isDone {
                LDButton("Try again", action: onTryAgain)
                LDGap(8)
            }
            if showsPickTypes {
                LDButton("Pick what to send", kind: isDone ? .primary : .ghost, action: onPickTypes)
                LDGap(8)
            }
            LDButton("Done", kind: isDone && !showsPickTypes ? .primary : .ghost, action: onDone)
                .disabled(outcome == nil)
        }
    }

    private func outcomeText(_ outcome: PairingPingOutcome) -> Text {
        switch outcome {
        case .confirmed:
            // The name is the link's claim, cleaned and capped by PairingLinks, as on the confirm
            // screen. Home Assistant's own links are named "Home Assistant".
            if let name = link.name {
                return Text("\(name) confirmed the pairing.")
            }
            return Text("The receiver confirmed the pairing.")
        case .deliveredUnconfirmed:
            // Only Home Assistant answers 200 to a webhook it no longer knows; anywhere else a
            // plain 2xx is all the receiver says.
            return link.looksLikeHomeAssistant
                ? Text("Delivered, but the Life Dashboard integration did not answer. Check that the entry for this phone still exists.")
                : Text("Delivered: the receiver accepted the test ping.")
        case .refused:
            return Text("Test ping failed: the receiver refused the signature. Scan the code again.")
        case .failed(let reason):
            let shown = AppDiagnostic.display(reason)
            return link.reach == .homeNetwork
                ? Text("Test ping failed: \(shown). If iOS asked about the local network, allow it in Settings > Privacy & Security > Local Network.")
                : Text("Test ping failed: \(shown)")
        }
    }
}
