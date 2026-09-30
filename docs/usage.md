# Installation and setup

## Requirements

- An iPhone with iOS 17.0 or later
- A Mac with Xcode 26 or later, to build the app (CI builds with Xcode 26.6)
- An Apple Account; a free one is enough, see [below](#free-or-paid-apple-account)
- Home Assistant with the Life Dashboard integration 0.7.0 or newer (HACS), a webhook endpoint, or an MQTT broker

## Build and install

There is no App Store or TestFlight build. You build the app with Xcode and run it on your own iPhone.

```bash
git clone https://github.com/owen282000/life-dashboard-companion-app-ios.git
cd life-dashboard-companion-app-ios
open LifeDashboardCompanion.xcodeproj
```

The project carries Owen's team and identifiers, and Xcode can only sign it for you after you change them to your own:

1. **Team.** Select the project, then for the targets **LifeDashboardCompanion** and **LifeDashboardWidget** open **Signing & Capabilities** and pick your team.
2. **Bundle identifiers.** Give both targets an identifier of your own, for example `com.yourname.lifedashboard` and `com.yourname.lifedashboard.widget`. The widget's must start with the app's.
3. **App group.** The app and the widget share their sync status through an app group. Replace `group.com.owen282000.lifedashboard` with a group of your own, for example `group.com.yourname.lifedashboard`, in three places: the **App Groups** capability of both targets (or `LifeDashboardCompanion/LifeDashboardCompanion.entitlements` and `LifeDashboardWidget/LifeDashboardWidget.entitlements`), and `appGroupId` in `LifeDashboardCompanion/Managers/SharedSyncStatus.swift`. Without that last one the app works, but the widget stays empty.
4. **Run.** Connect the iPhone, pick it as the destination and press Run. The first time, the iPhone asks you to switch on Developer Mode (Settings > Privacy & Security) and to trust your developer certificate (Settings > General > VPN & Device Management).

The simulator is fine for trying the screens, but it has none of your Health data, and HealthKit's background delivery does not work there.

### Free or paid Apple Account

With a free Apple Account, Xcode signs the app with a provisioning profile that expires 7 days after it was issued. After that the app no longer opens until you run it from Xcode again. Settings and sync progress stay. A paid Apple Developer Program membership signs for a year. Apple lists what each membership includes on [Choosing a Membership](https://developer.apple.com/support/compare-memberships/), and which capabilities each can use on [Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios). The app uses HealthKit, App Groups and Background Modes.

To update, pull the repository and run it again from Xcode. Your settings stay.

## First run

A fresh install opens a short setup: what the app does, where the data should go (the Home Assistant pairing scanner, which is recommended, a webhook URL or an MQTT broker), which data types to start with (the essentials, all 28, or none yet), and Apple Health access. Every step can be skipped, and everything it sets can be changed later on the Health tab.

After the setup:

1. **Grant Apple Health access.** When a type is on that iOS has not asked about yet, the green Apple Health banner shows **Grant**. iOS never tells an app whether you allowed reading, so a type you declined simply sends nothing; change it in the Health app under your profile, Apps, Life Dashboard.
2. **Add webhook headers** (optional), such as an auth token or API key, and an **HMAC Signing Secret** if your receiver checks signatures.
3. **Set the sync schedule**: an interval (at least 15 minutes) or fixed times, with optional weekdays and quiet hours. On iOS a fixed time means "not before"; see [Sync scheduling](features.md#sync-scheduling).
4. **Tap View** to see the payload, then **Sync Now** to send it.

**Test ping** checks that your server accepts a POST before you wait for real data. iOS asks once for access to the local network the first time the app talks to an address on it; allow it, or nothing reaches a server at home.

Moving from another phone, Android or iPhone? Import your settings under **About > Backup & restore** instead of typing everything again; see [settings-backup.md](settings-backup.md).

## Phone to Home Assistant

Two routes, and neither needs YAML. The **Life Dashboard integration** is the recommended one: it needs no broker, is paired by scanning a code, and writes every synced day into long-term statistics on its own date, so a backfill becomes history. **MQTT** is the alternative for a setup that already has a broker Home Assistant talks to. Pick one: running both gives you two devices with the same numbers.

### With the integration

You need the integration 0.7.0 or newer; earlier versions do not accept the iPhone app. Installing it is the same as for the Android app, and the Android app's [usage.md](https://github.com/owen282000/life-dashboard-companion-app/blob/main/docs/usage.md#with-the-integration) walks through it: add the repository to HACS, download **Life Dashboard**, restart Home Assistant, and add the integration under Settings > Devices & services, with a name for the phone. Then:

1. **Scan the code** the dialog shows with **Scan a pairing code** in the app, and tap **Pair**. [Pairing by QR code](#pairing-by-qr-code) has the details.
2. **Grant and sync.** Switch on the types you want and tap **Sync Now**. The iPhone appears under Settings > Devices & services > Life Dashboard with a sensor for each type it sent. For the past, tap **Backfill** on the Health tab.

An Android phone and an iPhone can each be paired with the same integration, each as a device of its own.

### Pairing by QR code

The integration shows a QR code when you add it, and again under its Reconfigure. In the app, tap **Scan a pairing code**: in the setup, or on the Webhook card of the Health tab, where it is the QR button next to the address field. iOS asks for the camera the first time.

A sheet then shows what the receiver calls itself, the address, whether it is new, whether the signing secret is replaced, and what iOS will do with a plain `http://` address. Nothing is saved until you tap **Pair**, and a code only ever fills in the address and the secret: what is synced, and when, stays your choice on the Health tab. After pairing, the app sends one test ping and the sheet says whether Home Assistant confirmed it.

An address added by pairing gets none of your custom headers. Those were typed for the receivers you entered yourself, and a code can come from anyone, so an API key never follows a scanned code to its host. To send them there anyway, type the address in by hand.

iOS decides in advance which plain `http://` addresses an app may use: an IP address, a `.local` name like `homeassistant.local`, or a name without a dot. A name like `ha.lan` over `http://` cannot be paired; the sheet says so. Use the IP address, or an `https://` address, in the integration's Reconfigure.

### MQTT

1. In Home Assistant, install the **Mosquitto broker** add-on and add the **MQTT** integration if it is not there yet, and create a user for the app.
2. In the app, open the Health tab, expand **MQTT**, switch on **Enable MQTT publishing** and fill in the broker host, port 1883, and that username and password. For a broker reached over the internet, switch on **TLS** (usually port 8883).
3. Tap **Sync Now**. A broker alone is enough, and from then on every sync publishes, the automatic ones included. A device named **Life Dashboard Companion (iOS)** appears under Settings > Devices & services > MQTT, with a sensor for every synced type that has a value.

Two iPhones on one broker: give each a **Phone name** at the bottom of the MQTT card, and each becomes a device of its own, with the name in its device, ids and topics. The Android app and the iPhone already use different devices and topics, so they need no name for each other. Leave it empty on a single iPhone: then nothing changes. After a rename, the next sync removes the old device's sensors from the broker.

Steps, distance and calories are today's totals, the other sensors hold the latest record of their type; [features.md](features.md#home-assistant-and-mqtt) lists them. MQTT has no retry queue and gets no deleted records or backfill. If you add a webhook URL later, it gets what is new from then on; **Sync Now** or **Backfill** sends what came before. Values are published retained, so they survive a Home Assistant restart. The Logs tab shows every publish, with the broker's answer when it fails.

## Syncing without opening the app

- **Home screen widget.** Touch and hold the home screen, tap **Edit** > **Add Widget** and pick Life Dashboard. It shows the last sync and the records delivered today, and the round button in its corner syncs now.
- **Control Center** (iOS 18 and later). Open Control Center, tap **+** > **Add a Control**, search for Life Dashboard and pick **Sync Now**. It is the Android app's Quick Settings tile.
- **Shortcuts and Siri.** The **Sync Health Data** action, in a shortcut, an automation or by voice.

All three run the same action: it sends what is queued and what is new since the last sync, where **Sync Now** in the app sends the last 7 days again. Health data cannot be read while the iPhone is locked, so unlock it first; a control on the Lock Screen syncs nothing until then. Together they sync at most once a minute, like the Android app's sync broadcast, so a second tap within a minute does nothing.

## Troubleshooting

### Background syncs are late, or do not happen

iOS decides when an app runs in the background, and syncs can come later than the schedule says. Things that stop them:

- **Background App Refresh** is off for Life Dashboard (Settings > General > Background App Refresh), or **Low Power Mode** is on, which turns it off
- The iPhone was locked: Health data cannot be read then, and the sync waits for the unlock
- Quiet hours, or a day that is off in the weekday filter

The line under **Sync Now** says why automatic syncs are waiting, and the Logs tab shows when syncs actually ran. For a sync at an exact time, use a Shortcuts automation with **Sync Health Data**; **Need an exact time?** under Sync Schedule explains how.

### "Your iPhone is locked"

A sync or backfill that starts while the iPhone is locked cannot read Apple Health, because iOS encrypts it then. The sync waits for the unlock, and a backfill pauses and continues when you come back to the app.

### Nothing reaches a server at home

- Allow **Local Network** for Life Dashboard (Settings > Privacy & Security > Local Network)
- A plain `http://` address must be an IP address, a `.local` name or a name without a dot; see [Pairing by QR code](#pairing-by-qr-code)
- **Test ping** and the Logs tab show the error the server or iOS gave

### MQTT sensors do not update

Every sync with new records publishes today's totals and the types that have them, so a sensor only changes when new data arrives; a type that is still catching up on a long backlog is published once it has caught up. A broker that does not answer within 10 seconds, such as a home address dialled from outside the home network, fails the sync. If a publish fails, the Logs tab shows the broker's error; `NOT_AUTHORIZED` means the username or password is wrong.

### Queued payloads disappear

A payload that could not be delivered is kept for up to 7 days or 20 attempts, and then dropped. The Health tab shows how many are pending, and **Retry Now** sends them at once.

### Step, distance or calorie totals are far too high

Apple Health often holds the same activity from the iPhone and the Watch, each as records of its own. Summing the raw records counts it twice. Use [`daily_totals`](webhook.md#daily-totals) for day totals, which are deduplicated by HealthKit the way the Health app does it, and deduplicate raw records on `uuid`, since Sync Now sends the last 7 days again.

### The app says a pairing code is from a newer version

The code carries a format version, and this build only reads version 1. Pull the latest version of this repository, run it again from Xcode, and scan again.

### The app no longer opens

With a free Apple Account the app's provisioning profile expires after 7 days. Run the app from Xcode again; see [Free or paid Apple Account](#free-or-paid-apple-account).
