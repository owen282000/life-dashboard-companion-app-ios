# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
