#!/bin/bash
# Captures the app screens for the App Store screenshots in store-assets/raw/ (not in git), at the
# native size of a 6.9 inch iPhone (iPhone 17 Pro Max, 1320x2868), uncropped: the panorama in
# docs/brand/app-store/panorama.html puts them in device frames.
#
# The store variant of scripts/screenshots.sh: its own simulator (ld-store-shots), dark, in one
# of the app's languages, the status bar at 9:41, and example data that reads as a phone in use:
# the Essentials selected, syncs four times a day for a week to Home Assistant, a webhook on
# n8n.example.com and MQTT, a backfill of all history. The Today figures are the ones on the Home Assistant cards in
# docs/brand/app-store/ha/. Everything points at homeassistant.local or example.com; nothing is real. The last
# sync is at 9:38. "3 min ago" on Home comes from the app's clock, so a small library loaded at
# launch moves that clock to 9:41 today, without a line in the app: the images come out the same at any hour.
#
# LANG_CODE picks the language: en (the default, British English) writes to store-assets/raw/, the
# others to store-assets/raw/<code>/ for their store pages. Units and dates follow the locale; the example data is the
# same in every language. Arabic uses ar_AE: Gregorian dates and Western digits, the same digits
# as the literal ones in its sentences.
#
#   scripts/store-screenshots.sh
#   LANG_CODE=nl scripts/store-screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=ld-store-shots
ID=com.owen282000.lifedashboard
LANG_CODE=${LANG_CODE:-en}
case "$LANG_CODE" in
    en) LOCALE=en_GB ;;
    nl) LOCALE=nl_NL ;;
    de) LOCALE=de_DE ;;
    fr) LOCALE=fr_FR ;;
    es) LOCALE=es_ES ;;
    it) LOCALE=it_IT ;;
    pt-BR) LOCALE=pt_BR ;;
    ja) LOCALE=ja_JP ;;
    ar) LOCALE=ar_AE ;;
    hi) LOCALE=hi_IN ;;
    zh-Hans) LOCALE=zh_CN ;;
    *) echo "LANG_CODE must be en, nl, de, fr, es, it, pt-BR, ja, ar, hi or zh-Hans" >&2; exit 1 ;;
esac
OUT=store-assets/raw
[ "$LANG_CODE" = en ] || OUT=$OUT/$LANG_CODE
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

# The status bar follows the simulator's own region: a 24-hour one writes 09:41. The app gets its
# language and region at launch, so this does not reach what is inside it.
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" >/dev/null
xcrun simctl spawn "$UDID" defaults write -g AppleLocale en_US

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

# Moves the app's wall clock by LD_CLOCK_OFFSET seconds. Timers and animations run on another
# clock and are left alone.
cat > "$WORK/clock.c" <<'C'
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>
#define INTERPOSE(mine, theirs) \
    __attribute__((used, section("__DATA,__interpose"))) static const struct { const void *a, *b; } i_##theirs = { (const void *)mine, (const void *)theirs };
static long offset;
__attribute__((constructor)) static void start(void) { const char *s = getenv("LD_CLOCK_OFFSET"); if (s) offset = atol(s); }
static int my_gettimeofday(struct timeval *t, void *z) { int r = gettimeofday(t, z); if (t) t->tv_sec += offset; return r; }
static int my_clock_gettime(clockid_t c, struct timespec *t) { int r = clock_gettime(c, t); if (c == CLOCK_REALTIME) t->tv_sec += offset; return r; }
static uint64_t my_clock_gettime_nsec_np(clockid_t c) { uint64_t r = clock_gettime_nsec_np(c); return c == CLOCK_REALTIME ? r + offset * 1000000000ULL : r; }
static time_t my_time(time_t *t) { time_t r = time(NULL) + offset; if (t) *t = r; return r; }
static CFAbsoluteTime my_now(void) { return CFAbsoluteTimeGetCurrent() + offset; }
INTERPOSE(my_gettimeofday, gettimeofday)
INTERPOSE(my_clock_gettime, clock_gettime)
INTERPOSE(my_clock_gettime_nsec_np, clock_gettime_nsec_np)
INTERPOSE(my_time, time)
INTERPOSE(my_now, CFAbsoluteTimeGetCurrent)
C
xcrun -sdk iphonesimulator clang -dynamiclib -arch arm64 -mios-simulator-version-min=17.0 \
    -framework CoreFoundation -o "$WORK/clock.dylib" "$WORK/clock.c"
CLOCK_LIB="$PWD/$WORK/clock.dylib"

# "Now" for the example data: three minutes before the status bar.
NOW_UTC=$(python3 -c 'import datetime as d; print(d.datetime.now().astimezone().replace(hour=9, minute=38, second=0, microsecond=0).astimezone(d.timezone.utc).strftime("%Y-%m-%d %H:%M:%S +0000"))')
NOW_ISO=$(python3 -c 'import datetime as d; print(d.datetime.now().astimezone().replace(hour=9, minute=38, second=0, microsecond=0).astimezone(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')

shot() { # file, launch arguments
    local file=$1; shift
    xcrun simctl terminate "$UDID" "$ID" 2>/dev/null || true
    local offset
    offset=$(python3 -c 'import datetime as d; n = d.datetime.now().astimezone(); print(int((n.replace(hour=9, minute=41, second=0, microsecond=0) - n).total_seconds()))')
    SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$CLOCK_LIB" SIMCTL_CHILD_LD_CLOCK_OFFSET="$offset" \
    xcrun simctl launch "$UDID" "$ID" -AppleLanguages "($LANG_CODE)" -AppleLocale "$LOCALE" \
        -ld.demoSteps "5200,7100,9800,8400,6300,10900,6482" \
        -ld.demoSleep "412,388,455,431,402,467,407" \
        -ld.demoRest "59,57,59,56,58,57,58" \
        -ld.demoWeight "82.9,82.8,82.7,82.7,82.6,82.5,82.4" "$@" >/dev/null
    sleep 6
    xcrun simctl io "$UDID" screenshot --type=png "$OUT/$file" >/dev/null 2>&1
    # Now and then the first frame is still black: a black PNG is tiny, so take it again.
    if [ "$(stat -f %z "$OUT/$file")" -lt 100000 ]; then
        sleep 4
        xcrun simctl io "$UDID" screenshot --type=png "$OUT/$file" >/dev/null 2>&1
    fi
}

# The setup's destination step, before anything is configured.
shot setup-destination.png -ld.step 1

# Example settings, under the app's own keys.
hexjson() { printf '%s' "$1" | xxd -p | tr -d '\n'; }
write() { xcrun simctl spawn "$UDID" defaults write "$ID" "$@"; }
write health_webhook_urls -data "$(hexjson '["http://homeassistant.local:8123/api/webhook/life_dashboard","https://n8n.example.com/webhook/health"]')"
write health_enabled_data_types -data "$(hexjson '["STEPS","DISTANCE","ACTIVE_CALORIES","SLEEP","HEART_RATE","RESTING_HEART_RATE","WEIGHT","EXERCISE"]')"
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
# row files at launch: four syncs a day to MQTT, Home Assistant and the webhook, and this morning
# a backfill of all history. The newest row is the webhook, for -ld.route logDetail; its payload
# has the fields of docs/webhook.md.
DATA=$(xcrun simctl get_app_container "$UDID" "$ID" data)
mkdir -p "$DATA/Library/Application Support"
python3 - "$DATA/Library/Application Support/webhook_logs.json" <<'PY'
import datetime, json, sys, uuid
now = datetime.datetime.now().astimezone().replace(hour=9, minute=38, second=0, microsecond=0)
ref = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
hook = "http://homeassistant.local:8123/api/webhook/life_dashboard"
rows = []
other = "https://n8n.example.com/webhook/health"
mqtt = "mqtt://homeassistant.local:1883"
def payload(records, t):
    stamp = t.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    def rec(**fields):
        return {**fields, "source": "iPhone", "uuid": str(uuid.uuid5(uuid.NAMESPACE_DNS, stamp + str(fields))).upper()}
    steps = [rec(count=212 + n * 37 % 300, start_time=stamp, end_time=stamp) for n in range(max(records - 3, 0))]
    return json.dumps({"source": "healthkit_ios", "timestamp": stamp, "timezone": "Europe/Amsterdam",
                       "app_version": "1.11.0", "sequence": 1842,
                       "resting_heart_rate": [rec(bpm=58, time=stamp)], "heart_rate": [rec(bpm=71, time=stamp)],
                       "weight": [rec(kilograms=82.4, time=stamp)], "steps": steps}, separators=(",", ":"))
def row(t, success=True, url=hook, code=200, records=12, dest="WEBHOOK", data="health_connect", raw=None):
    raw = raw or payload(records, t)
    rows.append({"id": str(uuid.uuid4()), "timestamp": (t - ref).total_seconds(), "url": url,
                 "statusCode": code, "success": success, "dataType": data, "recordCount": records,
                 "rawPayload": raw, "logType": "HEALTH_CONNECT", "destination": dest})
counts = [38, 21, 64, 17, 45, 29, 52, 33, 19, 41, 27, 58, 24, 36, 47, 22, 31, 55, 26, 43]
def sync(t, records):
    row(t, url=mqtt, code=None, records=19, dest="MQTT")
    row(t + datetime.timedelta(seconds=1), records=records)
    row(t + datetime.timedelta(seconds=2), url=other, records=records)
i = 0
for day in range(6, -1, -1):
    for hour, minute in [(7, 34), (12, 6), (18, 11), (22, 3)]:
        t = (now - datetime.timedelta(days=day)).replace(hour=hour, minute=minute, second=i % 50)
        # Today only the first sync, whatever the hour: the panels crop the newest rows.
        if t > now or (day == 0 and hour > 7):
            continue
        sync(t, counts[i % len(counts)])
        i += 1
# A backfill of all history this morning, after the first sync: six years in windows of three days.
start = now.replace(hour=8, minute=15, second=40)
row(start, records=486215, data="health_connect_backfill_run",
    raw=json.dumps({"backfill": True, "length": "all_history", "status": "done", "windows_done": 731, "window_count": 731, "records_sent": 486215}, sort_keys=True))
sync(now, 26)
rows.sort(key=lambda r: r["timestamp"], reverse=True)
json.dump(rows, open(sys.argv[1], "w"))
PY

shot health.png
shot what.png -ld.route whatToSend
shot logs.png -ld.tab 1
shot delivery.png -ld.route logDetail
shot webhook.png -ld.route webhookDestination
shot about.png -ld.about YES
shot paired.png -ld.route pairing -ld.pairPhase confirmed

# No backfill in progress: the simulator has no Health data and no Health access, so a
# backfill stored as running resumes at launch and stops at once on the first read.
xcrun simctl terminate "$UDID" "$ID" 2>/dev/null || true

echo "Wrote $(ls "$OUT"/*.png | wc -l | tr -d ' ') captures to $OUT. Look at every one at full size."
