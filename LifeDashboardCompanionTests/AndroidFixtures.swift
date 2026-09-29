import Foundation

/// Files written by the Android app's own code (ConfigBackup.encode and ConfigCrypto.encrypt,
/// run from its unit tests), so the iOS tests check against the real thing, not a copy of the
/// format as we understand it.
enum AndroidFixtures {
    /// Every key Android 1.21.2 writes, with Screen Time, an own broker slot, a type iOS lacks,
    /// Android's menstruation name and the Receive options.
    static let plain = """
        {
            "version": 1,
            "exported_at": "2026-09-30T10:15:30.123Z",
            "app_version": "1.21.2",
            "health": {
                "webhook_urls": [
                    "https://example.com/health",
                    "https://ha.example.com/api/webhook/abc"
                ],
                "headers": {
                    "Authorization": "Bearer token123"
                },
                "signing_secret": "hmac-secret",
                "sync_interval_minutes": 30,
                "sync_mode": "TIMES",
                "sync_times": "07:30,21:00",
                "sync_days": "MONDAY,TUESDAY,WEDNESDAY,THURSDAY,FRIDAY",
                "quiet_from": null,
                "quiet_to": null,
                "urls_without_headers": [
                    "https://ha.example.com/api/webhook/abc"
                ]
            },
            "screen_time": {
                "webhook_urls": [
                    "https://example.com/screen"
                ],
                "headers": {},
                "signing_secret": null,
                "sync_interval_minutes": 60,
                "sync_mode": "INTERVAL",
                "sync_times": "",
                "sync_days": "MONDAY,TUESDAY,WEDNESDAY,THURSDAY,FRIDAY,SATURDAY,SUNDAY",
                "quiet_from": null,
                "quiet_to": null,
                "urls_without_headers": []
            },
            "mqtt": {
                "shared": {
                    "host": "mqtt.local",
                    "port": 1883,
                    "use_tls": false,
                    "username": "user",
                    "password": "pass"
                },
                "health_enabled": true,
                "health_use_shared": true,
                "health_base_topic": "lifedashboard",
                "health_own_broker": {
                    "host": "",
                    "port": 1883,
                    "use_tls": false,
                    "username": null,
                    "password": null
                },
                "screen_time_enabled": false,
                "screen_time_use_shared": true,
                "screen_time_base_topic": "lifedashboard",
                "screen_time_own_broker": {
                    "host": "",
                    "port": 1883,
                    "use_tls": false,
                    "username": null,
                    "password": null
                }
            },
            "options": {
                "enabled_data_types": [
                    "BONE_MASS",
                    "HEART_RATE",
                    "MENSTRUATION_PERIOD",
                    "STEPS"
                ],
                "include_daily_totals": true,
                "allow_http_webhooks": false,
                "keep_full_payloads": false,
                "screen_time_day_boundary_hour": 4,
                "screen_time_use_day_boundary": true,
                "failure_notification_threshold": 3,
                "series_resolutions": {
                    "HEART_RATE": "FIVE_MINUTES"
                },
                "phone_name": "",
                "receive_enabled": false,
                "receive_types": [],
                "receive_older_measurements": false,
                "receive_source_url": ""
            }
        }
        """

    /// `plain`, encrypted by ConfigCrypto under `encryptedPassword`.
    static let encrypted = """
        {
          "type": "life-dashboard-encrypted-config",
          "version": 1,
          "kdf": "PBKDF2WithHmacSHA256",
          "iterations": 210000,
          "salt": "QqrLArrjm8FxLiEBJ5H0UQ==",
          "iv": "KPvxVk9lXEYHlooo",
          "ciphertext": "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"
        }
        """

    /// Precomposed n with tilde (U+00F1), so the test also pins the UTF-8 password bytes.
    static let encryptedPassword = "correct horse \u{f1}"
}
