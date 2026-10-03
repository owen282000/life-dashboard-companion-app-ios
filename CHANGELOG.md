# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- With more than one webhook URL, a sync counts as delivered once one of them took it, so a URL that failed missed that payload for good, with nothing queued for it and nothing to say so. Delivery stays the same, but now it shows: after Sync Now the result line adds "Delivered to 1 of 2 destinations, see Logs." in red, and when it keeps happening, as many syncs in a row as the failure notification waits for, a notification names the address that misses them, by its host alone, never its path or query. A sync that reaches every URL clears it. Pairing with Home Assistant replaces the signing secret, so the pairing sheet now names the other addresses that get payloads signed with the new secret from then on, so you can give one that checks signatures the new secret too, or remove it
- An opened log row and the Health Data Preview show the first 12,000 characters of a payload, as the Android app does, with a line that says how many there are and where the rest is: Share payload in the row, the share button in the preview. The log row showed 1,500 and the preview 100,000, a length that stalls the screen while it is laid out. A payload the log kept shortened, past 100,000 characters, says so, since sharing it gives that part too. VoiceOver reads "Payload" and the number of characters instead of the whole payload
- Ready for TestFlight. The app is for iPhone only and no longer offers itself for iPad. The Health permission sheet now says plainly that the app never saves anything to Apple Health and only reads the types you switch on, for your own webhook, Home Assistant or MQTT broker. The app and the widget each carry a privacy manifest, and the app declares that it uses only the encryption iOS provides, so an upload asks no export compliance questions

### Fixed

- Distance could stop arriving after the update to 1.5.0. Distance reads cycling, swimming and the other new kinds of distance since then, and until you answer the Health sheet for them, HealthKit refuses every read of one, which failed the whole type: no `distance` records, no `distance_meters` in `daily_totals` and no Distance Today on MQTT. A kind of distance HealthKit may not read is now left out on its own and the others are sent, in the records, the daily totals and the deletion step, which no longer counts it as a failed read. The Health tab now also asks for Health access once by itself when there is something to ask for the types you have on, as after this update, instead of only showing Grant
- About 20 kinds of workout went out with `type` `other`, among them downhill skiing, snowboarding, cross-country skiing, kickboxing, jump rope, tai chi, pickleball, barre, cardio and social dance, mixed cardio, step training, fitness gaming, disc sports, hand cycling, the triathlon's swim bike run and transition, underwater diving and the two wheelchair paces. Every activity HealthKit has now gets a snake_case name of its own, such as `downhill_skiing`; the names sent before stay as they were
- The error lines of the settings backup (a wrong password, a file that cannot be read) were in the system red, 3.6:1 on white, under the 4.5:1 that small text needs. They now use the darker red the rest of the app uses for error text

## [1.5.0] - 2026-09-30

### Added

- Sync Now outside the app, as the Android app's Quick Settings tile: a button on the home screen widget, and on iOS 18 and later a Sync Now control for Control Center. Both run the Sync Health Data action, which sends what is queued and what is new since the last sync. The widget, the control and the Shortcuts action together sync at most once a minute, like the Android app's sync broadcast; a tap within a minute of the last accepted one does nothing, and the action says so in Shortcuts
- Export on the Health tab, like the Android app's: the data View shows, as a JSON file or as a CSV table with a row per record, a column per field and the daily totals as rows of their own, through the share sheet. The file goes to the app's temporary folder, which is not backed up, and each export replaces the one before
- A phone name for MQTT, as in the Android app, so two iPhones can share one broker. It sits at the bottom of the MQTT card. Without a name nothing changes: the device id, the name and the topics stay exactly as they were, so an iPhone already set up needs to do nothing. With a name this iPhone publishes as a device of its own, `life_dashboard_companion_ios_<name>` with its topics under `lifedashboard-ios/<name>/`, and the first publish after a rename removes the old device's retained topics from the broker. The name goes into the settings backup under Android's key `phone_name`; a file from an Android phone leaves the iPhone's name alone
- Distance covers every activity, as on Android: cycling, swimming, wheelchair and downhill snow sports distance next to walking and running, and from iOS 18 rowing, paddling, cross-country skiing and skating. The `distance` records and `daily_totals`' `distance_meters` include them. Distance asks Health for access to them, so with Distance on, the Health tab shows Grant once after the update, and the first sync after it sends the last 7 days of distance again
- Nutrition records carry the food's name and 34 more nutrients under the Android app's keys, from fibre, sugars and the fat types to sodium, the vitamins and caffeine, as far as the app that logged the food wrote them. Nutrition asks Health for access to them, so with Nutrition on, the Health tab shows Grant once after the update
- Sleep sessions carry a `source`, the app or device that recorded most of the night's sleep stages, as Android's sessions do
- Menstruation periods carry a `uuid`, derived from their first flow day like a sleep session's, and the `source` of that day, so a receiver can replace a period that comes back longer instead of keeping both

### Changed

- MQTT publishes today's steps, distance, active calories and total calories, as the Android app does, instead of the newest record of each, which was a few dozen steps and meant nothing on a dashboard. The sensors are Steps Today, Distance Today, Active Calories Today and Total Calories Today, with the Android app's keys, units and device classes, state class `total_increasing` and the day in a `date` attribute. They come from today's `daily_totals` entry, as the Health app counts it, and are read for MQTT even with Daily totals in payload switched off. Every publish removes the old Steps, Distance, Active Calories and Total Calories "(latest record)" sensors from the broker, so Home Assistant drops them; a dashboard card or automation that used them needs the new sensor. Sensors also carry `suggested_display_precision`, so Home Assistant shows 5921 m instead of 5,921.00 m
- The log keeps one file per row. It was one file of up to about 10 MB, with the payload of each of the last 100 deliveries, that was read and written whole for every row, several times per sync, also in the background. The existing log is split into rows on the first launch

### Fixed

- Blood pressure is read per reading, the systolic and diastolic values saved together, instead of by matching the two by time. Every record now carries `diastolic`, which the Android schema requires; a value without its other half is no longer sent. Two readings within a second no longer share one diastolic value. The uuid stays the systolic sample's, so a receiver deduplicates against what earlier versions sent
- Heart rate and resting heart rate were cut to a whole number instead of rounded, so a Watch reading of 71.9 bpm arrived as 71. They are rounded now, and so are fractional step counts some apps write, and the 7-day steps sparkline on the Health tab
- Nutrition is read per food an app logged, instead of by matching energy, protein, carbohydrates and fat by time. Two foods logged at the same moment no longer get each other's values, and a food or value without energy, such as carbohydrates on their own, is no longer dropped. Values saved outside a food are still grouped by app and time when that is unambiguous
- Records could be lost when iOS suspended or ended the app while a sync's payload was on its way, because the sync had already marked them as sent. A HealthKit wakeup lets go after 25 seconds, one webhook can take over 90 seconds with its retries, and Sync Now had no background time at all once you left the app. A payload now goes into the retry queue before its records are marked as sent, and leaves it when a webhook accepted it, so every record is delivered, still queued, or read again by the next sync. At worst a payload arrives twice, which a receiver deduplicates on `uuid`. Sync Now and the sync that opening the app starts ask iOS for background time, so leaving the app mid-sync lets it finish
- The retry queue sent a payload with the custom headers it was queued with, so after you changed an API key every queued payload got HTTP 401 until it was dropped. A retry now goes to the webhook URLs and with the headers configured at that moment, as in the Android app, with the same rule as a sync for the addresses that pairing added, and the queue files no longer hold the headers. A queued payload whose URL you replaced was deleted; it now goes to the new one
- A payload the receiver refused for what it carries (HTTP 400, 413 or 422) held up everything queued after it. It is now skipped, so the rest goes through, and stays queued in case the receiver gets fixed, as in the Android app
- A queued payload was dropped after 20 attempts, and every sync, app launch and network change is one, so a receiver that was down for an afternoon could lose data. The queue now keeps a payload for 7 days, however many attempts that takes, and one older than that still gets a last try, so an iPhone that could not sync for a week delivers its queue once the receiver is back. A payload dropped after the week no longer disappears silently: it gets a row in the Logs tab with its payload and why it never arrived, and a notification says how many syncs were lost, also when failure notifications are off
- The failure notification never said what went wrong: its "Last error" line was never filled in. It now ends with the error of the last webhook that failed, such as HTTP 401, in the phone's language where the app wrote it
- Sync Now could set an MQTT sensor back by days. It reads the last 7 days oldest first, up to each type's cap per sync, so with an Apple Watch the heart rate, steps and active energy it read ended days ago, and that value was published as the current one, retained. A type with more records in the week than its cap is now read again from its newest end for MQTT, with or without a webhook, and a type that cannot be read is left alone on the broker
- One back-dated sample, such as a weight entered for last year or a history imported from another app, made the next syncs send every record of its type from that date to now again, a few hundred per sync until they caught up. A sync now sends only the samples HealthKit reports as added since the last one. A sleep stage or flow day added to a night or period that already went out sends that night or period again, whole, with the same `uuid` for the night. MQTT gets a type only when its newest sample is in the sync, so a back-dated entry never shows as the current value
- A HealthKit query that never answered held the sync, and Sync Now and every later sync behind it, until iOS ended the app. Every record query now gets 10 seconds, like the deletion step's; a type whose query runs out of time is skipped for that sync and read again by the next one, and the other types go ahead

## [1.4.1] - 2026-09-30

### Fixed

- The pairing sheet's title was cut off in Dutch ("Koppelen met een..."). It is now one word, Pairing, Koppeling or Kopplung, and shrinks a little before it is cut on a small iPhone with large text
- About says "No cloud in between", but the log, whose rows keep the payload they sent, and the payloads queued for retry were part of the iPhone's iCloud and computer backups. Both are now left out of backups, the files 1.4.0 wrote included, as the deletion tracking state already was. A restored or new iPhone starts without them; your settings and the sync progress are still in the backup, so a payload that was still queued when the backup was made is not sent again from the restored iPhone, and Backfill History is the way to resend it. The privacy policy says so
- A delivery cancelled halfway, as when iOS ends a background task, counted as a failure: the sync history showed "cancelled (2 times)" under Recent failures, it lowered the success rate and added to the failure notification's streak. It now shows as Interrupted, in a neutral colour, and counts as neither a success nor a failure; a delivery with an attempt that had already failed stays a failure. Its payload is queued for retry as before; a retry from the queue that is interrupted does not use up one of its 20 attempts, and an interrupted MQTT publish leaves the MQTT status at its last publish. Rows logged by 1.4.0 keep their Failed status until they leave the log

## [1.4.0] - 2026-09-30

### Added

- Six more data types, with the Android app's payload keys and fields: VO2 Max, Basal Body Temperature, Intermenstrual Bleeding, Ovulation Test, Cervical Mucus and Sexual Activity. Each starts off and asks for its own permission
- MQTT sensors for VO2 Max and Basal Body Temperature, named as in the Android app; the cycle tracking types stay webhook-only
- Backfill History on the Health tab sends the last 30, 90 or 365 days of every enabled type to your webhooks, in 3-day windows, oldest first, like the Android app's backfill and with the same payload fields (`backfill`, `window_start`, `window_end`, `window_complete`). The records are the same as a sync sends, uuid included, so a receiver deduplicates the overlap. Each sleep session and menstruation period goes out once and whole, in the window it ends or starts in. Progress is kept per window: Pause stops after the chunk in flight, and Resume continues at the first window that was not delivered in full. It runs while the app is open, and the screen stays on meanwhile; iOS pauses it shortly after you leave the app or lock the iPhone, since Health data can't be read while it is locked, and it continues when you come back within a day. On iOS 26 it runs as a continued processing task instead, which keeps going after you switch apps and shows its progress in the system UI, as long as the iPhone stays unlocked. A failed delivery stops it until you tap Resume; backfill payloads never go into the retry queue or to MQTT. Sync Now is unavailable while a backfill runs. iOS payloads always say `window_complete: false`: HealthKit does not tell an app that it may not read a type, so the app cannot vouch that a window is complete
- Deleting a record in Apple Health now reaches your webhook. The app follows HealthKit's own record of deletions and names the records that are gone in `deleted_records`, in the same shape as the Android app, so a receiver can drop exactly those. HealthKit edits by deleting a record and saving a new one under a new uuid, so until now every edit left the old record on the receiver next to the new one
- A sync whose only change is a deletion, which is what removing a meal without adding one looks like, sends a payload carrying the deletion and no records, and reports it as a delivery of 0 records instead of saying there was no new data. Deletions are kept until a payload carrying them has been delivered or queued for retry
- Types whose deletions a payload cannot vouch for, because HealthKit did not answer in time, could not be read, or was last read more than a week ago, are named in `deletions_unavailable`
- Every health payload with records carries `daily_totals` with the Android app's schema: per local day, for today and the two days before, the steps, distance, active and total calories as the Health app counts them, with overlapping iPhone and Watch samples counted once. A backfill payload carries every whole day of its window. A day or field without data is left out, never sent as 0. On iOS `distance_meters` is walking and running distance, and `total_calories` is resting plus active energy, only sent on days with resting energy (usually an Apple Watch). A switch, **Daily totals in payload**, turns it off; it is on by default
- Pairing with the Life Dashboard integration for Home Assistant (integration 0.7.1 or newer): tap **Scan a pairing code** under Webhook URLs, or point the iPhone camera at the code and follow the page's link to the app. A sheet shows who is asking, at which address and what changes, and nothing is saved until **Pair**; pairing fills in only the address and the signing secret
- After pairing, one test ping goes to the new address, and the sheet says whether Home Assistant confirmed it, which a plain 200 cannot prove
- Sleep sessions carry a `uuid` derived from their first stage, so a receiver can replace a night that comes back longer instead of counting it twice
- Sync schedule, as in the Android app: every X minutes or at fixed times, a weekday filter and quiet hours, stored in the Android app's format. iOS decides when an app runs in the background, so a fixed time means "not before this time": it syncs once, at the first chance iOS gives after it, and a time missed until quiet hours or a day that is off is skipped, not moved. The screen says so, warns when a combination never syncs, and a status line under Sync Now says why automatic syncs are waiting
- "Need an exact time?" explains how a Shortcuts Time of Day automation runs Sync Health Data at a set time
- Settings backup and restore under About: export the webhook URLs, which of them get no custom headers, the headers and signing secret, the sync schedule, every MQTT setting, the data-type toggles and the daily totals switch as a JSON file and import it again, on an iPhone or in the Android app. The file uses the Android app's format, and an export with secrets is encrypted with a password exactly as Android does it (AES-256-GCM, PBKDF2-HMAC-SHA256), so an encrypted Android export opens on the iPhone and the other way round. An export without secrets can be shared without handing over access. Importing shows a preview of the servers and of what is kept, cleared or skipped first; sync progress and logs are left out. Documented in `docs/settings-backup.md`
- Sync history on the Logs tab: success rate, deliveries and records over the entries the log keeps, with the time it starts, the last success, and the three latest failures grouped by receiver and error. A webhook is named by its host only
- MQTT publishes appear in the Logs tab next to webhook deliveries, with the broker, the number of sensors and the error when the broker could not be reached
- A first-run setup for a fresh install, as in the Android app: what the app does, where the data goes (the Home Assistant pairing scanner, a webhook or an MQTT broker), which types (the essentials, all 28 or later) and Apple Health access. Every step can be skipped, and an update from an earlier version never shows it
- A privacy policy in the app, under About, in the Android app's six sections and written for what the iPhone app does
- About links to the documentation, the changelog, a new issue and the licence, like the Android app's About page. Builds run from Xcode also show Buy me a coffee; an archive for TestFlight or the App Store leaves it out, since App Review refuses tip links outside the US
- Dutch and German, in the Android app's wording and with Apple's own names for the Health app, Shortcuts and Settings. The app, the widget, the Sync Health Data action and its Siri phrases, notifications, and the Health, camera and local network permission texts follow the iPhone's language, or the one set for Life Dashboard under Settings > Life Dashboard > Language; anything else stays English. The data types carry the names the Health app gives them. CI fails on a string without Dutch or German, so the app cannot ship half-translated as 1.2 did

### Changed

- The "Cycle Tracking" toggle is now called "Menstruation", since the other cycle types have toggles of their own
- A plain `http://` address that iOS will refuse (a name like `ha.lan` rather than an IP address or a `.local` name) cannot be paired, and the sheet says what to use instead; a delivery that iOS refuses for plain HTTP is no longer retried
- Adding a webhook URL that is already in the list no longer adds it twice
- The interval is the minimum time between automatic syncs, HealthKit-triggered ones included; before, it only moved the nightly background task
- Opening the app no longer syncs every time: it syncs when the schedule says a sync is due, and never in quiet hours. Sync Now always syncs
- The background processing task sends what is new instead of the last seven days; Sync Now keeps the full resend
- The Sync Health Data action sends what is queued and what is new instead of the last seven days, and on a locked iPhone says it is locked instead of "No new health data to sync"
- Every sync publishes to MQTT, the automatic ones and the Sync Health Data action included, with the latest value of each type that has new records, once a type that fell behind has caught up; before, only a full sync did. The status line under Sync Now names MQTT next to the webhooks
- A queued payload is retried automatically outside quiet hours only; Retry Now always retries
- The About screen says settings stay on your device unless you export them
- The app looks like the Android app: its brand green and card layout, rows with a tinted symbol and a subtitle that says their state, a green header on the Health tab, the Sync Now pill with View, Test ping and Backfill tiles, and log rows with a Delivered, Published or Failed pill. Navigation, controls, type and backgrounds stay the iPhone's own, with Dynamic Type and dark mode. Green text uses a darker green than Android's, and text on green is dark instead of white, so both stay readable
- Log rows, the Sync Now result, the sync history and the MQTT status still store the app's own messages in English, as the Android app does, so an export reads the same on every phone, but show them in the iPhone's language. Error text from a server or from iOS is shown as it came
- The time in a CSV log export is written as `2026-09-30 14:05:00`, as the Android app writes it, instead of in the iPhone's date style
- The Health tab follows the Android app's order in three cards: Data Types and Sync Schedule, Webhook (URLs, pairing scanner, custom headers and signing secret) and MQTT, Advanced (Daily totals in payload) and Notifications
- About moved from the tab bar to an (i) button on the Health and Logs tabs, as in the Android app, and shows the Android app's About page: the heartbeat mark on the dark brand ground, Apple Health, Destinations, Privacy & Security and Backup & restore. The row that linked to the Android app is gone
- The app icon is the Android app's heartbeat mark, with dark and tinted versions for iOS 18, rendered from `docs/brand/app-icon.html`
- The widget uses the brand colours, marks the last sync with a symbol and says "Synced 14:32" like the Android widget
- A pairing link closes About and the settings backup's sheets, so the pairing sheet can open

### Fixed

- An iPhone set up with an MQTT broker and no webhook URL never published, although the first-run setup offers the broker as a destination of its own. MQTT alone now counts, as in the Android app: Sync Now is available, and the HealthKit observers and background tasks start as soon as a broker or webhook URL is set, without reopening the app. Nothing is queued for MQTT, and deletions are not read without a webhook, since a sensor has no record to withdraw. A webhook URL added later gets what is new from then on; Sync Now or Backfill History sends what came before. A broker that does not answer, or a LAN address dialled from outside the LAN, now fails after 10 seconds instead of holding up every sync behind it
- The background refresh and processing tasks were never scheduled, because the background modes they need were missing; iOS refused every request without a visible error
- A HealthKit wakeup released HealthKit before its sync had started, so iOS could suspend the app mid-sync, and a wakeup that arrived while a sync was sending cancelled it, which logged a failure and sent the payload twice
- Two retries of the queue at the same time, such as at launch and when the app became active, posted each queued payload twice
- A retried payload that got through did not count for the widget and did not end the failure streak
- A background task that ran out of time could stay open until iOS ended the app
- A full sync on a locked iPhone said "No data to sync"; it now says the iPhone is locked
- A type with more new records than one sync may send (1000 heart rate or step samples, 200 of most other types) lost the rest: the sync moved past them and never read them again. The next sync now continues where the last one stopped, until it has caught up. Total calories, blood pressure and nutrition, which combine several HealthKit types, now keep a sync position for each of them instead of one shared position that could skip records of the others
- Two incremental syncs that started close together, for instance when the app opened while HealthKit reported new data, could both save their sync position and leave the later one without the point where the other had to continue, which skipped those records. Only one incremental sync runs at a time now, and one that is asked for meanwhile is added to it
- The Logs tab counted the records of failed deliveries as sent
- A failed Apple Health read showed up under the first webhook URL, which was never contacted; the entry now says Apple Health
- One log entry the app could not read emptied the whole log

### Security

- An address added by pairing gets none of the custom headers, and queued payloads no longer go to an address that has been removed since

## [1.3.0] - 2026-08-27

### Added

- MQTT publishing with Home Assistant Discovery: every enabled data type appears automatically as a sensor in Home Assistant, via a dependency-free built-in MQTT 3.1.1 client
- At-a-glance dashboard card on the Health screen: records today, lifetime records, last sync status, and a 7-day steps sparkline from HealthKit daily statistics

### Changed

- App Transport Security now permits plain HTTP to local network hosts only, so self-hosted receivers and brokers on the LAN work without TLS; internet traffic stays HTTPS

### Removed

- The half-finished Dutch localization; the app is English-only, matching the Android companion app

## [1.2.0] - 2026-08-26

### Added

- Local notification after repeated sync failures, with an in-app toggle and threshold (3/5/10)
- Dutch (nl) localization
- SwiftLint, OpenSSF Scorecard, and workflow hardening in CI
- Security policy, code of conduct, contributing guide, and issue/PR templates

### Changed

- All managers are now clean under Swift strict concurrency checking
- Webhook payloads cross the actor boundary as serialized data, removing a redundant decode/encode round trip in the retry queue

## [1.1.0] - 2026-08-26

### Added

- HMAC payload signing (`X-Signature`) compatible with the Android companion app
- Cycle tracking: menstruation flow records plus periods derived from consecutive flow days
- Record `uuid` and `source` on every payload record for server-side deduplication
- Home screen widget with last sync result and records delivered today
- "Sync Health Data" action for the Shortcuts app and Siri
- Send Test Ping button to verify webhook configuration
- Redesigned About screen with version info, feature overview, and a couple of easter eggs
- App icon, privacy manifest, and accessibility labels
- Unit test target (25 tests) running in CI, plus CodeQL analysis

### Changed

- Only transient webhook failures (network, timeout, 408, 429, 5xx) are retried; permanent client errors fail fast
- Sync batches are capped per data type, oldest first, so payloads stay bounded and later syncs catch up
- A read failure in one data type no longer fails the whole sync
- Sleep stage values now match the Android app (`deep` instead of `STAGE_TYPE_DEEP`)
- Webhook secrets moved from UserDefaults to the iOS Keychain
- Webhook logs moved to file storage with iOS file protection and capped payload snapshots
- Webhook timeout raised from 10s to 30s
- Data preview no longer blocks the UI on large payloads

## [1.0.0] - 2026-08-25

### Added

- Initial release: syncs 21 HealthKit data types to user-configured webhooks
- Background sync via HealthKit observers, app refresh, and processing tasks
- Offline queue with retries and exponential backoff
- Webhook logs with CSV/JSON export and payload preview

[Unreleased]: https://github.com/owen282000/life-dashboard-companion-app-ios/compare/1.5.0...HEAD
[1.5.0]: https://github.com/owen282000/life-dashboard-companion-app-ios/compare/1.4.1...1.5.0
[1.4.1]: https://github.com/owen282000/life-dashboard-companion-app-ios/compare/1.4.0...1.4.1
[1.4.0]: https://github.com/owen282000/life-dashboard-companion-app-ios/compare/1.3.0...1.4.0
[1.3.0]: https://github.com/owen282000/life-dashboard-companion-app-ios/compare/1.2.0...1.3.0
[1.2.0]: https://github.com/owen282000/life-dashboard-companion-app-ios/compare/1.1.0...1.2.0
[1.1.0]: https://github.com/owen282000/life-dashboard-companion-app-ios/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/owen282000/life-dashboard-companion-app-ios/releases/tag/1.0.0
