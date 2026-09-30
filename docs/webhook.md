# Webhook payload on iOS

The iPhone app sends the Android app's payload: the same keys, fields, units and signing, so one receiver and the Life Dashboard integration serve both phones. The full reference, with an example for every type, is the Android app's [docs/webhook.md](https://github.com/owen282000/life-dashboard-companion-app/blob/main/docs/webhook.md), and [webhook-schema.json](https://github.com/owen282000/life-dashboard-companion-app/blob/main/docs/webhook-schema.json) is the JSON Schema for both apps.

This page lists what an iPhone sends and where it differs, so a receiver can handle both.

## Contents

- [Top-level fields](#top-level-fields)
- [What iOS sends](#what-ios-sends)
- [Per-type notes](#per-type-notes)
- [Daily totals](#daily-totals)
- [Deletions](#deletions)
- [Backfill](#backfill)
- [What iOS does not send](#what-ios-does-not-send)
- [Delivery, retries and signing](#delivery-retries-and-signing)

## Top-level fields

```json
{
  "timestamp": "2026-02-05T12:00:00Z",
  "app_version": "1.3.0",
  "source": "healthkit_ios",
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

Every record carries:

- `uuid`: the HealthKit sample's UUID. It stays the same for the life of the record, so deduplicate on it. A full sync (Sync Now) sends the last 7 days again. HealthKit never edits a record in place: an app that edits one deletes it and saves a new one under a new `uuid`, and the old one is named in [`deleted_records`](#deletions).
- `source`: the name HealthKit gives the app or device that wrote the record (`HKSource.name`), not a package name as on Android. For data the iPhone or Watch records itself, this is the device's name, which often includes the owner's name.

## What iOS sends

The app has 28 data types. Menstruation sends two keys, so an iPhone can send 29 of the Android app's 33 record keys, with the same fields:

| Key | Fields | Read from HealthKit |
|---|---|---|
| `steps` | `count`, `start_time`, `end_time` | step count |
| `distance` | `meters`, `start_time`, `end_time` | walking and running distance |
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

A type with more new records than one sync may send (1000 for heart rate and steps, 500 for HRV and respiratory rate, 200 for the rest, as on Android) sends the oldest first, and the next sync continues where this one stopped.

## Per-type notes

- **Heart rate variability** is SDNN, the measure Apple Health stores. Health Connect stores RMSSD. Both arrive in `heart_rate_variability_millis`, but the two are not the same number.
- **Distance** is walking and running distance. Health Connect's distance covers every activity.
- **Total calories** are resting plus active energy records, since HealthKit has no total energy type.
- **Blood pressure** is read per reading: the systolic and diastolic values an app saved together, as HealthKit keeps them. The rare app that saves the two values separately gets them paired when they come from that app within a second of each other. A value without its other half is not sent, since the Android schema requires both. `uuid` is the systolic sample's.
- **Nutrition**: a food an app logged, with every nutrient in it, is one record, with its name in `name` when the app gave one. Besides energy, protein, carbohydrates and fat, a food carries the 34 other nutrients HealthKit and Android share, under Android's keys (`dietary_fibre_g`, `sugars_g`, `sodium_mg`, `caffeine_mg` and so on, see [webhook-schema.json](https://github.com/owen282000/life-dashboard-companion-app/blob/main/docs/webhook-schema.json)). HealthKit has no type for trans fat, unsaturated fat, energy from fat, folic acid or `meal_type`. Energy, protein, carbohydrate and fat values saved outside a food are sent too: values from one app with the same time and name become one record when no nutrient repeats, anything else a record per value. Those 34 nutrients are only read from inside a food that also has energy, protein, carbohydrates or fat; a food with none of those four, such as a coffee logged with caffeine only, is not sent. Every nutrient field is optional and left out when the food has no value for it. `uuid` is the uuid of the food's energy sample, else of its protein, carbohydrate or fat sample.
- **Sleep**: stage samples are grouped into sessions, and a gap of more than 1 hour starts a new session. Stage values are `in_bed`, `sleeping`, `light`, `deep`, `rem`, `awake` and `unknown`, as on Android. A session's `uuid` comes from its earliest stage, so it stays the same while a night grows at the end: replace the session when it comes back longer. Each stage carries its own sample's `uuid` and `source`.
- **Menstruation period**: HealthKit has no period record, so periods are derived from consecutive flow days, where a gap of up to 48 hours bridges one missed day. They carry no `uuid` or `source`. Replace the periods a payload covers.
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

There is one entry per local day in the phone's time zone, for today and the two days before, and only for enabled types. A field is left out for a day without data rather than sent as 0. A payload that only names deletions carries none. Where it differs from Android:

- `distance_meters` is walking and running distance
- `total_calories` is resting plus active energy and is only sent on days with resting energy. An iPhone without an Apple Watch usually records none.

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

## Backfill

**Backfill** on the Health tab sends the last 30, 90 or 365 days in 3-day windows, oldest first, with the Android app's fields: `backfill`, `window_start`, `window_end` and `window_complete`. The records are the ones a sync sends, `uuid` included, so the overlap deduplicates. `daily_totals` in a backfill payload covers every whole day of its window. Each sleep session and menstruation period goes out once, in the window it ends or starts in.

`window_complete` is always `false` on iOS. HealthKit does not tell an app that it may not read a type, so the app cannot vouch that a window is complete.

Backfill payloads go only to webhooks, never to MQTT or the retry queue.

## What iOS does not send

- `screen_time` and the Screen Time payload: see [What iOS does differently](features.md#what-ios-does-differently)
- `sequence`, `_diagnostics`, `_resolutions` and `records_outside_window`
- the writeback block and anything from the Android page's "Inbound" section: the iPhone app does not write into Apple Health

A receiver written for Android works unchanged, as long as it treats these as optional.

## Delivery, retries and signing

Every configured webhook URL receives each payload as a JSON POST. A sync counts as delivered when at least one URL accepted it. The Logs tab shows the result per URL.

A failed post is tried up to 3 times in total, with 1 and 2 seconds in between, but only for network errors, timeouts, HTTP 408, 429 and 5xx. Other errors, such as 401 or 404, fail at once. When every attempt fails, the payload is queued on the phone and sent again when the network comes back, at the next background task, or with **Retry Now**. The queue retries only outside quiet hours. A queued payload is dropped after 7 days or 20 attempts.

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
