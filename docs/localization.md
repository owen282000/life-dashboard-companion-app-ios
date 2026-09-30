# Translations

The app speaks English, Dutch and German, like the Android app. It follows the iPhone's
language, or the language set for Life Dashboard under Settings > Life Dashboard > Language;
anything else falls back to English.

Version 1.3.0 removed a Dutch translation that covered 56 of 71 strings, because it gave Dutch
iPhones a mixed-language app. What keeps that from happening again is a check that fails CI on
any string without Dutch and German, and on English text that never reaches a String Catalog.

## The loop

Every new or changed English string gets its Dutch and German in the same commit.

1. Write the code with English literals (see [In code](#in-code)).
2. `scripts/l10n.sh sync` puts every string the code uses into the catalogs, the way an Xcode
   build does, and lists what needs Dutch and German. It runs `xcodebuild -exportLocalizations`,
   which uses Xcode's own key order, so a later build in Xcode changes nothing.
3. Write nl and de, in Xcode's catalog editor or with `scripts/l10n/catalog.py`, using the
   glossary below and the Android app's `values-nl` and `values-de` for the same concept. A
   reworded English sentence is a new key; the old one is marked stale and keeps its
   translation as a starting point. `scripts/l10n.sh prune` removes the stale ones afterwards.
4. `scripts/l10n.sh check` builds and runs the same check as CI.

Never edit catalog JSON by hand, and never resolve a merge conflict in a catalog by hand: take
one side and run `scripts/l10n.sh sync` again.

## What the check fails on

`scripts/l10n/check.py`, run in CI right after the build:

- a string the code uses that is missing from a catalog, a key the code no longer uses, a key
  added to a catalog by hand, a localized string inside `#if DEBUG` (the export does not see
  it), and `NSLocalizedString` (the compiler does not extract it);
- a key without a translated Dutch or German value, in every plural form and substitution;
  format specifiers that differ from the English; a count followed by a noun that does not vary
  by plural; `(s)`; two keys that differ only in case; an em or en dash; a Siri phrase without
  `${applicationName}`; a sentence left in English;
- the words in `scripts/l10n/terms.json`: "je" and "du", never "u" or "Sie", the glossary's word
  where Android uses two, and the exact name of a button quoted in a sentence ("Tap Sync Now");
- an Info.plist usage description or display name without Dutch and German, whether it comes
  from an `INFOPLIST_KEY_*` build setting or from `Info.plist` itself;
- English text in code that is a plain `String`, so it never reaches a catalog;
- a catalog that is not in its target's bundle, or not in Xcode's own format.

Deliberate exceptions go in `scripts/l10n/allowlist.txt`, each with a category and a reason. An
entry that matches nothing fails the check too, so the list only shrinks by itself.

## In code

- A literal in a view (`Text("Sync Now")`, `Button("Cancel")`, `Label("...", systemImage:)`) is
  a `LocalizedStringKey` and is translated. A `String` passed to `Text` is not: `Text(name)` with
  `let name: String` shows exactly what is in it.
- Text built outside a view is a `LocalizedStringResource` (a data type's `displayName`, a
  helper's label) or, where an API needs a `String`, `String(localized: "...")` (notifications,
  the background task's title). A view helper takes `LocalizedStringKey`, not `String`.
- Never glue a sentence from pieces. Write the whole sentence with its values interpolated, so a
  translation can put them where its grammar wants them: `"Exported \(date) by the iPhone app."`,
  not `"Exported \(date) by \(app)."`.
- A count is interpolated into its sentence and the key varies by plural: `"\(count) records
  sent"`. Two keys chosen by `count == 1` only where the number is styled on its own (the widget,
  the dashboard); that is right for English, Dutch and German, not for every language.
- Data is shown with `Text(verbatim:)`: URLs, hosts, JSON, status codes.
- No localized literal inside `#if DEBUG`: define it outside and use it inside.
- The app group shared with the widget holds dates and counts, never a sentence; the widget has
  its own catalog, `LifeDashboardWidget/Localizable.xcstrings`.

## What stays English

| Text | Why |
|---|---|
| Payload keys, MQTT discovery names and topics, HTTP headers, the test ping text | Wire format: Home Assistant and every receiver read it as sent, the same as from Android |
| CSV and JSON exports, their timestamps | Read by scripts and spreadsheets, and the same on every phone |
| Log rows the app writes (`WebhookLog.errorMessage`), the MQTT status line | Stored in English, as on Android, and translated when shown through `AppDiagnostic` |
| Error text from a server or from iOS | Shown as it came; iOS writes its own in the phone's language |
| Life Dashboard, Home Assistant, MQTT, TLS, HMAC, JSON, webhook, payload | Names |

## Glossary

Rules: the Android app's wording for the app's own concepts, Apple's names for anything iOS
owns (the user sees it next to Settings or a system sheet), "je" and "du", sentence case in Dutch
and German.

### The app's words

| English | Dutch | German |
|---|---|---|
| sync (verb) | synchroniseren | synchronisieren |
| sync (noun) | synchronisatie; sync/syncs only where space is short | Synchronisierung; Sync/Syncs only where space is short |
| Sync Now | Nu synchroniseren | Jetzt synchronisieren |
| Sync Schedule, sync time | Syncschema, synctijd | Sync-Zeitplan, Sync-Zeit |
| Sync History | Syncgeschiedenis | Sync-Verlauf |
| Last sync | Laatste synchronisatie | Letzte Synchronisierung |
| health data | gezondheidsdata | Gesundheitsdaten |
| data type | datatype | Datentyp |
| record(s) | record(s) | Datensatz, Datensätze |
| webhook URL | webhook-URL | Webhook-URL |
| custom headers | eigen headers | eigene Header |
| signing secret | ondertekeningsgeheim | Signaturgeheimnis |
| payload | payload | der Payload |
| permission | toestemming | Berechtigung |
| queue, queued for retry | wachtrij, in de wachtrij voor een nieuwe poging | Warteschlange, für einen erneuten Versuch eingereiht |
| Delivered, Published, Failed, Interrupted | Afgeleverd, Gepubliceerd, Mislukt, Onderbroken | Zugestellt, Veröffentlicht, Fehlgeschlagen, Unterbrochen |
| delivery | aflevering | Zustellung |
| Backfill, Backfill History | Aanvullen, Geschiedenis aanvullen | Nachtragen, Verlauf nachtragen |
| window, chunk (of a backfill) | blok | Block |
| daily totals | dagtotalen | Tagessummen |
| quiet hours | stille uren | Ruhezeiten |
| pair, pairing code | koppelen, koppelcode | koppeln, Kopplungscode |
| receiver, destination | ontvanger, bestemming | Empfänger, Ziel |
| the Life Dashboard integration | de Life Dashboard-integratie | die Life-Dashboard-Integration |
| plain HTTP | onversleutelde HTTP | unverschlüsseltes HTTP |
| Cancel, Done | Annuleren, Gereed | Abbrechen, Fertig |
| Health (the tab) | Gezondheid | Gesundheit |

### iOS and Home Assistant words (checked on iOS 26.5)

| English | Dutch | German |
|---|---|---|
| Apple Health, the Health app | Apple Gezondheid, de Gezondheid-app | Apple Health, die Health-App |
| Settings > Privacy & Security > Local Network | Instellingen > Privacy en beveiliging > Lokaal netwerk | Einstellungen > Datenschutz & Sicherheit > Lokales Netzwerk |
| Background App Refresh | Ververs op achtergrond | Hintergrundaktualisierung |
| Notifications | Meldingen | Mitteilungen |
| Shortcuts, Automation | Opdrachten, Automatisering | Kurzbefehle, Automation |
| Time of Day, Run Immediately, Next | Tijdstip, Voer onmiddellijk uit, Volgende | Tageszeit, Sofort ausführen, Weiter |
| action (in Shortcuts) | taak | Aktion |
| Keychain | sleutelhanger | Schlüsselbund |
| Files | Bestanden | Dateien |
| Reconfigure (Home Assistant) | Herconfigureer | Neu konfigurieren |

The names of the 28 data types are the ones the Health app and the Health access sheet use in
each language ("Hartslag in rust", "Aktivitätsenergie"), in `Models/HealthDataType.swift` and the
catalog.

## Checking the layout

German runs about a third longer than English. Run the app in German and in Dutch before a
release, or after changing a screen: in Xcode set the scheme's App Language (Edit Scheme > Run >
Options), or launch the simulator app with `-AppleLanguages "(de)" -AppleLocale de_DE`. The Debug
launch arguments `-ld.tab 1`, `-ld.about YES`, `-ld.nerd YES`, `-ld.privacy YES`, `-ld.expand YES`,
`-ld.step 0...3` and `-ld.scroll 0.5` open every page directly.
