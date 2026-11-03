import SwiftUI

/// The privacy policy as the app shows it under About: a summary of PRIVACY.md and of the page
/// at `AboutLinks.privacy`, which say the same in more words. Change the three together. The
/// texts are resources so the tests can hold them to the limits in the code.
enum PrivacyPolicyText {
    static let intro: LocalizedStringResource = "Life Dashboard Companion is a self-hosting tool. It reads health data on this iPhone and sends it only to servers you set up yourself. The app sends nothing to the developer, who never receives, stores or sees your health data."
    static let reads: LocalizedStringResource = "Apple Health data, only for the types you switch on and only after you allow them in the Health access sheet. With Backfill, also older records for the range you pick. When you delete a record in Apple Health, the next sync reports its id so your server can remove it too."
    static let writes: LocalizedStringResource = "Nothing. The app only asks Apple Health for read access."
    static let permissions: LocalizedStringResource = "Apple Health, read only, for the types you switch on. Camera, only while the pairing scanner is open: frames are decoded on the iPhone and are never stored or sent. Local Network, to reach a webhook server or MQTT broker on your home network. Notifications, for failed syncs, lost payloads and syncs that stay away for days: they are shown on this iPhone and sent nowhere."
    static let destinations: LocalizedStringResource = "Only to the destinations you enter or pair: your own webhook URLs, the Life Dashboard integration in your own Home Assistant, and your own MQTT broker. The app contacts no other server and has no analytics, no crash reporting and no advertising SDKs. Besides the records of the types you switch on, a payload carries the sync time, the app version, a counter, the time zone of the iPhone, daily totals and the ids of deleted records. Each record carries its id and the name of the app or device that wrote it, which on an iPhone often includes your name. No device model or identifier of your iPhone is sent. MQTT is unencrypted unless you switch on TLS. States are published retained, so the broker keeps the latest value of each sensor even after you switch MQTT off in the app: clear the topics on the broker if you stop using it."
    static let developer: LocalizedStringResource = "The app itself sends nothing to the developer. Apple can share some things through App Store Connect: for the App Store version, sales reports, and crash reports and usage figures from people who chose in their iPhone's settings to share analytics with app developers; if you test a beta through TestFlight, crash reports and any feedback you send through TestFlight, with the screenshot you attach. Apart from what you write or attach yourself, none of this carries your health data, your settings or the addresses you send to."
    static let stays: LocalizedStringResource = "Your settings, with secrets in the iOS Keychain. Sync progress, so a sync sends only what is new; a backfill, or a delivery that iOS cut off, can send a record again. A log of the last 100 deliveries, which you can clear. Payloads that could not be delivered yet, at most 700: when the queue is full, the oldest one makes way. Otherwise a payload waits until it arrives, or until it is older than 7 days and a server answers it with an error; while no server can be reached, nothing is dropped for its age. With MQTT on, the latest value of each sensor. With a data resolution set, the samples of a window that is still filling. Your settings and most of the sync progress are in your iPhone backup, like other app data. The log, the undelivered payloads, the sensor values and the held samples are not: a restored or new iPhone starts without them. Deleting the app removes all of it, but iOS can keep the secrets in the Keychain: clear them in the app first if you want them gone. A settings export without secrets still contains your webhook URLs, which can work as a password, so share it with care."
    static let control: LocalizedStringResource = "Everything is opt-in and reversible: which types are read, where they go and how often. Turning off access in the Health app stops the matching reads immediately. The developer holds no copy of your health data or settings, so there is nothing of that to request or delete on the developer's side."
    static let contact: LocalizedStringResource = "Owen Vogelaar, trading as oVog Enterprise (KvK 81085583), is responsible for this app and this policy. For questions about privacy, email [owen282000@hotmail.com](mailto:owen282000@hotmail.com) or ask in [Discussions](https://github.com/owen282000/life-dashboard-companion-app/discussions) on GitHub."
}

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
