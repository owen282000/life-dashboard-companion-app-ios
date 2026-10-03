# Webhook payload on iOS

The iPhone app sends the Android app's payload: the same keys, fields, units and signing, so one receiver and the Life Dashboard integration serve both phones. The full reference, with an example for every type, is the Android app's [docs/webhook.md](https://github.com/owen282000/life-dashboard-companion-app/blob/main/docs/webhook.md), and [webhook-schema.json](https://github.com/owen282000/life-dashboard-companion-app/blob/main/docs/webhook-schema.json) is the JSON Schema for both apps.

This page lists what an iPhone sends and where it differs, so a receiver can handle both.

## Contents

- [Top-level fields](#top-level-fields)
- [What iOS sends](#what-ios-sends)
- [Per-type notes](#per-type-notes)
- [Daily totals](#daily-totals)
- [Deletions](#deletions)
- [Data resolution](#data-resolution)
- [Backfill](#backfill)
- [What iOS does not send](#what-ios-does-not-send)
- [Delivery, retries and signing](#delivery-retries-and-signing)

## Top-level fields

```json
{
  "timestamp": "2026-02-05T12:00:00Z",
  "app_version": "1.3.0",
  "source": "healthkit_ios",
  "sequence": 42,
  "steps": [
    {
      "count": 1234,
      "start_time": "2026-02-05T08:00:00Z",
      "end_time": "2026-02-05T09:00:00Z",
      "uuid": "5B7A0C2E-8F3D-4B1A-9C6E-2D4F8A1B3C5D",
      "source": "Owen's iPhone"
    }
  ],
  "daily_totals": [
    { "date": "2026-02-05", "steps": 8421, "distance_meters": 6210.4 }
  ]
}
```

`source` at the top is `healthkit_ios`, where the Android app says `health_connect`. Only enabled types with records are included.

`sequence` goes up by one with every payload the iPhone builds, from the same counter for a sync, a payload with only deletions and a backfill chunk, as in the Android app. It is taken when the payload is built and kept while the payload waits in the retry queue, so a retry carries the number it was built with, and it survives restarts and updates. A payload that waited in the queue can arrive after a newer one, and it still holds records that no later payload repeats, so do not ignore it as a whole: apply its records, deduplicated on `uuid`, and use `sequence` to settle the rest. A record from a payload with a lower number than the one that named it in `deleted_records` stays deleted, and `daily_totals` for a date come from the payload with the highest number that carried that date. View and Export take no number. Payloads from 1.5.0 and older have none, so treat a missing one as unknown rather than zero.

Every record carries:

- `uuid`: the HealthKit sample's UUID. It stays the same for the life of the record, so deduplicate on it. A blood pressure reading and a food, which HealthKit keeps as several samples, carry the uuid of one of them (see the notes below); a sleep session and a menstruation period, which HealthKit has no record for, carry one derived from their first sample. Every sync, Sync Now included, sends the records added since the last one, up to each type's cap per sync (1000 records for heart rate, steps and total calories, 500 for heart rate variability and respiratory rate, 200 for the rest), but a backfill sends its range again and a delivery that iOS cut off is sent again from the retry queue, so a record can arrive more than once. HealthKit never edits a record in place: an app that edits one deletes it and saves a new one under a new `uuid`, and the old one is named in [`deleted_records`](#deletions).
- `source`: the name HealthKit gives the app or device that wrote the record (`HKSource.name`), not a package name as on Android. For data the iPhone or Watch records itself, this is the device's name, which often includes the owner's name.

Numbers go out with the decimals their field needs, without the float noise of a unit conversion, rounded half up: 3 for `meters` and `liters`; 2 for `kilograms`, `calories`, `celsius`, `mmol_per_liter`, the nutrient amounts and the `distance_meters`, `active_calories` and `total_calories` of `daily_totals`; 1 for `percentage`, `systolic`, `diastolic`, `rate`, `heart_rate_variability_millis` and `vo2_ml_per_min_per_kg`. That is the Android app's MQTT precision, or more where a value entered in pounds, Fahrenheit, millilitres or millimetres would not survive it. Trailing zeros are dropped, so 97.0 arrives as `97`. Counts, beats per minute and durations are whole numbers.

## What iOS sends

The app has 28 data types. Menstruation sends two keys, so an iPhone can send 29 of the Android app's 33 record keys, with the same fields:

| Key | Fields | Read from HealthKit |
|---|---|---|
| `steps` | `count`, `start_time`, `end_time` | step count |
| `distance` | `meters`, `start_time`, `end_time` | every distance: walking and running, cycling, swimming, wheelchair, downhill snow sports, and from iOS 18 rowing, paddling, cross-country skiing and skating |
| `active_calories` | `calories`, `start_time`, `end_time` | active energy |
| `total_calories` | `calories`, `start_time`, `end_time` | resting and active energy records |
| `exercise` | `type`, `start_time`, `end_time`, `duration_seconds` | workouts |
| `weight` | `kilograms`, `time` | body mass |
| `height` | `meters`, `time` | height |
| `body_temperature` | `celsius`, `time` | body temperature |
| `basal_body_temperature` | `celsius`, `time` | basal body temperature |
| `body_fat` | `percentage`, `time` | body fat percentage |
| `lean_body_mass` | `kilograms`, `time` | lean body mass |
| `heart_rate` | `bpm`, `time` | heart rate |
| `resting_heart_rate` | `bpm`, `time` | resting heart rate |
| `heart_rate_variability` | `heart_rate_variability_millis`, `time` | HRV (SDNN) |
| `blood_pressure` | `systolic`, `diastolic`, `time` | blood pressure readings |
| `blood_glucose` | `mmol_per_liter`, `time` | blood glucose |
| `oxygen_saturation` | `percentage`, `time` | oxygen saturation |
| `respiratory_rate` | `rate`, `time` | respiratory rate |
| `vo2_max` | `vo2_ml_per_min_per_kg`, `time` | VO2 max |
| `sleep` | `session_end_time`, `duration_seconds`, `stages[]` | sleep analysis |
| `hydration` | `liters`, `start_time`, `end_time` | water |
| `nutrition` | `calories`, `protein_grams`, `carbs_grams`, `fat_grams`, `name`, 34 more nutrients, `start_time`, `end_time` | foods, and lone energy, protein, carbohydrate and fat values |
| `mindfulness` | `start_time`, `end_time`, `duration_seconds` | mindful sessions |
| `menstruation_flow` | `flow`, `time` | menstrual flow |
| `menstruation_period` | `start_time`, `end_time` | derived from flow days |
| `intermenstrual_bleeding` | `time` | intermenstrual bleeding |
| `ovulation_test` | `result`, `time` | ovulation test result |
| `cervical_mucus` | `appearance`, `sensation`, `time` | cervical mucus quality |
| `sexual_activity` | `protection_used`, `time` | sexual activity |

The four Android keys an iPhone never sends:

| Android key | Why not |
|---|---|
| `bone_mass` | Apple Health has no bone mass type |
| `body_water_mass` | Apple Health has no body water type |
| `skin_temperature` | Apple Health stores the absolute sleeping wrist temperature, not the change against a baseline that `delta_celsius` carries |
| `basal_metabolic_rate` | Apple Health stores resting energy per interval, not a rate in kcal per day; it goes out as part of `total_calories` |

A type with more new records than one sync may send (1000 for heart rate, steps and total calories, 500 for HRV and respiratory rate, 200 for the rest, as on Android) sends that many, and the next sync continues where this one stopped. Sync Now goes on by itself, as the Android app's sync does: up to 8 payloads in a row while a type is still behind, within 2 minutes. New records go in the order HealthKit saved them; the first week of a newly enabled type goes oldest first.

## Per-type notes

- **Heart rate variability** is SDNN, the measure Apple Health stores. Health Connect stores RMSSD. Both arrive in `heart_rate_variability_millis`, but the two are not the same number.
- **Distance** covers every activity, as Health Connect's does: HealthKit keeps a distance type per kind of activity, and the app reads them all. They do not overlap, so adding them up counts nothing twice. A record does not say which activity it is from.
- **Total calories** are resting plus active energy records, since HealthKit has no total energy type.
- **Blood pressure** is read per reading: the systolic and diastolic values an app saved together, as HealthKit keeps them. The rare app that saves the two values separately gets them paired when they come from that app within a second of each other. A value without its other half is not sent, since the Android schema requires both. `uuid` is the systolic sample's.
- **Nutrition**: a food an app logged, with every nutrient in it, is one record, with its name in `name` when the app gave one. Besides energy, protein, carbohydrates and fat, a food carries the 34 other nutrients HealthKit and Android share, under Android's keys (`dietary_fibre_g`, `sugars_g`, `sodium_mg`, `caffeine_mg` and so on, see [webhook-schema.json](https://github.com/owen282000/life-dashboard-companion-app/blob/main/docs/webhook-schema.json)). HealthKit has no type for trans fat, unsaturated fat, energy from fat, folic acid or `meal_type`. Energy, protein, carbohydrate and fat values saved outside a food are sent too: values from one app with the same time and name become one record when no nutrient repeats, anything else a record per value. Those 34 nutrients are only read from inside a food that also has energy, protein, carbohydrates or fat; a food with none of those four, such as a coffee logged with caffeine only, is not sent. Every nutrient field is optional and left out when the food has no value for it. `uuid` is the uuid of the food's energy sample, else of its protein, carbohydrate or fat sample.
- **Exercise**: `type` is the HealthKit activity in snake_case, such as `running`, `walking`, `downhill_skiing` or `hiit`. Every activity HealthKit has gets a name of its own; `other` is HealthKit's own Other, or an activity from an iOS newer than the app. `duration_seconds` is `end_time` minus `start_time`, pauses included, as on Android; the Health app's workout time leaves pauses out, so it can be shorter. The Android app sends Health Connect's exercise type constant as a string instead, such as `"56"` for running, so a backend that serves both has to handle both.
- **Sleep**: stage samples are grouped into sessions, and a gap of more than 1 hour starts a new session. Stage values are `sleeping`, `light`, `deep`, `rem`, `awake` and `unknown`, which Android sends too, and `in_bed`, which only iOS sends: HealthKit's in bed sample, the time in bed around the stages, not a stage itself. Android's `out_of_bed` and `awake_in_bed` never come from an iPhone. A session's `uuid` comes from its earliest stage, so it stays the same while a night grows at the end: replace the session when it comes back longer. A stage added later to a night that was already sent sends that whole night again. Its `source` is the app or device that recorded most of the night's sleep stages. Each stage carries its own sample's `uuid` and `source`.
- **Menstruation period**: HealthKit has no period record, so periods are derived from consecutive flow days, where a gap of up to 48 hours bridges one missed day. A period's `uuid` comes from its first flow day, as a sleep session's does, and every read looks two weeks back for that day, so the `uuid` stays the same while the period grows at the end: replace the period when it comes back longer, as it does when a flow day is added to it later. It changes when an earlier flow day is logged or the first one is deleted. Its `source` is the first flow day's.
- **Cervical mucus**: HealthKit records no sensation, so `sensation` is always `unknown`, the value Android sends when none was logged.
- **Ovulation test**: `result` is `positive` (LH surge), `high` (estrogen surge), `negative`, `inconclusive` or `unknown`.
- **Sexual activity**: `protection_used` is `protected` or `unprotected` when the writing app recorded it, and `unknown` otherwise.

## Daily totals

When an iPhone and a Watch both record steps, Apple Health holds each stretch twice, and adding up the raw records counts it twice. Every payload with records therefore also carries `daily_totals`, with the Android app's schema, computed with HealthKit's statistics queries. These count overlapping samples from different sources once, in the order set in the Health app (Browse, a data type, Data Sources & Access), so the figures match what the Health app shows.

```json
"daily_totals": [
  { "date": "2026-02-05", "steps": 8421, "distance_meters": 6210.4, "active_calories": 412.0, "total_calories": 2231.5 }
]
```

There is one entry per local day in the phone's time zone, for today and the two days before, and only for enabled types. A field is left out for a day without data rather than sent as 0. A payload that only names deletions carries none. `distance_meters` adds up every distance, as the `distance` records do. Where it differs from Android: `total_calories` is resting plus active energy and is only sent on days with resting energy. An iPhone without an Apple Watch usually records none.

Use `daily_totals` for day totals and the raw records for detail. The setting **Daily totals in payload** switches it off.

## Deletions

A record deleted in Apple Health leaves nothing for a sync to read, so a receiver that stores records would keep it. The app follows HealthKit's own record of deletions and names the records that are gone, in the same shape as the Android app:

```json
"deleted_records": [
  { "type": "nutrition", "uuid": "84E37E8A-1C2D-4E5F-8A9B-0C1D2E3F4A5B" }
]
```

`type` is the key the record arrived under and `uuid` is the `uuid` it was delivered with. The field is absent when nothing was deleted. When a deletion is the only change, the sync sends a payload with `deleted_records` and no records. Deletions are kept on the phone until a payload carrying them was delivered or queued, so a receiver can get one twice but never lose one.

`deletions_unavailable` lists the payload keys whose deletions a payload cannot vouch for. That happens when HealthKit did not answer in time (five seconds per type, twenty in total, eight in the background), when the type could not be read, or when it was last read more than 7 days ago. HealthKit may forget a deletion after a while and does not say when, so the 7 days is an estimate. Reconcile those types against a fresh read of the range.

Where this differs from Android:

- Every sample has its own `uuid`; match it exactly. Android's `<uuid>#<epoch millis>` rule for heart rate samples does not apply.
- An active energy sample is part of both `active_calories` and `total_calories`, so its deletion is named under both when both are enabled.
- A blood pressure reading is named by its systolic sample, and a food by the sample its `uuid` comes from. A diastolic value deleted on its own is not reported. An energy, protein, carbohydrate or fat value deleted from a food whose `uuid` comes from another sample is named under a `uuid` no record carries; ignore a `uuid` you do not have.
- A sleep deletion names the stage (`stages[].uuid`), not the session. Drop that stage, or replace the sessions a newer payload covers.
- `menstruation_period` never appears in `deleted_records`.
- Tracking starts with the first sync of a type after installing or updating the app. After a restore onto another iPhone, the enabled types are named once in `deletions_unavailable`.

## Data resolution

Under **Data Resolution** on the Health tab, each dense type can be sent as one value per window of 1, 5 or 15 minutes, or per hour, instead of every record, as in the Android app. Heart rate, heart rate variability, oxygen saturation and respiratory rate are averaged, with `min` and `max`; steps, distance, active calories and total calories are summed into `total`. Every type starts at every record, so nothing changes for a receiver until you choose otherwise.

The shape is the Android app's, described with the merge rules on its page under [Data resolution](https://github.com/owen282000/life-dashboard-companion-app/blob/main/docs/webhook.md#data-resolution): a bucketed series replaces its records under the same key, every bucket has `bucket_start`, `bucket_end` and `sample_count` and never the record's own field, windows are aligned to the clock in UTC, and `_resolutions` names the window per series:

```json
"heart_rate": [
  { "bucket_start": "2026-02-05T08:00:00Z", "bucket_end": "2026-02-05T08:01:00Z",
    "sample_count": 12, "avg": 72.4, "min": 66, "max": 81, "sources": ["Owen's Apple Watch"] }
],
"_resolutions": { "heart_rate": "1m" }
```

`sources` holds the records' `source` names, so HealthKit's names here too. An interval record (steps, distance, calories) counts whole in the window it starts in. The records' `uuid`s do not travel with a bucket, and deletions of records in a bucketed series still name those `uuid`s in `deleted_records`.

When the windows go out:

- **The automatic syncs and the Sync Health Data action** send a window once it has closed, whole, as the Android app does. The samples of a window still filling stay on the iPhone, encrypted and out of iCloud backups, and are saved together with how far the sync has read, so a sync that iOS cuts off sends a window neither twice nor without them. A type still catching up past its cap per sync, or not read in a sync, keeps its windows open until its next read. A sync whose new records all fall in windows still filling posts no records; deletions that are waiting still go out on their own.
- **Sync Now** is an incremental sync like the automatic ones, so it sends a window once as well. When it runs several payloads in a row for a type still catching up, a window cut by where one payload stops is held for the next. **View** reads the last 7 days and shows those types as the week's closed windows, without holding or storing anything.
- **Backfill** sends each window once, whole, with the backfill window it starts in, so a bucket can end a few minutes after that payload's `window_end`. The window cut by the start of the backfill range and the one still filling at its end are left out. Like the Android app's backfill, it sends windows a receiver may already have; the payload says `"backfill": true`.
- **A type set back to every record** sends the samples it was holding as records, with their `uuid`s, where the Android app drops them.

As on Android, a record that reaches the iPhone late, from a Watch that syncs hours afterwards, makes its window go out a second time with only the late samples, and a payload from the retry queue can arrive twice. Use the Android page's rule and add buckets with the same `bucket_start` up, which is what the Life Dashboard integration does. MQTT and `daily_totals` are not affected: they never carried records.

## Backfill

**Backfill** on the Health tab sends the last 30, 90 or 365 days in 3-day windows, oldest first, with the Android app's fields: `backfill`, `window_start`, `window_end` and `window_complete`. The records are the ones a sync sends, `uuid` included, so the overlap deduplicates. `daily_totals` in a backfill payload covers every whole day of its window. Each sleep session and menstruation period goes out once, in the window it ends or starts in.

`window_complete` is always `false` on iOS. HealthKit does not tell an app that it may not read a type, so the app cannot vouch that a window is complete.

Backfill payloads go only to webhooks, never to MQTT or the retry queue.

## What iOS does not send

- `screen_time` and the Screen Time payload: see [What iOS does differently](features.md#what-ios-does-differently)
- `_diagnostics` and `records_outside_window`
- the writeback block and anything from the Android page's "Inbound" section: the iPhone app does not write into Apple Health

A receiver written for Android works unchanged, as long as it treats these as optional.

## Delivery, retries and signing

Every configured webhook URL receives each payload as a JSON POST. A sync counts as delivered when at least one URL accepted it. The Logs tab shows the result per URL.

A failed post is tried up to 3 times in total, with 1 and 2 seconds in between, but only for network errors, timeouts, HTTP 408, 429 and 5xx. Other errors, such as 401 or 404, fail at once. An attempt gives up once the connection stands still for 10 seconds, as in the Android app, so a server that hangs holds a payload up for about 33 seconds; a large payload on a slow connection is not cut off as long as it keeps moving.

Redirects are followed only on the same host: the same port, or `http` on port 80 moving up to `https` on 443, at most 5 in a row. The app sends the same POST there, with the same body, signature and headers, also after a 301, 302 or 303, which iOS on its own would turn into a GET without a body. A redirect to another host, or from `https` down to `http`, is not followed: it would send the body, the signature and your custom headers to an address you did not enter. Behind a login proxy such as Authelia, Authentik or Cloudflare Access, that redirect goes to the login page, which answers 200 to a request that never reached the webhook. Such a 3xx counts as a failed delivery, so the payload stays queued, and the log names the host it pointed at: enter the final address as the webhook URL instead, or let the proxy pass the webhook path without a login.

Every sync payload goes into a queue on the phone before it is posted, and leaves it once a URL accepted it, so a sync that iOS suspends or ends halfway loses nothing: the payload is sent again, and can arrive twice. A payload that was not delivered is sent again when the network comes back, at the next sync or background task, or with **Retry Now**, oldest first; the automatic retries wait for quiet hours to end. A retry goes to the webhook URLs configured at that moment, with the custom headers and signing secret configured then, as in the Android app: a new API key or a new address also reaches what was queued before it, a removed address gets nothing more, and an address that pairing added still gets no custom headers. The queue stops at the first payload that fails, so the rest keep their order. One retry posts for at most 2 minutes, as in the Android app, and in the background it stops while 10 seconds of the time iOS gives are left, for the sync after it; the rest waits for the next retry. A payload that every failing URL refused as such, with HTTP 400, 413 or 422, does not hold them up: it is skipped and stays queued, in case the receiver gets fixed, and is offered again once a day rather than at every retry, so it does not add a failed row to the log for every sync; **Retry Now** offers it at once. Payloads queued after it may then arrive before it: use `sequence` to order them. A payload older than 7 days is dropped when the receiver answers its next delivery with an error, however many attempts it had before, so an iPhone that could not sync for a week still tries it once. A delivery that reached no receiver, because the iPhone was offline, the name did not resolve or the connection timed out, drops nothing, and neither does one that iOS cut off. The queue holds up to 700 payloads, the Android app's limit; past that the oldest one is dropped. The Logs tab then gets a failed row with its payload, saying whether it was refused, not delivered or pushed out of a full queue, and a notification says how many syncs were lost.

iOS allows plain `http://` only to the home network: an IP address, a `.local` name or a name without a dot. Use `https://` for anything else.

With an HMAC signing secret set (under the webhook's custom headers), every POST carries:

```
X-Signature: sha256=<hex of HMAC-SHA256(secret, raw request body)>
```

This is the Android app's scheme, so one check covers both. Recompute it over the raw body:

```javascript
const crypto = require('crypto');

function verifySignature(req, secret) {
  const expected = 'sha256=' + crypto
    .createHmac('sha256', secret)
    .update(req.rawBody) // the exact raw request body bytes
    .digest('hex');
  const actual = req.get('X-Signature') || '';
  return actual.length === expected.length &&
    crypto.timingSafeEqual(Buffer.from(actual), Buffer.from(expected));
}
```

The Android page has [example receivers](https://github.com/owen282000/life-dashboard-companion-app/blob/main/docs/webhook.md#example-backend-integrations).
