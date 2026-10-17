# Security policy

Life Dashboard Companion for iOS moves health data from your iPhone to servers you run. This page explains how to [report a security problem](#reporting-a-vulnerability) and [what is in scope](#scope).

## Supported versions

Only the latest release receives security fixes.

| Version | Supported |
| ------- | --------- |
| Latest release | Yes |
| Older versions | No |

## Reporting a vulnerability

Please do not open a public issue for a security vulnerability.

Report it through [GitHub's private vulnerability reporting](https://github.com/owen282000/life-dashboard-companion-app-ios/security/advisories/new) for this repository. If you do not have a GitHub account, email owen282000@hotmail.com instead, with "Security" in the subject.

Useful in a report: the app version, the iOS version, what an attacker needs (another app on the iPhone, a position on the network, access to the receiving server), and the steps to reproduce it.

### What happens next

- You get a reply within 7 days, confirming the report and saying whether it is in scope.
- The target for a fix depends on severity: a release within 14 days for a problem that exposes health data or secrets, within 30 days for a moderate problem, and in a regular release for a minor one. If a fix needs longer, you hear why and when to expect it.
- The fix is published as a [GitHub security advisory](https://github.com/owen282000/life-dashboard-companion-app-ios/security/advisories) once the release is out, with a CVE where one applies.
- You are credited in the advisory and the changelog by the name you choose, unless you prefer not to be named.

The project has one maintainer and no bug bounty.

## Scope

The app has read-only access to Apple Health and sends what it reads to servers the user chose, so reports about any of these are especially welcome:

- **Data leaving for the wrong place.** Health data reaching anything other than the webhooks and the MQTT broker the user entered or paired, a type that is switched off leaving the iPhone, custom headers reaching an address that pairing added, or a redirect to another host or from `https` down to `http` being followed.
- **Pairing codes and links.** The code the in-app scanner reads and the `lifedashboard://pair` link the pairing page opens the app with: a code or link that changes a destination without the **Pair** confirmation, switches on a data type or changes the schedule, or leaks the secret, which travels in the part after the `#`. Also the pairing test: an answer counted as confirmed when it does not name the request's signature, or carries a wrong signature of its own.
- **Shortcuts, the widget and Control Center.** The **Sync Health Data** action, the widget's button and the Control Center control should do nothing more than start a sync to the configured destinations, at most once a minute. Anything more is in scope.
- **Stored secrets.** Custom headers, the HMAC signing secret and the MQTT password, kept in the iOS Keychain; the client certificate (mTLS) and its key, kept in the Keychain for this iPhone only; the encrypted settings export; and secrets or health data ending up in the system log.
- **The retry queue and other held data.** Undelivered payloads, the MQTT sensor values and the samples of a window still filling are protected by iOS file protection and kept out of backups: one of them readable by another app, ending up in a backup, or sent to an address that was removed is in scope.
- **Background delivery.** HealthKit background delivery and the background tasks: a sync started in the background that reads or sends a type the user did not switch on, or sends to a destination the user removed.
- **Transport.** Webhook TLS, the plain HTTP that iOS allows only to an IP address, a `.local` name or a name without a dot, client certificates, MQTT over TLS, and the HMAC request signature.

Out of scope: problems that need a jailbroken iPhone, an unlocked iPhone in someone else's hands, or an app with permissions the user granted to it; when iOS lets the app run in the background; and the receiving side. The Android app has its own policy in [owen282000/life-dashboard-companion-app](https://github.com/owen282000/life-dashboard-companion-app/security/policy), the Home Assistant integration in [owen282000/life-dashboard-ha](https://github.com/owen282000/life-dashboard-ha/security/policy), and the receiver, database and dashboards in [owen282000/life-dashboard-stack](https://github.com/owen282000/life-dashboard-stack/security/policy).
