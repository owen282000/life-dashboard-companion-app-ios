import SwiftUI

/// The MQTT broker. Everything is a draft until Save, which also keeps a half-typed host or phone
/// name out of a sync in between: a name per keystroke would publish a device and clear it again.
struct MqttDestinationScreen: View {
    @ObservedObject private var prefs = PreferencesManager.shared
    @EnvironmentObject private var navigator: LDNavigator

    @State private var isEnabled: Bool
    @State private var host: String
    @State private var port: String
    @State private var useTls: Bool
    @State private var username: String
    @State private var password: String
    @State private var baseTopic: String
    @State private var phoneName: String

    @State private var isPasswordRevealed = false
    @State private var showRemoveConfirm = false

    init() {
        let prefs = PreferencesManager.shared
        _isEnabled = State(initialValue: prefs.mqttEnabled)
        _host = State(initialValue: prefs.mqttHost)
        _port = State(initialValue: String(prefs.mqttPort))
        _useTls = State(initialValue: prefs.mqttUseTls)
        _username = State(initialValue: prefs.mqttUsername)
        _password = State(initialValue: prefs.mqttPassword)
        _baseTopic = State(initialValue: prefs.mqttBaseTopic)
        _phoneName = State(initialValue: prefs.phoneName)
    }

    var body: some View {
        LDScreen(background: LDTheme.sheet) {
            LDHeading("MQTT broker")
            LDNote("Publishes today's steps, distance and calories and the latest value of every other synced data type to your MQTT broker with Home Assistant Discovery: sensors appear automatically, no server-side setup needed.", top: 4)
            LDGap(12)
            fields
            phoneNameNotes
            if let status = MqttStatus(stored: prefs.mqttLastStatus) {
                LDNote(
                    Text(status.text),
                    color: status.success ? LDTheme.accentTextSoft : LDTheme.warning,
                    top: 10
                )
            }
            if prefs.mqttEnabled || !prefs.mqttHost.isEmpty {
                LDGap(10)
                LDButton("Remove destination", kind: .danger) { showRemoveConfirm = true }
            }
        }
        .navigationTitle("MQTT")
        .ldSheetToolbar(confirm: "Save", canConfirm: hostProblem == nil && portProblem == nil, onConfirm: save)
        .confirmationDialog("Remove destination", isPresented: $showRemoveConfirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MQTT publishing stops, and the broker's address and login are deleted from this iPhone.")
        }
    }

    private var fields: some View {
        LDCard {
            LDToggleRow("Enable MQTT publishing", isOn: $isEnabled)

            LDFieldRow("Broker host", text: $host, verbatimPrompt: "192.168.1.10")
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            if let hostProblem {
                DestinationFieldError(message: Text(verbatim: hostProblem.message))
            }

            LDFieldRow("Port", text: $port)
                .keyboardType(.numberPad)
            if let portProblem {
                DestinationFieldError(message: Text(verbatim: portProblem.message))
            }

            LDToggleRow("TLS", isOn: $useTls)

            LDFieldRow("Username (optional)", text: $username, prompt: "None")
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            LDFieldRow("Password (optional)", text: $password, prompt: "None", isSecure: !isPasswordRevealed) {
                DestinationRevealButton(isRevealed: $isPasswordRevealed)
            }
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            LDFieldRow("Base topic", text: $baseTopic)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            LDFieldRow("Phone name", text: $phoneName, prompt: "Optional", isCode: false)
                .autocorrectionDisabled()
        }
    }

    /// Android's phone name: a second iPhone on the same broker gets a device of its own, and
    /// without a name nothing changes. The id is shown as it goes on the wire, and a name with
    /// nothing usable in it, which would publish nameless, is said out loud.
    @ViewBuilder
    private var phoneNameNotes: some View {
        LDNote("For a second iPhone on the same MQTT broker. Empty keeps the device and the topics as they are; a name gives this iPhone its own device and its own topics under the base topic.", size: 13)
        if !phoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let slug = MqttSupport.phoneSlug(phoneName) {
                LDNote(
                    Text("Publishes as \(MqttSupport.deviceId(slug: slug)). After a rename, the next sync removes the old device's sensors from the broker."),
                    color: LDTheme.accentTextSoft,
                    size: 13
                )
            } else {
                LDNote(
                    "This name has no letters from a to z or digits, so the iPhone stays unnamed.",
                    color: LDTheme.warning,
                    size: 13
                )
            }
        }
    }

    /// An empty host is no broker, which is fine while MQTT is off.
    private var hostProblem: SettingsValidation.BrokerProblem? {
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isEnabled { return nil }
        return SettingsValidation.brokerHostProblem(host)
    }

    private var portProblem: SettingsValidation.BrokerProblem? {
        SettingsValidation.brokerPortProblem(port)
    }

    private func save() {
        if let number = Int(port.trimmingCharacters(in: .whitespaces)) {
            prefs.mqttPort = number
        }
        prefs.mqttUseTls = useTls
        prefs.mqttUsername = username
        prefs.mqttPassword = password
        prefs.mqttBaseTopic = baseTopic
        let name = String(phoneName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SettingsImport.maxPhoneNameLength))
        if name != prefs.phoneName { prefs.phoneName = name }
        // Last, because these two tell the background sync that the destinations changed.
        prefs.mqttHost = SettingsValidation.normalizedBrokerHost(host)
        prefs.mqttEnabled = isEnabled
    }

    /// The login goes with the address. Port, topic and phone name are no secrets and stay for a
    /// broker added later.
    private func remove() {
        prefs.mqttEnabled = false
        prefs.mqttHost = ""
        prefs.mqttUsername = ""
        prefs.mqttPassword = ""
        prefs.mqttLastStatus = ""
        navigator.dismissSheet()
    }
}
