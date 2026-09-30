# Contributing

Thanks for your interest in improving Life Dashboard Companion for iOS!

## Getting Started

1. Fork and clone the repository
2. Open `LifeDashboardCompanion.xcodeproj` in Xcode 26 or newer
3. Set your own team, bundle identifiers and app group, as [docs/usage.md](docs/usage.md#build-and-install) describes
4. Build and run on a real iPhone (HealthKit needs real data; the simulator is fine for UI work and unit tests)

## Development Guidelines

- **Run the tests** before opening a PR:

  ```bash
  xcodebuild test -project LifeDashboardCompanion.xcodeproj -scheme LifeDashboardCompanion \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -testLanguage en -testRegion US
  ```

- **UI text comes in English, Dutch and German.** Write English literals the String Catalogs
  can pick up, never concatenate a sentence from pieces, and add the Dutch and German in the
  same commit: `scripts/l10n.sh sync` lists what is missing, `scripts/l10n.sh check` fails the
  way CI does. The rules and the glossary are in [docs/localization.md](docs/localization.md).

- **Payload compatibility matters.** The JSON payload format is shared with the [Android companion app](https://github.com/owen282000/life-dashboard-companion-app); both apps feed the same backends. Changes to payload keys or value formats need a very good reason and matching documentation in [docs/webhook.md](docs/webhook.md).
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
