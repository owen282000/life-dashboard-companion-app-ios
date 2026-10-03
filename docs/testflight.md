# TestFlight

What a TestFlight build needs, from the archive to a public link. The repository side is done:
iPhone only, a privacy manifest for the app and the widget, `ITSAppUsesNonExemptEncryption` set
to NO, the retry queue, the log and the deletion records out of backups, a privacy policy page,
and `scripts/bump-build.sh` for the build number. What is left happens in App Store Connect and
is listed here, with texts ready to paste.

There is no TestFlight build yet. [When the link exists](#when-the-link-exists) has the lines
that change then.

## Every upload

1. **Build number.** Run `scripts/bump-build.sh`. It sets `CURRENT_PROJECT_VERSION` of the app,
   the widget and the tests to the number of commits up to HEAD (135 at the time of writing),
   prints every bundle identifier with its version and build, and names the commit. App Store
   Connect refuses a build number it already has for the same version, and a widget whose
   version or build differs from the app's. For a second upload of the same commit, give a
   number yourself: `scripts/bump-build.sh 135.1`.
2. **Archive.** In Xcode, pick the scheme **LifeDashboardCompanion** and the destination **Any
   iOS Device (arm64)**, then **Product > Archive**. Automatic signing with team `B92ASNRFPF`
   registers the App IDs and their capabilities on the first archive (see
   [App IDs](#app-ids)).
3. **Upload.** In the Organizer: **Distribute App > App Store Connect > Upload**. Not
   "TestFlight Internal Only": a build uploaded that way can never go to external testers.
4. **Restore the project file:** `git checkout -- LifeDashboardCompanion.xcodeproj/project.pbxproj`.
   The build number exists for the upload only; the repository keeps 1.
5. **In App Store Connect**, once the build has processed (a few minutes, an email says so):
   add it to the internal group, fill in **What to Test**, and add it to the external group.
   The first build of each version goes through Beta App Review; later builds of the same
   version usually do not. No export compliance question appears, because the Info.plist
   answers it.

What to Test, per build:

```text
Build <N> (commit <sha>). <One or two lines from the Unreleased section of the changelog.>
Everything else: set up a destination, switch on a few data types, tap Sync Now, and check
that the data arrives and that the Logs tab agrees.
```

## One time, in App Store Connect

### Name

"Life Dashboard" is taken: an app by Crystal Maguire (id 6761919162, Lifestyle) uses it in the
NL, DE and GB storefronts, and in the US storefront as "Life Dashboard (34741d)". The home
screen name can stay "Life Dashboard" (`CFBundleDisplayName`); only the store name has to be
unique.

Checked on 3 October 2026 with the iTunes Search API
(`https://itunes.apple.com/search?term=<name>&entity=software&country=<cc>`) in the US, NL, DE
and GB storefronts, looking for an app named exactly that or with the name inside its own:

| Name | Characters | Found |
|---|---|---|
| **Life Dashboard Companion** | 24 | Nothing, in all four storefronts |
| Life Dashboard Sync | 19 | Nothing |
| Life Dashboard Health Sync | 26 | Nothing |
| Life Dashboard Bridge | 21 | Nothing |
| Life Dashboard Connect | 22 | Nothing |
| Life Dashboard Link | 19 | Nothing |
| Life Dashboard Relay | 20 | Nothing |
| Life Dashboard Health Export | 28 | Nothing |

Taken or close: "Life Dashboard" (above), and five apps that carry it inside a longer name
("Steer: AI Life Dashboard", "Chronos Ink: Life Dashboard", "GdApp - Your Life Dashboard",
"Lumeia: Private Life Dashboard", "ChronOrbit:Life Dashboard&Note"). The search sees only apps
that are live: a name reserved by an app record that never shipped is invisible to it, so App
Store Connect has the last word when the record is created.

The pick is **Life Dashboard Companion**: it is the repository's name, the Android app's name
and the name in the privacy policy, and it stays under the 30-character limit. If it is
refused, Life Dashboard Bridge or Life Dashboard Relay say what the app does without "Sync",
which reads as syncing between platforms (the Play listing avoids that word for the same
reason). Leave "Home Assistant" out of the name: it is someone else's trademark.

### App IDs

Automatic signing creates these on the first archive. To make them by hand instead, under
Certificates, Identifiers & Profiles:

| App ID | Capabilities |
|---|---|
| `com.owen282000.lifedashboard` | HealthKit (with Background Delivery), App Groups: `group.com.owen282000.lifedashboard` |
| `com.owen282000.lifedashboard.widget` | App Groups: `group.com.owen282000.lifedashboard` |

### New app

**Apps > + > New App**:

| Field | Value |
|---|---|
| Platforms | iOS |
| Name | Life Dashboard Companion |
| Primary Language | English (U.S.) |
| Bundle ID | `com.owen282000.lifedashboard` |
| SKU | `life-dashboard-companion-ios` (never shown, cannot change) |
| User Access | Full Access |

### App Information

| Field | Value |
|---|---|
| Subtitle (App Store only, 30 characters) | Your health data, your server |
| Category | Health & Fitness, secondary Utilities |
| Content Rights | No, the app shows no third-party content |
| Age Rating | 4+, from the answers below |

Age rating questionnaire: every content question **None**, every feature question **No**:

| Question | Answer |
|---|---|
| Parental Controls, Age Assurance | No |
| Unrestricted Web Access | No: links open in Safari, there is no browser in the app |
| User-Generated Content, Messaging and Chat | No |
| Advertising | No |
| Medical or Treatment Information | None: the app shows the user's own measurements and gives no advice |
| Health or Wellness Topics, if asked | Yes: the app reads Apple Health. Check that the computed rating stays 4+ |
| Violence, sexual content, profanity, horror, drugs, alcohol, tobacco | None |
| Gambling, simulated gambling, contests, loot boxes | No / None |

### Availability

The app is iPhone only (`TARGETED_DEVICE_FAMILY = 1`), and a later build may not drop a device
family an earlier one offered, so this was settled before the first upload. Two switches are
still on by default and should go off:

- **Pricing and Availability > iPhone and iPad Apps on Apple Silicon Macs:** off. A Mac has no
  Apple Health data for the app to read.
- **Pricing and Availability > Apple Vision Pro:** off. The app is built and tested for the
  iPhone only, and its background sync was never tried there.
- In **TestFlight**, "Test iPhone and iPad Apps on Apple Silicon Macs" and the Vision Pro
  equivalent, if shown: off.

An iPad can still install an iPhone app in compatibility mode; Apple offers no switch for that.

### App Privacy

**Privacy Policy URL:** `https://owen282000.github.io/life-dashboard-companion/ios/privacy/`

**Data collection:** "No, we do not collect data from this app", which shows as **Data Not
Collected**. Apple defines collecting as "transmitting data off the device in a way that
allows you and/or your third-party partners to access it for a period longer than what is
necessary to service the transmitted request in real time". The app sends health data only to
the webhook URLs, Home Assistant and MQTT broker the user enters or pairs, which the user runs
and the developer has no access to. It contacts no other server, embeds no SDKs, and has no
analytics, crash reporting or advertising. The camera frames of the pairing scanner never
leave the phone. `PrivacyInfo.xcprivacy` declares the same: no tracking, no tracking domains,
no collected data types.

This answer has to change the day the app sends anything to a server of the developer's or a
third party's, a crash reporter or an update check included.

### Export compliance

`ITSAppUsesNonExemptEncryption` is NO in `LifeDashboardCompanion/Info.plist`, so a build asks
nothing. That is true because the app uses only the encryption iOS provides: HTTPS through
`URLSession` and TLS for MQTT through the Network framework. If App Store Connect asks anyway,
the answer is that the app uses only encryption exempt from export documentation, the
operating system's.

### TestFlight: Test Information

Beta App Description, English:

```text
Life Dashboard Companion reads the Apple Health data you choose and sends it to a server you run yourself: the Life Dashboard integration in Home Assistant, any webhook that accepts a JSON POST, or an MQTT broker. Nothing goes to the developer or to anyone else. There are no accounts, analytics or ads.

28 data types, from steps, sleep and heart rate to workouts and nutrition, each off until you switch it on. Syncs on an interval or from set times, fills in up to a year of history, passes on deleted records, and logs every delivery. The payload is the Android app's, so one server or one Home Assistant serves both phones.

This is a beta. Report problems on GitHub (github.com/owen282000/life-dashboard-companion-app-ios/issues) or with TestFlight's screenshot feedback.
```

Beta App Description, Dutch (for a Dutch localization of the test information):

```text
Life Dashboard Companion leest de Apple Health-gegevens die je kiest en stuurt ze naar een server die je zelf beheert: de Life Dashboard-integratie in Home Assistant, elke webhook die een JSON POST aanneemt, of een MQTT-broker. Er gaat niets naar de ontwikkelaar of naar iemand anders. Geen accounts, geen analytics, geen advertenties.

28 gegevenstypen, van stappen, slaap en hartslag tot trainingen en voeding, elk uit tot je het aanzet. Synchroniseert met een interval of vanaf vaste tijden, vult tot een jaar geschiedenis aan, geeft verwijderde records door en houdt van elke levering een log bij. De payload is die van de Android-app, dus één server of één Home Assistant bedient beide telefoons.

Dit is een bèta. Meld problemen op GitHub (github.com/owen282000/life-dashboard-companion-app-ios/issues) of met de schermafbeelding-feedback van TestFlight.
```

| Field | Value |
|---|---|
| Feedback Email | `<FEEDBACK_EMAIL>`: testers see it, so not the personal address. An alias that forwards is enough |
| Marketing URL | `https://github.com/owen282000/life-dashboard-companion-app-ios` |
| Privacy Policy URL | `https://owen282000.github.io/life-dashboard-companion/ios/privacy/` |

### TestFlight: Beta App Review Information

Contact name, phone and email: Owen's own; Apple does not show them to testers. **Sign-in
required:** off, the app has no accounts.

The reviewer needs somewhere to send data. Before submitting, open
[webhook.site](https://webhook.site): it gives a unique URL that accepts any POST, and a page
that shows each request as it arrives. Free URLs are removed after 7 days and stop after 100
requests, so make one the day you submit, and a new one for a later build that goes to review
again. A receiver of your own that shows what arrives works just as well.

Review notes (English; App Review reads English):

```text
Life Dashboard Companion sends the Apple Health data the user picks to a server the user runs. No account, no Home Assistant and no hardware are needed to try it. A test receiver is ready:

Webhook URL: https://webhook.site/<TOKEN>
See what arrives: https://webhook.site/#!/view/<TOKEN>

1. Open the app. In the setup, choose "Your own webhook" and paste the Webhook URL above. Choose "Essentials" and allow Apple Health access when iOS asks.
2. On the Health tab, tap "Test ping". A POST with "Test ping from Life Dashboard Companion" appears on the page above within seconds.
3. If this device has no Health data, add some in the Health app (Browse > Activity > Steps > Add Data).
4. Back in the app, tap "View" to see the JSON the app will send, then "Sync Now". The POST with the steps appears on the page above, and the Logs tab lists the delivery.

The app only reads from Apple Health and never writes to it. It sends data only to the addresses the user enters; it has no server of its own, no analytics and no third-party SDKs. The camera is used only to scan the pairing QR code that the Life Dashboard integration for Home Assistant shows. The app is open source: https://github.com/owen282000/life-dashboard-companion-app-ios
```

### External group and public link

1. **TestFlight > Internal Testing:** a group with yourself, to install each build on your own
   iPhone first. No review.
2. **TestFlight > External Testing:** a group, for example "Public". Add the build and submit it
   for Beta App Review.
3. After approval, open the group and switch on **Public Link**. A tester limit is optional
   (up to 10,000). Under the group, "Testers" shows installs and sessions, which is the signal
   P3-5 is about.

TestFlight builds expire after 90 days; a new build every two weeks, with each release, keeps
the link alive.

## When the link exists

Today the README and the docs say, truthfully, that there is no TestFlight build. Once the
public link works, replace these three lines (`<LINK>` is the `https://testflight.apple.com/join/...`
address):

`README.md`, the line under the top links:

```markdown
Install the beta with [TestFlight](<LINK>), or build the app yourself with Xcode and install it on your own iPhone; [Quick start](#quick-start) says how, and what a free Apple Account means for it. It follows the [Android app](https://github.com/owen282000/life-dashboard-companion-app), which gets new features first, and says so where iOS cannot do what Android does.
```

`docs/usage.md`, the first line under "Build and install":

```markdown
The easiest way in is the [TestFlight beta](<LINK>): install TestFlight, open the link on the iPhone and tap Install. To build the app yourself instead, use Xcode and run it on your own iPhone.
```

`docs/features.md`, the last item of "What iOS does differently":

```markdown
- **No App Store build yet.** The app is a [TestFlight beta](<LINK>), or you build it with Xcode; see [usage.md](usage.md#build-and-install).
```

Also with the link: the "Build from source" button at the top of the README can become
"TestFlight" with the link, and outside this repository the Android README, the pairing page
in the Android repository (`docs/pair/index.html`, which says there is no App Store build) and
the integration's README get the link in place of "build it yourself".
