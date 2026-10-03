# Building and contributing

## Build

Installing the app on your own iPhone, with your own team and identifiers, is described in [usage.md](usage.md#build-and-install). For development, the simulator is enough for the screens and the unit tests:

```bash
xcodebuild test -project LifeDashboardCompanion.xcodeproj -scheme LifeDashboardCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -testLanguage en -testRegion US CODE_SIGNING_ALLOWED=NO
swiftlint --strict
```

CI (`.github/workflows/build.yml`) builds with Xcode 26.6, unsigned, checks the translations, runs the unit tests in English and the wire-format tests again in German, and runs SwiftLint in strict mode. HealthKit needs a real iPhone for real data: the simulator has none, and background delivery does not work there.

The app has no third-party dependencies, and should stay that way.

## Project layout

| Path | Contents |
|---|---|
| `LifeDashboardCompanion/Managers/` | Sync, HealthKit reads, webhook and MQTT delivery, background tasks, schedule, backfill, settings backup |
| `LifeDashboardCompanion/Models/` | Data types, log entries, pairing links, sync results |
| `LifeDashboardCompanion/Screens/` | SwiftUI screens and the design kit |
| `LifeDashboardWidget/` | The home screen widget |
| `LifeDashboardCompanionTests/` | Unit tests |
| `docs/` | Documentation, screenshots and the brand sources |
| `scripts/` | The translation check, the screenshot script and the TestFlight build number |
| `.github/workflows/` | Build, release, CodeQL, security and Scorecard workflows |
| `.githooks/` | Optional hook enforcing strict, increasing semver tags |

Sync logic that does not need HealthKit lives in small, dependency-free types (`SleepSessionBuilder`, `SyncLimits`, `SyncSchedule`, `WebhookRetryPolicy`, `MqttSupport`) so it stays unit-testable.

The Xcode project does not use synchronized folders: a new Swift file has to be added to `LifeDashboardCompanion.xcodeproj/project.pbxproj`, to the right target. Adding it in Xcode does that.

## Translations

The app speaks English, Dutch and German, and CI fails on a string without Dutch or German. [localization.md](localization.md) has the loop, the rules and the glossary.

## Releasing

1. Move the `## [Unreleased]` entries in [CHANGELOG.md](../CHANGELOG.md) under a new `## [X.Y.Z]` heading
2. Set `MARKETING_VERSION` in the Xcode project to the same version
3. Tag the release (`git tag X.Y.Z && git push --tags`)

The release workflow checks that the tag is strict semver, higher than the last one and equal to `MARKETING_VERSION`, and creates a GitHub release with generated notes. It publishes no installable build: that needs code signing. To have the same check before a tag leaves your machine, enable the repository's hooks once:

```bash
git config core.hooksPath .githooks
```

For TestFlight, run `scripts/bump-build.sh` before the archive: it gives the app and the widget
the same build number, the number of commits up to HEAD, which App Store Connect needs to be new
for every upload. Restore the project file after the upload.

## Contributing

Contributions are welcome. [CONTRIBUTING.md](../CONTRIBUTING.md) has the full guidelines; the short version:

1. Fork the repository and create a feature branch
2. Make your changes, with tests where it makes sense
3. Run the tests and `swiftlint --strict`
4. Open a Pull Request describing what changed and why

Two things to keep in mind:

- **Payload compatibility matters.** The JSON payload is the [Android app's](https://github.com/owen282000/life-dashboard-companion-app); both feed the same backends and the same Home Assistant integration. A change to payload keys or value formats needs a very good reason, and matching updates to [webhook.md](webhook.md) here and to the Android app's reference.
- **Commit messages** follow the conventional style used in the history: `feat:`, `fix:`, `docs:`, `ci:`, `build:`, `test:`, `chore:`.

## Screenshots

The screenshots in `docs/screenshots` come from a Debug build in the simulator:

```bash
scripts/screenshots.sh
```

It builds the app, installs it on a simulator of its own (`ld-screenshots`, an iPhone 17 Pro), gives it example settings and a week of example log entries, and opens each page with the Debug-only launch arguments:

| Argument | Opens |
|---|---|
| `-ld.tab 1` | the Logs tab |
| `-ld.about YES` | About |
| `-ld.nerd YES` | About with Nerd Stats |
| `-ld.privacy YES` | the privacy policy |
| `-ld.expand YES` | every row on the Health tab |
| `-ld.scroll 0.5` | a long page, scrolled to that fraction |
| `-ld.step 1` | a step of the first-run setup |

The pairing sheet needs a tap on iOS's "Open in Life Dashboard?" prompt, which the script sends as Return to the Simulator app. The screenshots are dark, in English with 24-hour times, without the status bar, and 1080 pixels wide, like the Android app's. The simulator has no Health data, so the numbers on them are examples. Look at every one at full size before you commit it.

## Brand images

`docs/social-preview.png`, the repository's social preview, and the app icon are rendered from HTML with headless Chrome, never drawn by hand or generated. The sources are in `docs/brand/`, with the command in each file's header:

- `banner.html` - the social preview, 1280 by 640, a copy of the Android app's banner
- `app-icon.html` - the app icon, with its dark and tinted versions

After changing the banner, upload the new PNG under the repository's Settings > Social preview; GitHub does not read it from the repository.
