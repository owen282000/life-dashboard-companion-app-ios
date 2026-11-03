import SwiftUI

/// One address's own signing secret and headers (P2-13), as Android's address dialog since 1.28.0.
/// Generate and the copies from another address are offered only while the field is empty, so
/// nothing typed is overwritten by a tap. Saved as a whole, or not at all.
struct WebhookDestinationScreen: View {
    /// The webhook URL to edit, nil for a new one.
    let address: String?

    @ObservedObject private var prefs = PreferencesManager.shared
    @EnvironmentObject private var navigator: LDNavigator

    @State private var destination: WebhookDestination
    /// Not on the list yet: the URL can still be typed, and Save adds it.
    private let isNew: Bool

    @State private var isSecretRevealed = false
    @State private var copyOutcome: PayloadCopy.Outcome?

    @State private var showsHeaderForm = false
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var headerProblem: SettingsValidation.HeaderProblem?
    @FocusState private var keyFocused: Bool

    @State private var lastRow: WebhookLog?
    @State private var isTesting = false
    @State private var testDelivered: Bool?
    @State private var showRemoveConfirm = false

    init(address: String?) {
        self.address = address
        let prefs = PreferencesManager.shared
        let listed = prefs.healthDestinations.first { $0.url == address }
        isNew = listed == nil
        _destination = State(initialValue: listed ?? WebhookDestination(
            id: UUID().uuidString.lowercased(),
            url: address ?? "",
            secret: prefs.healthSigningSecret,
            headers: [:]
        ))
    }

    var body: some View {
        LDScreen(background: LDTheme.sheet) {
            if isNew {
                LDHeading("Webhook")
            } else {
                LDHeading(Text(verbatim: destination.host))
                deliveryLine
            }
            addressSection
            signingSection
            headersSection
            if !isNew {
                actions
            }
        }
        .navigationTitle("Destination")
        .ldSheetToolbar(confirm: "Save", canConfirm: addressProblem == nil, onConfirm: save)
        .task { await loadLastRow() }
        .confirmationDialog("Remove destination", isPresented: $showRemoveConfirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This address stops receiving data, and its signing secret and headers are deleted.")
        }
    }

    // MARK: - Delivered

    /// The last row in the log for this address. A sync cut off by iOS says nothing about it.
    private func loadLastRow() async {
        let url = destination.url
        lastRow = await Task.detached(priority: .utility) {
            LogStore.shared.load().first { $0.url == url && $0.syncKind == .webhook && !$0.isInterrupted }
        }.value
    }

    @ViewBuilder
    private var deliveryLine: some View {
        if let row = lastRow {
            let when = row.timestamp.formatted(.relative(presentation: .named))
            if row.success {
                LDNote(deliveredText(when: when, records: row.recordCount ?? 0), color: LDTheme.accentTextSoft, top: 4)
            } else if let reason = row.errorMessage {
                LDNote(Text("Last try failed \(when): \(AppDiagnostic.display(reason))"), color: LDTheme.warning, top: 4)
            } else {
                LDNote(Text("Last try failed \(when)."), color: LDTheme.warning, top: 4)
            }
        }
    }

    private func deliveredText(when: String, records: Int) -> Text {
        switch records {
        case 0: return Text("Delivered \(when).")
        case 1: return Text("Delivered \(when), 1 record.")
        default: return Text("Delivered \(when), \(records) records.")
        }
    }

    // MARK: - Address

    private var trimmedAddress: String {
        destination.url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var addressProblem: WebhookAddress.Problem? {
        isNew ? WebhookAddress.problem(trimmedAddress, listed: prefs.healthWebhookUrls) : nil
    }

    @ViewBuilder
    private var addressSection: some View {
        LDSectionLabel("Address")
        LDCard {
            if isNew {
                LDFieldRow("URL", text: $destination.url, verbatimPrompt: WebhookAddress.example)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if let addressProblem, !trimmedAddress.isEmpty {
                    DestinationFieldError(message: Text(addressProblem.message))
                }
            } else {
                LDFieldRow("URL", value: Text(verbatim: destination.url))
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Signing

    private var others: [WebhookDestination] {
        prefs.healthDestinations.filter { $0.id != destination.id }
    }

    @ViewBuilder
    private var signingSection: some View {
        LDSectionLabel("Signing")
        LDCard {
            LDFieldRow(
                "HMAC Signing Secret",
                text: Binding(
                    get: { destination.secret },
                    set: { destination.secret = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                ),
                prompt: "Optional secret for X-Signature",
                isSecure: !isSecretRevealed
            ) {
                DestinationRevealButton(isRevealed: $isSecretRevealed)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: destination.secret) { copyOutcome = nil }

            if destination.secret.isEmpty {
                LDRow("Generate", showsChevron: false)
                    .ldButton { destination.secret = WebhookDestinations.generatedSecret() }
                let signed = others.filter { !$0.secret.isEmpty }
                if !signed.isEmpty {
                    Menu {
                        ForEach(signed) { other in
                            Button { destination.secret = other.secret } label: { Text(verbatim: other.host) }
                        }
                    } label: {
                        LDRow("Use the secret of another address", showsChevron: false)
                    }
                }
            } else {
                LDRow("Copy secret", showsChevron: false)
                    .ldButton(action: copySecret)
            }
        }
        if let copyOutcome {
            LDNote(Text(verbatim: copyOutcome.message), color: LDTheme.accentTextSoft, size: 13)
        }
        LDNote("When set, every request includes X-Signature: sha256=HMAC-SHA256(secret, body) so your server can verify the sender.", size: 13)
    }

    private func copySecret() {
        let outcome = PayloadCopy.copy(destination.secret)
        copyOutcome = outcome
        AccessibilityNotification.Announcement(outcome.message).post()
    }

    // MARK: - Headers

    @ViewBuilder
    private var headersSection: some View {
        LDSectionLabel("Custom Headers")
        LDCard {
            ForEach(destination.headers.keys.sorted(), id: \.self) { key in
                DestinationHeaderRow(name: key, value: destination.headers[key] ?? "") {
                    destination.headers.removeValue(forKey: key)
                }
            }
            if showsHeaderForm {
                LDFieldRow("Key", text: $newKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($keyFocused)
                    .onChange(of: newKey) { headerProblem = nil }
                LDFieldRow("Value", text: $newValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: newValue) { headerProblem = nil }
                if let headerProblem {
                    DestinationFieldError(message: Text(verbatim: headerProblem.message))
                }
                let canAdd = !newKey.trimmingCharacters(in: .whitespaces).isEmpty
                LDRow("Add", showsChevron: false)
                    .ldButton(action: addHeader)
                    .disabled(!canAdd)
            } else {
                LDRow("Add a header", showsChevron: false)
                    .ldButton {
                        showsHeaderForm = true
                        keyFocused = true
                    }
            }
            let withHeaders = others.filter { !$0.headers.isEmpty }
            if destination.headers.isEmpty && !withHeaders.isEmpty {
                Menu {
                    ForEach(withHeaders) { other in
                        Button { destination.headers = other.headers } label: { Text(verbatim: other.host) }
                    }
                } label: {
                    LDRow("Use the headers of another address", showsChevron: false)
                }
            }
        }
        LDNote("Sent to this address only. Swipe a header to remove it.", size: 13)
    }

    /// A header goes in only when iOS would send it as typed; otherwise the line under the
    /// fields says why, and what was typed stays to be corrected.
    private func addHeader() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = SettingsValidation.headerProblem(name: key, value: value, existing: destination.headers) {
            headerProblem = found
            AccessibilityNotification.Announcement(found.message).post()
            return
        }
        destination.headers[key] = value
        newKey = ""
        newValue = ""
        showsHeaderForm = false
    }

    // MARK: - Test and remove

    /// A delivery reads the secret and headers from storage, so a test cannot use what is only
    /// typed here yet.
    private var hasUnsavedChanges: Bool {
        prefs.healthDestinations.first { $0.id == destination.id } != destination
    }

    @ViewBuilder
    private var actions: some View {
        LDGap(12)
        LDButton(isTesting ? Text("Sending...") : Text("Send test"), kind: .ghost, isBusy: isTesting, action: sendTest)
        if hasUnsavedChanges {
            LDNote("The test uses what is saved. Save first to test your changes.", size: 13)
        }
        if let testDelivered {
            LDNote(
                testDelivered ? Text("Test ping delivered") : Text("Test ping failed, check the logs"),
                color: testDelivered ? LDTheme.accentTextSoft : LDTheme.warning
            )
        }
        LDGap(8)
        LDButton("Remove destination", kind: .danger) { showRemoveConfirm = true }
    }

    /// The Test ping of TestPing, to this address alone.
    private func sendTest() {
        guard let body = TestPing.body() else {
            testDelivered = false
            return
        }
        isTesting = true
        testDelivered = nil
        Task {
            let delivery = await WebhookManager.shared.post(
                body: body,
                urls: [destination.url],
                logType: .healthConnect,
                dataType: "test",
                recordCount: 0
            )
            isTesting = false
            testDelivered = delivery.delivered
            AccessibilityNotification.Announcement(
                delivery.delivered ? String(localized: "Test ping delivered") : String(localized: "Test ping failed, check the logs")
            ).post()
            await loadLastRow()
        }
    }

    private func save() {
        guard isNew else {
            prefs.updateDestination(destination)
            return
        }
        let url = trimmedAddress
        prefs.addTypedHealthWebhookUrl(url)
        guard var added = prefs.healthDestinations.first(where: { $0.url == url }) else { return }
        added.secret = destination.secret
        added.headers = destination.headers
        prefs.updateDestination(added)
    }

    private func remove() {
        prefs.healthWebhookUrls.removeAll { $0 == destination.url }
        navigator.dismissSheet()
    }
}

/// The eye in a secret's field. It starts hidden, and hides again when the screen goes.
struct DestinationRevealButton: View {
    @Binding var isRevealed: Bool

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
                .foregroundStyle(LDTheme.muted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.ldPress)
        .accessibilityLabel(isRevealed ? Text("Hide password") : Text("Show password"))
    }
}

/// A header with its value masked until tapped, since it often holds an API key. A swipe either
/// way shows Delete: a card is no List, so it has no swipe of its own, and this way the row needs
/// no care for right-to-left languages.
private struct DestinationHeaderRow: View {
    let name: String
    let value: String
    let onDelete: () -> Void

    private static let deleteWidth: CGFloat = 84

    @State private var isValueShown = false
    @State private var isOpen = false
    @State private var dragged: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isInvalid: Bool {
        SettingsValidation.firstInvalidHeader([name: value]) != nil
    }

    /// The first word stays readable: "Bearer" says what kind of value it is.
    private var maskedValue: String {
        let parts = value.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? "\(parts[0]) ••••" : "••••"
    }

    private var revealed: CGFloat {
        min(Self.deleteWidth, isOpen ? Self.deleteWidth - dragged : dragged)
    }

    var body: some View {
        LDRow(
            Text(verbatim: name),
            subtitle: isInvalid
                ? Text("Not a valid header, so nothing is sent. Remove it and add it again.").foregroundColor(LDTheme.warning)
                : nil,
            value: Text(verbatim: isValueShown ? value : maskedValue),
            showsChevron: false
        )
        .ldButton { isValueShown.toggle() }
        .accessibilityHint(Text("Shows or hides the value"))
        .accessibilityAction(named: Text("Delete"), onDelete)
        .padding(.trailing, max(0, revealed))
        .overlay(alignment: .trailing) {
            if revealed > 0 {
                Button(action: onDelete) {
                    Text("Delete")
                        .font(LDType.row)
                        .foregroundStyle(LDTheme.warning)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: revealed)
                        .frame(maxHeight: .infinity)
                        .background(LDTheme.warningSurface)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.ldPress)
                .clipped()
                .accessibilityHidden(true)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { drag in
                    guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                    dragged = abs(drag.translation.width)
                }
                .onEnded { _ in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        if dragged > Self.deleteWidth / 2 { isOpen.toggle() }
                        dragged = 0
                    }
                }
        )
    }
}
