# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Six more data types, with the Android app's payload keys and fields: VO2 Max, Basal Body Temperature, Intermenstrual Bleeding, Ovulation Test, Cervical Mucus and Sexual Activity. Each starts off and asks for its own permission
- MQTT sensors for VO2 Max and Basal Body Temperature, named as in the Android app; the cycle tracking types stay webhook-only
- Backfill History on the Health tab sends the last 30, 90 or 365 days of every enabled type to your webhooks, in 3-day windows, oldest first, like the Android app's backfill and with the same payload fields (`backfill`, `window_start`, `window_end`, `window_complete`). The records are the same as a sync sends, uuid included, so a receiver deduplicates the overlap. Each sleep session and menstruation period goes out once and whole, in the window it ends or starts in. Progress is kept per window: Pause stops after the chunk in flight, and Resume continues at the first window that was not delivered in full. It runs while the app is open, and the screen stays on meanwhile; iOS pauses it shortly after you leave the app or lock the iPhone, since Health data can't be read while it is locked, and it continues when you come back within a day. On iOS 26 it runs as a continued processing task instead, which keeps going after you switch apps and shows its progress in the system UI, as long as the iPhone stays unlocked. A failed delivery stops it until you tap Resume; backfill payloads never go into the retry queue or to MQTT. Sync Now is unavailable while a backfill runs. iOS payloads always say `window_complete: false`: HealthKit does not tell an app that it may not read a type, so the app cannot vouch that a window is complete
- Deleting a record in Apple Health now reaches your webhook. The app follows HealthKit's own record of deletions and names the records that are gone in `deleted_records`, in the same shape as the Android app, so a receiver can drop exactly those. HealthKit edits by deleting a record and saving a new one under a new uuid, so until now every edit left the old record on the receiver next to the new one
- A sync whose only change is a deletion, which is what removing a meal without adding one looks like, sends a payload carrying the deletion and no records, and reports it as a delivery of 0 records instead of saying there was no new data. Deletions are kept until a payload carrying them has been delivered or queued for retry
- Types whose deletions a payload cannot vouch for, because HealthKit did not answer in time, could not be read, or was last read more than a week ago, are named in `deletions_unavailable`
- Every health payload with records carries `daily_totals` with the Android app's schema: per local day, for today and the two days before, the steps, distance, active and total calories as the Health app counts them, with overlapping iPhone and Watch samples counted once. A backfill payload carries every whole day of its window. A day or field without data is left out, never sent as 0. On iOS `distance_meters` is walking and running distance, and `total_calories` is resting plus active energy, only sent on days with resting energy (usually an Apple Watch). A switch, **Daily totals in payload**, turns it off; it is on by default

### Changed

- The "Cycle Tracking" toggle is now called "Menstruation", since the other cycle types have toggles of their own

### Fixed

- The background refresh and processing tasks were never scheduled, because the background modes they need were missing; iOS refused every request without a visible error
- A HealthKit wakeup released HealthKit before its sync had started, so iOS could suspend the app mid-sync, and a wakeup that arrived while a sync was sending cancelled it, which logged a failure and sent the payload twice
- Two retries of the queue at the same time, such as at launch and when the app became active, posted each queued payload twice
- A retried payload that got through did not count for the widget and did not end the failure streak
- A background task that ran out of time could stay open until iOS ended the app
- A full sync on a locked iPhone said "No data to sync"; it now says the iPhone is locked
- A type with more new records than one sync may send (1000 heart rate or step samples, 200 of most other types) lost the rest: the sync moved past them and never read them again. The next sync now continues where the last one stopped, until it has caught up. Total calories, blood pressure and nutrition, which combine several HealthKit types, now keep a sync position for each of them instead of one shared position that could skip records of the others
- Two incremental syncs that started close together, for instance when the app opened while HealthKit reported new data, could both save their sync position and leave the later one without the point where the other had to continue, which skipped those records. Only one incremental sync runs at a time now, and one that is asked for meanwhile is added to it

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

[Unreleased]: https://github.com/owen282000/life-dashboard-companion-app-ios/compare/1.2.0...HEAD
[1.2.0]: https://github.com/owen282000/life-dashboard-companion-app-ios/compare/1.1.0...1.2.0
[1.1.0]: https://github.com/owen282000/life-dashboard-companion-app-ios/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/owen282000/life-dashboard-companion-app-ios/releases/tag/1.0.0
