#!/bin/bash
# Takes the README and docs screenshots in docs/screenshots from a Debug build in the
# simulator: dark, English with 24-hour times, the status bar cropped off, 1080 pixels wide.
#
# The simulator has no Health data, so the app gets example settings and a week of example
# log entries instead (homeassistant.local, nothing real). The Debug launch arguments -ld.tab,
# -ld.about, -ld.expand and -ld.scroll open each page. The pairing sheet needs one tap on
# iOS's "Open in Life Dashboard?" prompt: the script sends Return to the Simulator app, which
# needs Accessibility access for the terminal (System Settings > Privacy & Security).
#
#   scripts/screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=ld-screenshots
ID=com.owen282000.lifedashboard
OUT=docs/screenshots
WORK=build/screenshots
mkdir -p "$WORK/raw"

UDID=$(xcrun simctl list devices | grep -m1 "$NAME (" | grep -oE '[0-9A-F-]{36}' || true)
if [ -z "$UDID" ]; then
    UDID=$(xcrun simctl create "$NAME" "iPhone 17 Pro")
fi

xcodebuild build -project LifeDashboardCompanion.xcodeproj -scheme LifeDashboardCompanion \
    -configuration Debug -destination "id=$UDID" -derivedDataPath "$WORK/dd" \
    CODE_SIGNING_ALLOWED=NO -quiet
APP="$WORK/dd/Build/Products/Debug-iphonesimulator/LifeDashboardCompanion.app"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" >/dev/null
xcrun simctl terminate "$UDID" "$ID" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --wifiBars 3 --cellularBars 4 --operatorName ""
xcrun simctl ui "$UDID" appearance dark

# Example settings, under the app's own keys.
hexjson() { printf '%s' "$1" | xxd -p | tr -d '\n'; }
write() { xcrun simctl spawn "$UDID" defaults write "$ID" "$@"; }
write health_webhook_urls -data "$(hexjson '["http://homeassistant.local:8123/api/webhook/life_dashboard"]')"
write health_enabled_data_types -data "$(hexjson '["STEPS","SLEEP","HEART_RATE","RESTING_HEART_RATE","HEART_RATE_VARIABILITY","WEIGHT","ACTIVE_CALORIES","DISTANCE","EXERCISE","BLOOD_PRESSURE","OXYGEN_SATURATION","RESPIRATORY_RATE"]')"
write health_schedule_mode TIMES
write health_schedule_times "07:30,12:00,18:00,22:00"
write health_schedule_days "MONDAY,TUESDAY,WEDNESDAY,THURSDAY,FRIDAY,SATURDAY,SUNDAY"
write health_schedule_quiet_from "23:00"
write health_schedule_quiet_to "07:00"
write mqtt_enabled -bool YES
write mqtt_host homeassistant.local
write failure_notifications_enabled -bool YES
write stats_lifetime_records -int 48210
write stats_total_deliveries -int 1236
write onboarding_completed -bool YES
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for DOMAIN in "$ID" "group.$ID"; do
    xcrun simctl spawn "$UDID" defaults write "$DOMAIN" records_today -int 214
    xcrun simctl spawn "$UDID" defaults write "$DOMAIN" records_today_date -date "$NOW"
    xcrun simctl spawn "$UDID" defaults write "$DOMAIN" last_sync -date "$NOW"
    xcrun simctl spawn "$UDID" defaults write "$DOMAIN" last_sync_success -bool YES
done

# A week of example log entries in the LogStore format: four syncs a day, one failure, and an
# MQTT publish with the last one.
DATA=$(xcrun simctl get_app_container "$UDID" "$ID" data)
mkdir -p "$DATA/Library/Application Support"
python3 - "$DATA/Library/Application Support/webhook_logs.json" <<'PY'
import datetime, json, sys, uuid
now = datetime.datetime.now().astimezone().replace(second=0, microsecond=0)
ref = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
hook = "http://homeassistant.local:8123/api/webhook/life_dashboard"
rows = []
def row(t, success=True, url=hook, code=200, records=12, dest="WEBHOOK", error=None):
    entry = {"id": str(uuid.uuid4()), "timestamp": (t - ref).total_seconds(), "url": url,
             "statusCode": code, "success": success, "errorMessage": error,
             "dataType": "health_connect", "recordCount": records,
             "rawPayload": '{"source":"healthkit_ios"}', "logType": "HEALTH_CONNECT",
             "destination": dest}
    rows.append({k: v for k, v in entry.items() if v is not None})
counts = [38, 21, 64, 17, 45, 29, 52, 33, 19, 41, 27, 58, 24, 36, 47, 22, 31, 55, 26, 43]
i = 0
for day in range(6, -1, -1):
    for hour, minute in [(7, 34), (12, 6), (18, 11), (22, 3)]:
        t = (now - datetime.timedelta(days=day)).replace(hour=hour, minute=minute)
        if t > now:
            continue
        failed = day == 3 and hour == 12
        row(t, success=not failed, code=502 if failed else 200,
            error="HTTP 502" if failed else None, records=counts[i % len(counts)])
        i += 1
t = now - datetime.timedelta(minutes=4)
row(t, url="mqtt://homeassistant.local:1883", code=None, records=17, dest="MQTT")
row(t + datetime.timedelta(seconds=2), records=26)
rows.sort(key=lambda r: r["timestamp"], reverse=True)
json.dump(rows, open(sys.argv[1], "w"))
PY

shot() { # file, launch arguments
    local file=$1; shift
    xcrun simctl terminate "$UDID" "$ID" 2>/dev/null || true
    xcrun simctl launch "$UDID" "$ID" -AppleLanguages "(en)" -AppleLocale en_GB "$@" >/dev/null
    sleep 6
    xcrun simctl io "$UDID" screenshot --type=png "$WORK/raw/$file" >/dev/null 2>&1
}
shot apple-health.png
shot sync-schedule.png -ld.expand YES -ld.scroll 0.47
shot mqtt.png -ld.expand YES -ld.scroll 0.715
shot logs.png -ld.tab 1
shot about.png -ld.about YES

shot pairing-base.png
xcrun simctl openurl "$UDID" "lifedashboard://pair#v=1&url=http%3A%2F%2Fhomeassistant.local%3A8123%2Fapi%2Fwebhook%2F3f9c2a7e51b84d06a1e2c9d8b7f4e5a1&secret=0123456789abcdef&name=Home%20Assistant"
open -a Simulator
sleep 3
osascript -e 'tell application "Simulator" to activate' -e 'delay 1' \
    -e 'tell application "System Events" to keystroke return' || echo "Tap Open in the Simulator"
sleep 4
xcrun simctl io "$UDID" screenshot --type=png "$WORK/raw/home-assistant.png" >/dev/null 2>&1
rm "$WORK/raw/pairing-base.png"

# Crop the status bar and scale to 1080 pixels wide, like the Android app's screenshots.
cat > "$WORK/crop.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
let source = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: args[1])))!.cgImage!
let top = Int(args[3])!
let cropped = source.cropping(to: CGRect(x: 0, y: top, width: source.width, height: source.height - top))!
let width = 1080
let height = Int((Double(cropped.height) * Double(width) / Double(cropped.width)).rounded())
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.interpolationQuality = .high
context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: args[2]))
SWIFT
for raw in "$WORK"/raw/*.png; do
    swift "$WORK/crop.swift" "$raw" "$OUT/$(basename "$raw")" 170
done
xcrun simctl terminate "$UDID" "$ID" 2>/dev/null || true
echo "Wrote $(ls "$WORK"/raw | wc -l | tr -d ' ') screenshots to $OUT. Look at every one at full size before committing."
