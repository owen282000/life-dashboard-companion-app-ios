import SwiftUI

/// The Android app's first-run setup in four steps: what the app does, where the data goes,
/// which types, and Apple Health access. Only a fresh install sees it; every step can be
/// skipped, and it writes only the settings the Health tab writes too.
struct OnboardingView: View {
    let onFinish: () -> Void

    @ObservedObject private var prefs = PreferencesManager.shared
    @EnvironmentObject private var pairing: PairingCoordinator

    @State private var step = Step.welcome
    @State private var webhookUrl = ""
    @State private var mqttHost = ""
    @State private var typeChoice: TypeChoice?
    @State private var isPinging = false
    @State private var pingOutcome: SyncOutcome?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Int, CaseIterable {
        case welcome, destination, types, done
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .welcome: welcome
                    case .destination: destination
                    case .types: types
                    case .done: done
                    }
                }
                .padding(16)
                .readableWidth()
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { footer }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if step != .done {
                        Button("Skip setup", action: finish)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            #if DEBUG
            // For screenshots: -ld.step 2 opens the third step.
            step = Step(rawValue: UserDefaults.standard.integer(forKey: "ld.step")) ?? .welcome
            #endif
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 20) {
            BrandMark(glow: true)
                .frame(width: 180)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
                .background(
                    RadialGradient(colors: Brand.ground, center: UnitPoint(x: 0.3, y: 0.25), startRadius: 0, endRadius: 500),
                    in: RoundedRectangle(cornerRadius: Brand.heroRadius, style: .continuous)
                )
            Text("Your health data, your server")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Life Dashboard Companion sends your Apple Health data to Home Assistant, to your own webhook or to an MQTT broker. Nothing goes anywhere else.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("Where should your data go?", "You can add more, or change this, on the Health tab.")

            choiceCard(
                title: "Home Assistant",
                subtitle: Text("Scan the pairing code of the Life Dashboard integration"),
                systemImage: "qrcode.viewfinder",
                isDone: !prefs.healthUrlsWithoutHeaders.isEmpty
            ) {
                Button {
                    pairing.startScan()
                } label: {
                    Label("Scan a pairing code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            choiceCard(
                title: "Your own webhook",
                subtitle: Text("Every sync is a JSON POST to this address"),
                systemImage: "link",
                isDone: !prefs.healthWebhookUrls.isEmpty
            ) {
                ForEach(prefs.healthWebhookUrls, id: \.self) { url in
                    Text(verbatim: url)
                        .font(.footnote)
                        .foregroundStyle(Brand.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    TextField("Webhook URL", text: $webhookUrl, prompt: Text(verbatim: "https://your-webhook.com/health"))
                        .font(.footnote)
                        .textFieldStyle(.filled)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Add") {
                        let trimmed = webhookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        prefs.addTypedHealthWebhookUrl(trimmed)
                        webhookUrl = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(webhookUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                // The Health tab's Test ping, so a wrong address shows before any data is due.
                HStack(spacing: 12) {
                    Button(action: sendTestPing) {
                        Label("Test ping", systemImage: "dot.radiowaves.left.and.right")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(prefs.healthWebhookUrls.isEmpty || isPinging)
                    if isPinging {
                        ProgressView()
                    }
                }
                if let pingOutcome {
                    ResultLine(text: pingOutcome.text, tone: pingOutcome.tone)
                }
            }
            .onChange(of: prefs.healthWebhookUrls) {
                pingOutcome = nil
            }

            choiceCard(
                title: "MQTT broker",
                subtitle: Text("Sensors appear in Home Assistant through discovery"),
                systemImage: "house",
                isDone: prefs.mqttEnabled && !prefs.mqttHost.isEmpty
            ) {
                HStack(spacing: 8) {
                    TextField("Broker host, e.g. 192.168.1.10", text: $mqttHost)
                        .font(.footnote)
                        .textFieldStyle(.filled)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Use") {
                        prefs.mqttHost = mqttHost.trimmingCharacters(in: .whitespaces)
                        prefs.mqttEnabled = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(mqttHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var types: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("What should it send?", "Each type asks for its own access, and you can switch them one by one later.")
            typeCard(.essentials, title: "Essentials", subtitle: Text("Steps, distance, calories, sleep, heart rate, weight and workouts"), systemImage: "star")
            typeCard(.all, title: "All types", subtitle: Text("All \(HealthDataType.allCases.count) types the app can read"), systemImage: "square.grid.2x2")
            typeCard(.later, title: "Choose later", subtitle: Text("Pick them on the Health tab"), systemImage: "clock")
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("Ready", "All of this can be changed on the Health tab. iOS asks which of the types the app may read.")
            VStack(alignment: .leading, spacing: 0) {
                SettingRow(
                    "Destinations",
                    systemImage: "paperplane",
                    subtitle: destinationCount == 0 ? Text("None yet") : Text("\(destinationCount) set up"),
                    subtitleColor: destinationCount == 0 ? .secondary : Brand.ink
                )
                CardDivider()
                SettingRow(
                    "Data Types",
                    systemImage: "waveform.path.ecg.rectangle",
                    subtitle: Text("\(prefs.healthEnabledDataTypes.count) of \(HealthDataType.allCases.count) selected"),
                    subtitleColor: prefs.healthEnabledDataTypes.isEmpty ? .secondary : Brand.ink
                )
            }
            .cardStyle(padding: 0)

            if !prefs.healthEnabledDataTypes.isEmpty {
                Button {
                    Task { try? await HealthKitManager.shared.requestAuthorization(for: prefs.healthEnabledDataTypes) }
                } label: {
                    Label("Allow Apple Health access", systemImage: "heart")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
    }

    private var destinationCount: Int {
        prefs.healthWebhookUrls.count + (prefs.mqttEnabled && !prefs.mqttHost.isEmpty ? 1 : 0)
    }

    // MARK: - Parts

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button("Back") { move(by: -1) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
            }
            Button(action: step == .done ? finish : { move(by: 1) }) {
                switch step {
                case .welcome: Text("Get started")
                case .done: Text("Open the app")
                default: Text("Continue")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .readableWidth()
        .background(.bar)
    }

    private func stepTitle(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private func choiceCard<Content: View>(
        title: LocalizedStringKey,
        subtitle: Text,
        systemImage: String,
        isDone: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(systemName: systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    subtitle
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Brand.successInk)
                        .accessibilityLabel("Set up")
                }
            }
            content()
        }
        .cardStyle()
    }

    private func typeCard(_ choice: TypeChoice, title: LocalizedStringKey, subtitle: Text, systemImage: String) -> some View {
        let isSelected = typeChoice == choice
        return Button {
            typeChoice = choice
            switch choice {
            case .essentials: prefs.healthEnabledDataTypes = OnboardingView.essentials
            case .all: prefs.healthEnabledDataTypes = Set(HealthDataType.allCases)
            case .later: prefs.healthEnabledDataTypes = []
            }
        } label: {
            SettingRow(title: title, systemImage: systemImage, subtitle: subtitle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Brand.ink : Color.secondary)
                    .accessibilityHidden(true)
            }
            .cardStyle(padding: 0)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
                        .strokeBorder(Brand.green, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    private func move(by offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        if reduceMotion {
            step = next
        } else {
            withAnimation(.snappy) { step = next }
        }
    }

    private func finish() {
        BackgroundSyncManager.shared.reconfigureObservers()
        BackgroundSyncManager.shared.replan()
        onFinish()
    }
}
