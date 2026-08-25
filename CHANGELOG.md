# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Local notification after repeated sync failures, so silent background problems surface without opening the app
- Dutch (nl) localization
- SwiftLint and OpenSSF Scorecard in CI

### Changed

- All managers are now clean under Swift strict concurrency checking

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

[Unreleased]: https://github.com/owen282000/life-dashboard-companion-app-ios/compare/1.1.0...HEAD
[1.1.0]: https://github.com/owen282000/life-dashboard-companion-app-ios/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/owen282000/life-dashboard-companion-app-ios/releases/tag/1.0.0
