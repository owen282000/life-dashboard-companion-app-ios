#!/bin/bash
# Captures the app screens for the App Store screenshots in docs/brand/app-store/raw/, at the
# native size of a 6.9 inch iPhone (iPhone 17 Pro Max, 1320x2868), uncropped: the panorama in
# docs/brand/app-store/panorama.html puts them in device frames.
#
# The store variant of scripts/screenshots.sh: its own simulator (ld-store-shots), dark,
# in one of the app's languages with 24-hour times, the status bar at 9:41, and example data that reads as a phone
# in use: syncs four times a day for a week, a year of backfill, MQTT and a signing secret.
# Everything points at homeassistant.local; nothing is real. "Now" in the example data is
# today at 9:38, so the last sync matches the 9:41 in the status bar.
#
# The pairing sheet needs one tap on iOS's "Open in Life Dashboard?" prompt: the script sends
# Return to the Simulator app, which needs Accessibility access for the terminal.
#
# LANG_CODE picks the language: en (the default, British English) writes to raw/, nl and de
# to raw/nl/ and raw/de/ for the Dutch and German store pages. Units and dates follow the
# locale; the example data is the same in every language.
#
#   scripts/store-screenshots.sh
#   LANG_CODE=nl scripts/store-screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=ld-store-shots
ID=com.owen282000.lifedashboard
LANG_CODE=${LANG_CODE:-en}
case "$LANG_CODE" in
    en) LOCALE=en_GB; OUT=docs/brand/app-store/raw ;;
    nl) LOCALE=nl_NL; OUT=docs/brand/app-store/raw/nl ;;
    de) LOCALE=de_DE; OUT=docs/brand/app-store/raw/de ;;
    *) echo "LANG_CODE must be en, nl or de" >&2; exit 1 ;;
esac
WORK=build/store-shots
mkdir -p "$OUT" "$WORK"

UDID=$(xcrun simctl list devices | grep -m1 "$NAME (" | grep -oE '[0-9A-F-]{36}' || true)
if [ -z "$UDID" ]; then
    UDID=$(xcrun simctl create "$NAME" "iPhone 17 Pro Max")
fi

# Signed ad hoc, as in CI: an unsigned app gets no Keychain on the simulator, so the example
# secret would not show.
xcodebuild build -project LifeDashboardCompanion.xcodeproj -scheme LifeDashboardCompanion \
    -configuration Debug -destination "id=$UDID" -derivedDataPath "$WORK/dd" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -quiet
APP="$WORK/dd/Build/Products/Debug-iphonesimulator/LifeDashboardCompanion.app"

# A fresh boot: an "Open in" prompt left from the last run stays up otherwise.
xcrun simctl shutdown "$UDID" 2>/dev/null || true
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" >/dev/null
xcrun simctl terminate "$UDID" "$ID" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$ID" 2>/dev/null || true
# The Keychain outlives an uninstall on the simulator: without this, secrets and destinations of
# an earlier run would win over the example settings below.
xcrun simctl keychain "$UDID" reset 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
# The simulator keeps an app's defaults across a reinstall: start from none.
xcrun simctl spawn "$UDID" defaults delete "$ID" 2>/dev/null || true
xcrun simctl spawn "$UDID" defaults delete "group.$ID" 2>/dev/null || true
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState discharging --batteryLevel 100 \
    --wifiBars 3 --cellularBars 4 --operatorName ""
xcrun simctl ui "$UDID" appearance dark

# "Now" for the example data: today at 9:38 local time, three minutes before the status bar.
NOW_UTC=$(python3 -c 'import datetime as d; n=d.datetime.now().astimezone().replace(hour=9, minute=38, second=0, microsecond=0); print(n.astimezone(d.timezone.utc).strftime("%Y-%m-%d %H:%M:%S +0000"))')
NOW_ISO=$(python3 -c 'import datetime as d; n=d.datetime.now().astimezone().replace(hour=9, minute=38, second=0, microsecond=0); print(n.astimezone(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')

shot() { # file, launch arguments
    local file=$1; shift
    xcrun simctl terminate "$UDID" "$ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$ID" -AppleLanguages "($LANG_CODE)" -AppleLocale "$LOCALE" "$@" >/dev/null
    sleep 6
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/$file" >/dev/null 2>&1
}

# The setup's destination step, before anything is configured.
shot setup-destination.png -ld.step 1

# Example settings, under the app's own keys.
hexjson() { printf '%s' "$1" | xxd -p | tr -d '\n'; }
write() { xcrun simctl spawn "$UDID" defaults write "$ID" "$@"; }
write health_webhook_urls -data "$(hexjson '["http://homeassistant.local:8123/api/webhook/life_dashboard"]')"
write health_enabled_data_types -data "$(hexjson '["STEPS","SLEEP","HEART_RATE","RESTING_HEART_RATE","HEART_RATE_VARIABILITY","WEIGHT","BODY_FAT","ACTIVE_CALORIES","DISTANCE","EXERCISE","BLOOD_PRESSURE","OXYGEN_SATURATION","RESPIRATORY_RATE","VO2_MAX","MINDFULNESS","HYDRATION"]')"
# Moved into the Keychain by the app at launch, as from an older version.
write health_signing_secret "example-signing-secret-not-real"
write health_schedule_mode TIMES
write health_schedule_times "07:30,12:00,18:00,22:00"
write health_schedule_days "MONDAY,TUESDAY,WEDNESDAY,THURSDAY,FRIDAY,SATURDAY,SUNDAY"
write health_schedule_quiet_from "23:00"
write health_schedule_quiet_to "07:00"
write mqtt_enabled -bool YES
write mqtt_host homeassistant.local
write mqtt_last_status "OK: 19 sensors published at $NOW_ISO"
write failure_notifications_enabled -bool YES
write stats_lifetime_records -int 183946
write stats_total_deliveries -int 1236
write onboarding_completed -bool YES
write ld.ask -bool NO
for DOMAIN in "$ID" "group.$ID"; do
    xcrun simctl spawn "$UDID" defaults write "$DOMAIN" records_today -int 214
    xcrun simctl spawn "$UDID" defaults write "$DOMAIN" records_today_date -date "$NOW_UTC"
    xcrun simctl spawn "$UDID" defaults write "$DOMAIN" last_sync -date "$NOW_UTC"
    xcrun simctl spawn "$UDID" defaults write "$DOMAIN" last_sync_success -bool YES
done

# A week of example log entries as the one-file log of 1.4.1, which LogStore splits into its
# row files at launch: four syncs a day to the webhook and MQTT, and this morning a backfill of
# all history.
DATA=$(xcrun simctl get_app_container "$UDID" "$ID" data)
mkdir -p "$DATA/Library/Application Support"
python3 - "$DATA/Library/Application Support/webhook_logs.json" <<'PY'
import datetime, json, sys, uuid
now = datetime.datetime.now().astimezone().replace(hour=9, minute=38, second=0, microsecond=0)
ref = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
hook = "http://homeassistant.local:8123/api/webhook/life_dashboard"
rows = []
def row(t, success=True, url=hook, code=200, records=12, dest="WEBHOOK", data="health_connect", raw='{"source":"healthkit_ios"}'):
    rows.append({"id": str(uuid.uuid4()), "timestamp": (t - ref).total_seconds(), "url": url,
                 "statusCode": code, "success": success, "dataType": data, "recordCount": records,
                 "rawPayload": raw, "logType": "HEALTH_CONNECT", "destination": dest})
counts = [38, 21, 64, 17, 45, 29, 52, 33, 19, 41, 27, 58, 24, 36, 47, 22, 31, 55, 26, 43]
i = 0
for day in range(6, -1, -1):
    for hour, minute in [(7, 34), (12, 6), (18, 11), (22, 3)]:
        t = (now - datetime.timedelta(days=day)).replace(hour=hour, minute=minute, second=i % 50)
        if t > now:
            continue
        row(t, records=counts[i % len(counts)])
        i += 1
        if day > 0 or hour < 9:
            row(t + datetime.timedelta(seconds=1), url="mqtt://homeassistant.local:1883", code=None, records=19, dest="MQTT")
# A backfill of all history this morning, after the first sync: six years in windows of three days.
start = now.replace(hour=8, minute=15, second=40)
row(start, records=486215, data="health_connect_backfill_run",
    raw=json.dumps({"backfill": True, "length": "all_history", "status": "done", "windows_done": 731, "window_count": 731, "records_sent": 486215}, sort_keys=True))
row(now, records=26)
row(now + datetime.timedelta(seconds=1), url="mqtt://homeassistant.local:1883", code=None, records=19, dest="MQTT")
rows.sort(key=lambda r: r["timestamp"], reverse=True)
json.dump(rows, open(sys.argv[1], "w"))
PY

shot health.png
shot types.png -ld.expand YES -ld.scroll 0
shot webhook.png -ld.expand YES -ld.scroll 0.53
shot logs.png -ld.tab 1
shot about-privacy.png -ld.about YES -ld.scroll 0.5

# No backfill in progress: the simulator has no Health data and no Health access, so a
# backfill stored as running resumes at launch and stops at once on the first read.

# The pairing sheet, when there is a Simulator app to send the Return to. Xcode 26.5 has none
# (the simulator runs headless), and the "Open in" prompt would stay up: then it is skipped.
if open -a Simulator 2>/dev/null; then
    shot pairing-base.png
    xcrun simctl openurl "$UDID" "lifedashboard://pair#v=1&url=http%3A%2F%2Fhomeassistant.local%3A8123%2Fapi%2Fwebhook%2F3f9c2a7e51b84d06a1e2c9d8b7f4e5a1&secret=0123456789abcdef&name=Home%20Assistant"
    sleep 3
    osascript -e 'tell application "Simulator" to activate' -e 'delay 1' \
        -e 'tell application "System Events" to keystroke return' || echo "Tap Open in the Simulator"
    sleep 4
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/pairing.png" >/dev/null 2>&1
    rm "$OUT/pairing-base.png"
else
    echo "No Simulator app: skipped the pairing sheet"
fi
xcrun simctl terminate "$UDID" "$ID" 2>/dev/null || true

echo "Wrote $(ls "$OUT"/*.png | wc -l | tr -d ' ') captures to $OUT. Look at every one at full size."
