# Settings backup and restore

Export your configuration to a file and import it again, on this iPhone, another iPhone, or in the Android app. Find it under **About > Backup & restore**.

## When you need it

Moving from one iPhone to another usually needs nothing from this app: the settings and the Keychain items that hold the secrets travel with an encrypted iPhone backup and with Quick Start. The client certificate is the exception; see below. The export is for everything else: moving between the Android app and the iPhone app, setting the app up again after deleting it, or handing a setup to someone else without your credentials.

## What is included

| Included | Not included |
|---|---|
| Webhook URLs | HealthKit anchors (how far this install has read), and when the schedule last ran |
| Custom headers (with secrets) | Webhook logs and raw payloads |
| The webhook URLs that get no custom headers (the ones QR pairing added) | |
| HMAC signing secret (with secrets) | The pending queue |
| Sync schedule: interval or fixed times, days and quiet hours | HealthKit permissions |
| The data-type toggles, and whether payloads carry daily totals | The last MQTT status line |
| MQTT broker, port, TLS, switch, base topic and phone name | The client certificate (mTLS) |
| MQTT username and password (with secrets) | |
| Failure notifications and their threshold | |

Sync progress is left out on purpose, as on Android: the anchors describe how far this install has read from HealthKit, and restoring them on another phone would make it skip everything written before them. HealthKit permissions are granted by iOS, so the app asks for them again after an import.

The client certificate is left out as well, as on Android. Its private key stays in this iPhone's Keychain and is never exported, and its name alone means nothing on another phone. Unlike the other secrets it also stays behind with an encrypted iPhone backup and with Quick Start, because the app stores it for this device only. On the new iPhone, import the `.p12` file again under **Advanced** on the Health tab; until then, the webhook log says the certificate is unavailable and no webhook is sent.

## Exporting

1. Open **About > Backup & restore > Export**
2. Choose whether to **include secrets** (on by default)
3. With secrets, enter a password twice, at least 8 characters
4. Pick where to save the file: iCloud Drive, On My iPhone, or any other location in Files

**With secrets** the file is encrypted with AES-256-GCM under a key derived from your password (PBKDF2-HMAC-SHA256, 210,000 iterations), exactly as the Android app does it, and saved as `life-dashboard-config.encrypted.json`. There is no recovery if you lose the password.

**Without secrets** the file is plain JSON (`life-dashboard-config.json`) with the URLs, MQTT host, topic and options, but no headers, signing secret or MQTT credentials. It still contains your webhook URLs, and a URL can be a credential in itself: a Home Assistant `/api/webhook/<id>` address accepts anything posted to it. Share the file only with someone you would give that access to.

The file goes straight to the place you pick; the app keeps no copy of it. To send it to an Android phone, share it from the Files app.

## Importing

1. Open **About > Backup & restore > Import**
2. Pick the file
3. Enter the password when the file is encrypted
4. Check the preview: the webhook servers, the MQTT broker, the number of data types, whether the file carries secrets, and what is kept, cleared or skipped
5. Tap **Import**

Nothing changes before you tap Import. A file with a value of the wrong type, a header with a line break in it, or an MQTT port outside 1 to 65535 is refused as a whole, so a damaged file never half-applies. Keys the app does not know are ignored, so a file from a newer version still imports what this one understands; the preview says when a file comes from a newer version.

What an import keeps from the iPhone:

- **Signing secret:** a file without one keeps the one on the iPhone.
- **Custom headers:** a file with headers brings its own list of URLs that get none of them. A file without headers keeps the ones on the iPhone, for the URLs they were already sent to: a URL from the file that was not on the iPhone, or that pairing added, gets none of them. This is the Android app's rule, so a token never reaches an address it was not set for, also on a service that hosts many users' webhooks on one server such as Home Assistant Cloud's `hooks.nabu.casa`. The preview marks the webhooks that get no custom headers.
- **MQTT username and password:** kept only when the file has no secrets at all and points at the same broker, meaning the same host, port and TLS setting. Otherwise the file's credentials apply, or none, so they never go to a server they were not set for, or out in plain text where they had TLS.

Other rules:

- Webhook URLs must use HTTPS, or plain HTTP to a host on your own network (a private address, a name without a dot, or a `.local`, `.lan`, `.home`, `.internal` or `.ts.net` name). Other URLs are skipped and listed in the preview.
- The sync interval is kept between 15 and 1440 minutes, and the failure threshold becomes the nearest of 3, 5 or 10.
- The rest of the schedule follows the Android app's rule: a file from before the schedule existed (Android 1.13 or older) changes only the interval. Otherwise the file's mode, times and days replace the iPhone's, and its quiet hours too, which means none when the file has none. An imported schedule counts as a change, so a time earlier today does not run straight away.
- Settings apply immediately. Background sync is scheduled again and the app asks for HealthKit access to the imported data types.

## Moving between Android and iPhone

Both apps write and read the same format, so a file from one opens in the other, encrypted or not.

**From Android to iPhone:** the webhook URLs, signing secret, sync schedule, data types, daily totals switch, MQTT broker and failure threshold carry over. Screen Time, the Receive options, series resolutions and the other Android-only settings are skipped. Android data types the iPhone has no counterpart for are skipped and counted in the preview. When the Android file uses Android's default MQTT topic `lifedashboard`, the iPhone keeps its own default `lifedashboard-ios`, so the two phones do not publish to the same sensors; a custom topic is copied as it is. The Android phone's `phone_name` names that phone, so the iPhone keeps its own; a file from an iPhone brings its name along.

Custom headers from Android come with a list of URLs that get none of them (the ones QR pairing added). The iPhone keeps the same list, so both carry over, in either direction.

**From iPhone to Android:** Android reads the file, but its importer resets what the file does not mention. Importing an iPhone file on an Android phone that also syncs Screen Time clears its Screen Time webhooks, switches Screen Time MQTT off, resets the Android-only options (full payloads, the day boundary) and turns off the data types the iPhone does not have. On a fresh Android phone this does not matter. The Android app also takes the file's `phone_name`, so an Android phone with a name of its own takes the iPhone's name, or none; set it again under MQTT afterwards.

## File format

The same JSON as the Android app, with `"platform": "ios"` added so the importer can tell the two apart (Android ignores it):

```json
{
  "app_version" : "1.4.0",
  "exported_at" : "2026-09-30T12:00:00Z",
  "health" : {
    "quiet_from" : "23:00",
    "quiet_to" : "07:00",
    "sync_days" : "MONDAY,TUESDAY,WEDNESDAY,THURSDAY,FRIDAY,SATURDAY,SUNDAY",
    "sync_interval_minutes" : 60,
    "sync_mode" : "INTERVAL",
    "sync_times" : "",
    "webhook_urls" : [
      "https://example.com/health"
    ]
  },
  "mqtt" : {
    "health_base_topic" : "lifedashboard-ios",
    "health_enabled" : true,
    "health_use_shared" : true,
    "shared" : {
      "host" : "mqtt.local",
      "port" : 1883,
      "use_tls" : false
    }
  },
  "options" : {
    "allow_http_webhooks" : false,
    "enabled_data_types" : [
      "HEART_RATE",
      "MENSTRUATION_FLOW",
      "MENSTRUATION_PERIOD",
      "STEPS"
    ],
    "failure_notification_threshold" : 3,
    "failure_notifications_enabled" : true,
    "include_daily_totals" : true,
    "phone_name" : ""
  },
  "platform" : "ios",
  "version" : 1
}
```

- The iPhone's one MQTT broker is Android's shared broker. From an Android file whose health section uses its own broker, that broker is taken instead, host and credentials together.
- Cycle tracking is one toggle on iPhone and two record types on Android, so it is written as `MENSTRUATION_FLOW` and `MENSTRUATION_PERIOD` and read back from either.
- `allow_http_webhooks` is for Android: it is true when one of the URLs uses plain HTTP, so Android does not block the same local webhook. The iPhone ignores it and lets iOS decide.
- `failure_notifications_enabled` is iPhone-only for now, under the name Android uses for the same setting.
- With secrets, the file is Android's encrypted envelope around this JSON (`type`, `version`, `kdf`, `iterations`, `salt`, `iv`, `ciphertext`), with the salt and IV random per export.

## Keeping an export safe

An export with secrets grants full access to your webhook endpoints and MQTT broker. Treat the file like a password: use a strong password, avoid leaving the file in a chat thread or a shared folder, and delete it once the new phone is set up. When you only need to move non-secret settings, export without secrets.
