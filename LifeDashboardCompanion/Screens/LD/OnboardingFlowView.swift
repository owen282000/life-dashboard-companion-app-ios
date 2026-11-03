import SwiftUI

/// What the setup and the gate in ContentView share, and the essentials What to send offers too.
enum OnboardingView {
    enum Step: Int, CaseIterable {
        case welcome, destination, types, access, done
    }

    enum TypeChoice {
        case essentials, all, later
    }

    /// The types a new user most often wants: activity, sleep, heart and weight.
    static let essentials: Set<HealthDataType> = [
        .steps, .distance, .activeCalories, .sleep, .heartRate, .restingHeartRate, .weight, .exercise
    ]

    /// A fresh install has nowhere to send to and no type on. Anything else is an upgrade or a
    /// restored backup, which never sees the setup.
    static func isFreshInstall(webhookUrls: [String], mqttHost: String, enabledTypes: Set<HealthDataType>) -> Bool {
        webhookUrls.isEmpty && mqttHost.trimmingCharacters(in: .whitespaces).isEmpty && enabledTypes.isEmpty
    }
}

/// The first-run setup, boards On1 to On5: what the app does, where the data goes, which types,
/// Apple Health access with a first sync that shows it works, and a summary. Only a fresh install
/// sees it; every step can be skipped, and it writes only the settings Home writes too. ContentView
/// decides when it shows and brings back a setup left halfway. The scanner and the pairing sheet
/// hang on ContentView as well, so they come back here with the step and the fields untouched.
struct OnboardingFlowView: View {
    private typealias Step = OnboardingView.Step
    private typealias TypeChoice = OnboardingView.TypeChoice

    let onFinish: () -> Void

    @ObservedObject private var prefs = PreferencesManager.shared
    @EnvironmentObject private var pairing: PairingCoordinator

    @State private var step = Step.welcome
    @State private var travel = LDTabDirection.forward
    @State private var webhookUrl = ""
    @State private var webhookProblem: WebhookProblem?
    @State private var mqttHost = ""
    @State private var mqttHostProblem: SettingsValidation.BrokerProblem?
    @State private var showsMqttField = false
    @State private var typeChoice: TypeChoice?
    @State private var isPinging = false
    @State private var pingOutcome: SyncOutcome?
    @State private var accessAsked = false
    @State private var isFirstSyncing = false
    @State private var firstSync: SyncOutcome?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private static let topAnchor = "onboarding.top"

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        #if DEBUG
        // For screenshots: -ld.step 2 opens the third step.
        _step = State(initialValue: Step(rawValue: UserDefaults.standard.integer(forKey: "ld.step")) ?? .welcome)
        #endif
    }

    var body: some View {
        ScrollViewReader { scroll in
            LDScreen {
                topBar.id(Self.topAnchor)
                pulse
                // A ZStack, so the leaving step and the entering step share the same place.
                ZStack(alignment: .topLeading) {
                    currentStep
                        .id(step)
                        .transition(stepTransition)
                }
            } footer: {
                footer
            }
            .onChange(of: step) {
                scroll.scrollTo(Self.topAnchor, anchor: .top)
                // Back at the top of the new step: VoiceOver would stay on the button that was tapped.
                AccessibilityNotification.ScreenChanged().post()
            }
        }
    }

    private var currentStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .welcome: welcome
            case .destination: destination
            case .types: types
            case .access: access
            case .done: done
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Top

    private var topBar: some View {
        HStack {
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                .font(LDType.mono(12.5))
                .foregroundStyle(LDTheme.muted)
            Spacer(minLength: 8)
            if step != .done {
                LDTextButton("Skip setup", action: finish)
            }
        }
        .padding(.horizontal, LDTheme.textInset)
        .frame(minHeight: 48)
    }

    /// The line is the progress. Up to the last step PulseProgress draws further; only then comes
    /// the full mark with its arcs, as Home shows it. One PulseProgress stays alive throughout, so
    /// Back draws the line back as well.
    private var pulse: some View {
        let last = Step.allCases.count
        return ZStack {
            PulseProgress(step: min(step.rawValue + 1, last - 1), of: last)
                .opacity(step == .done ? 0 : 1)
            if step == .done {
                PulseLine()
            }
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            LDHeading("Your health data, your server.")
            LDNote("Send Apple Health to your own Home Assistant or server. No account, no cloud.", color: LDTheme.inactive, top: 10, size: 16)
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 0) {
            LDHeading("Where should your data go?")
            LDGap(14)
            LDButton("Scan a pairing code") {
                pairing.startScan()
            }
            LDNote("For any receiver that shows one, such as Home Assistant, the Life Dashboard Stack or your own server.", size: 13)
            if !prefs.healthUrlsWithoutHeaders.isEmpty {
                LDNote("Paired", color: LDTheme.accentTextSoft, top: 4, size: 13)
            }

            LDSectionLabel("Or your own server")
            webhookCard
            if let webhookProblem {
                LDNote(Text(verbatim: webhookProblem.message), color: LDTheme.warning, size: 13)
            }
            if let pingOutcome {
                LDNote(pingOutcome.text, color: resultColor(pingOutcome.tone), size: 13)
            }
            LDGap(8)
            mqttCard
            if let mqttHostProblem {
                LDNote(Text(verbatim: mqttHostProblem.message), color: LDTheme.warning, size: 13)
            }
        }
        .onChange(of: prefs.healthWebhookUrls) { pingOutcome = nil }
        .onChange(of: webhookUrl) { webhookProblem = nil }
        .onChange(of: mqttHost) { mqttHostProblem = nil }
    }

    private var webhookCard: some View {
        LDCard {
            ForEach(prefs.healthWebhookUrls, id: \.self) { url in
                Text(verbatim: url)
                    .font(LDType.monoValue)
                    .foregroundStyle(LDTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .ldCode()
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
            }
            LDFieldRow("Webhook URL", text: $webhookUrl, verbatimPrompt: "https://...") {
                LDButton("Add", kind: .ghost, size: .small, fullWidth: false) {
                    _ = addWebhook()
                }
                .disabled(isBlank(webhookUrl))
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.done)
            .onSubmit { _ = addWebhook() }

            // The Home screen's Test ping, so a wrong address shows before any data is due.
            LDRow("Test ping") {
                if isPinging {
                    ProgressView()
                        .tint(LDTheme.muted)
                }
            }
            .ldButton(action: sendTestPing)
            .disabled(prefs.healthWebhookUrls.isEmpty || isPinging)
        }
    }

    private var mqttCard: some View {
        LDCard {
            LDRow(
                "MQTT broker",
                value: hasMqttBroker ? Text(verbatim: prefs.mqttHost) : Text("Set up"),
                valueColor: hasMqttBroker ? LDTheme.accentTextSoft : LDTheme.muted,
                showsChevron: !showsMqttField
            )
            .ldButton { setMqttField(!showsMqttField) }

            if showsMqttField {
                LDFieldRow("Broker host, e.g. 192.168.1.10", text: $mqttHost, verbatimPrompt: "192.168.1.10") {
                    LDButton("Use", kind: .ghost, size: .small, fullWidth: false) {
                        _ = useMqttHost()
                    }
                    .disabled(isBlank(mqttHost))
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .onSubmit { _ = useMqttHost() }
            }
        }
    }

    private var types: some View {
        VStack(alignment: .leading, spacing: 0) {
            LDHeading("What should it send?")
            LDGap(16)
            LDOption(
                "Essentials",
                subtitle: Text("Steps, distance, active calories, sleep, heart rate, resting heart rate, weight, exercise"),
                isSelected: typeChoice == .essentials
            ) { choose(.essentials) }
                .ldStaggerRise(0)
            LDOption(
                "All types",
                subtitle: Text("Everything this app can read"),
                isSelected: typeChoice == .all
            ) { choose(.all) }
                .ldStaggerRise(1)
            LDOption(
                "Choose later",
                subtitle: Text("Pick from What to send"),
                isSelected: typeChoice == .later
            ) { choose(.later) }
                .ldStaggerRise(2)
        }
        // The essentials are the answer for most, so they are picked already; Choose later stays.
        .onAppear {
            if typeChoice == nil && prefs.healthEnabledDataTypes.isEmpty { choose(.essentials) }
        }
    }

    /// Its own step since 1.10.0: as a button on the summary it was easy to pass, and an app
    /// without Health access sends nothing and says little about why. A first sync follows at
    /// once, so the setup ends on proof that data arrives, or on what to fix.
    private var access: some View {
        VStack(alignment: .leading, spacing: 0) {
            LDHeading("Apple Health access")
            LDNote("iOS asks once for each type, and an app never gets to see what you refused.")
            if prefs.healthEnabledDataTypes.isEmpty {
                LDGap(6)
                LDBanner("No data types selected", message: Text("Pick them in What to send, then tap Sync now."))
            } else {
                LDGap(16)
                LDButton(accessAsked ? Text("Ask iOS again") : Text("Allow Apple Health access"), action: allowAccess)
                    .disabled(isFirstSyncing)

                if accessAsked {
                    accessResult
                }
            }
        }
    }

    @ViewBuilder
    private var accessResult: some View {
        if destinationCount == 0 {
            LDGap(6)
            LDBanner("No destination yet", message: Text("Add a destination on the Health tab, and the first sync goes out."))
        } else if isFirstSyncing {
            LDNote("Sending a first sync...", color: LDTheme.accentTextSoft, top: 16)
        } else if let firstSync {
            LDNote(firstSync.text, color: resultColor(firstSync.tone), top: 16)
            if firstSync == .noData {
                LDNote("Nothing to send yet, or iOS gives no access. Settings > Health > Data Access & Devices > Life Dashboard shows what it may read.", size: 13)
            }
            if firstSync.tone != .success {
                LDGap(12)
                LDButton("Sync again", kind: .ghost, action: sendFirstSync)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 0) {
            LDHeading("Ready.")
            LDGap(12)
            LDKeyValueList(summary)
                .ldStaggerRise(0)
        }
    }

    private var summary: [LDKeyValue] {
        var items = [
            LDKeyValue(
                "Sending to",
                destinationNames.isEmpty ? Text("None yet") : Text(verbatim: destinationNames.joined(separator: "\n")),
                color: destinationNames.isEmpty ? LDTheme.muted : LDTheme.text
            ),
            LDKeyValue(
                "Data Types",
                dataTypesSummary,
                color: prefs.healthEnabledDataTypes.isEmpty ? LDTheme.muted : LDTheme.text
            )
        ]
        if isFirstSyncing {
            items.append(LDKeyValue("First sync", Text("Sending a first sync..."), color: LDTheme.accentTextSoft))
        } else if let firstSync {
            items.append(LDKeyValue("First sync", firstSyncSummary(firstSync), color: firstSync.tone == .success ? LDTheme.text : resultColor(firstSync.tone)))
        }
        return items
    }

    private var destinationNames: [String] {
        prefs.healthDestinations.map(\.host) + (hasMqttBroker ? [prefs.mqttHost] : [])
    }

    private var dataTypesSummary: Text {
        let enabled = prefs.healthEnabledDataTypes
        if enabled == OnboardingView.essentials {
            return Text("\(enabled.count) essentials")
        }
        return Text("\(enabled.count) of \(HealthDataType.allCases.count) selected")
    }

    private func firstSyncSummary(_ outcome: SyncOutcome) -> Text {
        if case .synced(let records) = outcome {
            return Text("\(records) records")
        }
        return outcome.text
    }

    private var hasMqttBroker: Bool {
        prefs.mqttEnabled && !prefs.mqttHost.isEmpty
    }

    private var destinationCount: Int {
        prefs.healthWebhookUrls.count + (hasMqttBroker ? 1 : 0)
    }

    // MARK: - Footer

    private var footer: some View {
        LDFooterBar {
            if step != .welcome {
                LDButton("Back", kind: .ghost, inset: 0) { move(by: -1) }
            }
            LDButton(primaryTitle, inset: 0, action: step == .done ? finish : advance)
        }
    }

    private var primaryTitle: Text {
        switch step {
        case .welcome: return Text("Get started")
        case .done: return Text("Open the app")
        default: return Text("Continue")
        }
    }

    // MARK: - Parts

    /// The boards' danger is amber, not red.
    private func resultColor(_ tone: StatusTone) -> Color {
        switch tone {
        case .success: return LDTheme.accentTextSoft
        case .failure, .warning: return LDTheme.warning
        case .info: return LDTheme.secondary
        }
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func setMqttField(_ shown: Bool) {
        if reduceMotion {
            showsMqttField = shown
        } else {
            withAnimation(LDMotion.enter()) { showsMqttField = shown }
        }
    }

    // MARK: - Actions

    private func choose(_ choice: TypeChoice) {
        typeChoice = choice
        switch choice {
        case .essentials: prefs.healthEnabledDataTypes = OnboardingView.essentials
        case .all: prefs.healthEnabledDataTypes = Set(HealthDataType.allCases)
        case .later: prefs.healthEnabledDataTypes = []
        }
        firstSync = nil
    }

    private func allowAccess() {
        Task {
            try? await HealthKitManager.shared.requestAuthorization(for: prefs.healthEnabledDataTypes)
            accessAsked = true
            if destinationCount > 0 { sendFirstSync() }
        }
    }

    /// Sync now, as on Home, with its result line.
    private func sendFirstSync() {
        isFirstSyncing = true
        firstSync = nil
        Task {
            let outcome = SyncOutcome(await SyncCoordinator.shared.runManual(syncNow: true))
            isFirstSyncing = false
            firstSync = outcome
            AccessibilityNotification.Announcement(outcome.announcement).post()
        }
    }

    /// An address that can never work stays in the field, with what is wrong.
    private func addWebhook() -> Bool {
        let trimmed = webhookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if let problem = WebhookProblem.of(trimmed) {
            webhookProblem = problem
            AccessibilityNotification.Announcement(problem.message).post()
            return false
        }
        prefs.addTypedHealthWebhookUrl(trimmed)
        webhookUrl = ""
        return true
    }

    /// The rule of the MQTT settings: a host that is not one stays in the field, with what is wrong.
    private func useMqttHost() -> Bool {
        if let problem = SettingsValidation.brokerHostProblem(mqttHost) {
            mqttHostProblem = problem
            AccessibilityNotification.Announcement(problem.message).post()
            return false
        }
        prefs.mqttHost = SettingsValidation.normalizedBrokerHost(mqttHost)
        prefs.mqttEnabled = true
        setMqttField(false)
        return true
    }

    private func sendTestPing() {
        isPinging = true
        pingOutcome = nil
        let urls = prefs.healthWebhookUrls
        Task {
            let delivered = await TestPing.send(prefs: prefs)
            isPinging = false
            // An address added or removed meanwhile makes the answer about another list.
            guard let delivered, prefs.healthWebhookUrls == urls else { return }
            let outcome: SyncOutcome = delivered ? .pingDelivered : .pingFailed
            pingOutcome = outcome
            AccessibilityNotification.Announcement(outcome.announcement).post()
        }
    }

    /// Continue never asks for a destination, the step can be left empty. Only text still in a
    /// field counts as meant: it is saved, or Continue stays here to show what is wrong with it.
    private func advance() {
        if step == .destination {
            let webhookSaved = addWebhook()
            let hostSaved = isBlank(mqttHost) || useMqttHost()
            if !hostSaved { setMqttField(true) }
            guard webhookSaved && hostSaved else { return }
        }
        move(by: 1)
    }

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        travel = offset > 0 ? .forward : .backward
        // A leaving view keeps the transition of its last update, so the direction lands first.
        DispatchQueue.main.async {
            if reduceMotion {
                step = next
            } else {
                withAnimation(LDMotion.enter()) { step = next }
            }
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let entering = travel.startOffset * (layoutDirection == .rightToLeft ? -1 : 1)
        return .asymmetric(
            insertion: .offset(x: entering).combined(with: .opacity),
            removal: .offset(x: -entering).combined(with: .opacity)
        )
    }

    private func finish() {
        BackgroundSyncManager.shared.reconfigureObservers()
        BackgroundSyncManager.shared.replan()
        onFinish()
    }
}

/// What is wrong with a typed webhook address: not a web address at all, or one iOS refuses on
/// every request. By the rules a pairing link is held to, as far as they apply to a typed address.
private enum WebhookProblem: Equatable {
    case invalid
    case blockedByATS

    static func of(_ url: String) -> WebhookProblem? {
        guard !url.contains(where: \.isWhitespace),
              // Android stores its URL list comma-joined, and a settings backup serves both apps.
              !url.contains(","),
              let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              // No look-alike: https://homeassistant.local@evil.example goes to evil.example.
              components.user == nil, components.password == nil
        else { return .invalid }
        return PairingReach.of(url) == .blockedByATS ? .blockedByATS : nil
    }

    var message: String {
        switch self {
        case .invalid: return String(localized: "Invalid URL")
        case .blockedByATS: return String(localized: "iOS blocks plain HTTP to this host. Use its IP address or https.")
        }
    }
}
