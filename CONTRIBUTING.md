# Contributing

Thanks for your interest in improving Life Dashboard Companion for iOS!

## Getting Started

1. Fork and clone the repository
2. Open `LifeDashboardCompanion.xcodeproj` in Xcode 15 or newer
3. Select your own development team under Signing & Capabilities
4. Build and run on a real iPhone (HealthKit needs real data; the simulator is fine for UI work and unit tests)

## Development Guidelines

- **Run the tests** before opening a PR:

  ```bash
  xcodebuild test -project LifeDashboardCompanion.xcodeproj -scheme LifeDashboardCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
  ```

- **Payload compatibility matters.** The JSON payload format is shared with the [Android companion app](https://github.com/owen282000/life-dashboard-companion-app); both apps feed the same backends. Changes to payload keys or value formats need a very good reason and matching documentation in the README.
- **Keep pure logic testable.** Sync logic that does not need HealthKit lives in small, dependency-free types (see `SleepSessionBuilder`, `SyncLimits`, `WebhookRetryPolicy`); follow that pattern so it stays unit-testable.
- **Secrets never go in UserDefaults.** Use `KeychainStore` for anything sensitive.
- **Commit messages** follow the conventional style used in the history: `feat:`, `fix:`, `docs:`, `ci:`, `build:`, `test:`, `chore:`.

## Version tags

If you push version tags, enable the repo's git hooks once:

```bash
git config core.hooksPath .githooks
```

Tags must be strict semver (X.Y.Z), higher than the previous tag, and match `MARKETING_VERSION` in the Xcode project.

## Opening a Pull Request

1. Create a feature branch (`git checkout -b feature/amazing-feature`)
2. Make your changes, with tests where it makes sense
3. Make sure the build and tests pass
4. Open a PR describing what changed and why

Small, focused PRs are much easier to review than big ones. When in doubt, open an issue first to discuss the direction.
