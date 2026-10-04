# Privacy policy

Last updated: October 4, 2026, for version 1.6.0.

**In short:** the app reads the Apple Health types you switch on and sends them only to the webhooks, Home Assistant and MQTT broker you set up. There is no Life Dashboard server, no analytics, no crash reporting and no advertising. The app never writes into Apple Health.

Life Dashboard Companion is a self-hosting tool. It reads health data on your iPhone and sends it only to servers you set up yourself. The developer never receives, stores or sees any of your data. The app shows a summary of this policy under **About**, and the policy also has [a page of its own](https://owen282000.github.io/life-dashboard-companion/ios/privacy/).

- **What the app reads** - Apple Health data, only for the types you switch on and only after you allow them in the Health access sheet. With **Backfill**, also older records for the range you pick. When you delete a record in Apple Health, the next sync reports its `uuid` so your server can remove it too.
- **What the app writes** - nothing. The app only asks Apple Health for read access.
- **Permissions** - Apple Health, read only, for the types you switch on. Camera, only while the pairing scanner is open: frames are decoded on the iPhone and are never stored or sent. Local Network, to reach a webhook server or MQTT broker on your home network. Notifications, for failed syncs and payloads that were dropped; they are shown on the iPhone and sent nowhere.
- **Where it goes** - only to the destinations you enter or pair: your own webhook URLs, the Life Dashboard integration in your own Home Assistant, and your own MQTT broker. The app contacts no other server. There are no analytics, no crash reporting services and no advertising SDKs. Besides the types you switch on, each payload carries the app version, and each record carries the name of the app or device that wrote it. On an iPhone that name often includes your own name. MQTT is unencrypted unless you switch on **TLS**. States are published retained, so the broker keeps the latest value of each sensor even after you switch MQTT off in the app: clear the topics on the broker if you stop using it.
- **What stays on the iPhone:**
  - Your settings, with secrets in the iOS Keychain.
  - Sync progress, so a sync sends only what is new since the last one. A backfill, or a delivery that iOS cut off, can send a record again with the same `uuid`.
  - A log of the last 100 deliveries, which you can clear.
  - Payloads that could not be delivered yet, at most 700. Each one stays until it arrives, or until it is older than 7 days and a server responds with an error.
  - With MQTT on, the latest value of each sensor, so every publish can send all of them. Switching MQTT off removes them at the next sync.
  - With a data resolution set, the samples of a window that is still filling, until the window closes and is sent.

  Your settings and the sync progress are part of your iPhone backup, like other app data. The log, the undelivered payloads, the sensor values and the held samples are not: they stay on this iPhone, and a restored or new iPhone starts without them. Deleting the app removes all of it, but iOS can keep the secrets in the Keychain: clear them in the app first if you want them gone.

  Exports are files you create yourself and hand to the share sheet or the Files app, where the app you pick keeps its own copy. A settings export without secrets still contains your webhook URLs, which can work as a password, so share it with care.
- **Your control** - everything is opt-in and reversible: which types are read, where they go and how often. Turning off access in the Health app stops the matching reads immediately. The developer holds no copy of anything, so there is nothing to request or delete on the developer's side.
- **Changes** - a change to this policy is published here with a new date, and in the changelog.
- **Contact** - ask privacy questions in [Discussions](https://github.com/owen282000/life-dashboard-companion-app/discussions). For anything personal, email owenvogelaar@hotmail.com. Security problems go through [SECURITY.md](SECURITY.md).

The app ships a privacy manifest (`PrivacyInfo.xcprivacy`) that declares no tracking and no collected data.
