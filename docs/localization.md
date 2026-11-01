# Translations

The app speaks English, Dutch, German, French, Spanish, Italian, Portuguese (Brazil), Japanese,
Arabic, Hindi and Simplified Chinese, like the Android app. It follows the iPhone's
language, or the language set for Life Dashboard under Settings > Life Dashboard > Language;
anything else falls back to English.

Version 1.3.0 removed a Dutch translation that covered 56 of 71 strings, because it gave Dutch
iPhones a mixed-language app. What keeps that from happening again is a check that fails CI on
any string without a translation in every language, and on English text that never reaches a
String Catalog.

## The loop

Every new or changed English string gets all its translations in the same commit.

1. Write the code with English literals (see [In code](#in-code)).
2. `scripts/l10n.sh sync` puts every string the code uses into the catalogs, the way an Xcode
   build does, and lists what still needs a translation. It runs `xcodebuild -exportLocalizations`,
   which uses Xcode's own key order, so a later build in Xcode changes nothing. The languages are
   `LANGS` in `scripts/l10n/check.py`.
3. Write every language, in Xcode's catalog editor or with `scripts/l10n/catalog.py`, using the
   glossary below and the Android app's `values-<locale>` for the same concept. A
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
- a key without a translated value in one of the languages, in every plural form that language has
  (one and other in Dutch, German and Hindi; one, many and other in French, Spanish, Italian and
  Portuguese; only other in Japanese and Chinese; six in Arabic) and in every substitution;
  format specifiers that differ from the English; a count followed by a noun that does not vary
  by plural; `(s)`; two keys that differ only in case; an em or en dash; a Siri phrase without
  `${applicationName}`; a sentence left in English;
- the words in `scripts/l10n/terms.json`: each language's register ("je" and "du", never "u" or
  "Sie"; "vous" in French; "tú" in Spanish), the glossary's word
  where Android uses two, and the exact name of a button quoted in a sentence ("Tap Sync Now");
- an Info.plist usage description or display name without every language, whether it comes
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
owns (the user sees it next to Settings or a system sheet), the register the platform itself uses
in each language ("je" and "du" in Dutch and German), and that language's capitalization and
punctuation. The two tables below are Dutch and German; every other language has its own section
after them, with the same words and the Android system words it shares with the Android app.

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

### French (`fr`)

Vous everywhere, as Apple and Google do in French, with imperatives in the vous form ("Touchez", "Saisissez", "Vérifiez"). The only exception is the two Siri phrases, written as a person talks to Siri ("Synchronise mes données de santé avec ${applicationName}"), which is the informal imperative French users actually say to Siri. Sentence case, typographic apostrophe (’, so no `\'` escaping needed on Android), guillemets « » for a quoted user value, and a non-breaking space (U+00A0) before : ; ! ? and inside « », as Apple and Google print them. Apple's verb "Toucher" for tap, Android's "Paramètres" vs Apple's "Réglages" kept per platform. English semicolons were mostly turned into two sentences or a colon, which reads more natural in French.

#### The app's words

| English | French |
|---|---|
| sync (verb) | synchroniser |
| sync (noun) | synchronisation; "synchro" only in the two tiny widget status lines |
| Sync Now | Synchroniser maintenant |
| Sync Schedule, sync time(s) | Horaires de synchronisation, heure(s) de synchronisation |
| Sync History | Historique des synchronisations |
| Last sync | Dernière synchronisation |
| health data | données de santé |
| data type | type de données |
| record(s) | enregistrement(s) |
| webhook URL | URL de webhook (feminine, invariable plural "les URL") |
| custom headers | en-têtes personnalisés |
| signing secret | secret de signature |
| payload | payload (masculine, kept as the technical word) |
| permission | autorisation |
| queue, queued for retry | file d'attente, en file d'attente pour une nouvelle tentative |
| Delivered, Published, Failed, Interrupted | Livré, Publié, Échec, Interrompu |
| delivery | livraison |
| Backfill (button), Backfill History, a backfill | Rattraper, Rattraper l'historique, un rattrapage |
| window, chunk (of a backfill) | bloc |
| daily totals | totaux quotidiens |
| quiet hours | heures de silence |
| pair, pairing code | associer, code d'association |
| receiver, destination | récepteur, destination |
| the Life Dashboard integration | l'intégration Life Dashboard |
| plain HTTP | HTTP non chiffré |
| Cancel, Done | Annuler, OK |
| Health (the tab) | Santé |
| Logs (tab) | Journaux |
| broker, topic, base topic | broker, topic, topic de base |
| Nerd Stats | Stats de geek |
| data resolution, time window (averaging) | résolution des données, plage |

#### iOS words

| English | French |
|---|---|
| Apple Health, the Health app | Santé, l'app Santé (the iOS app's own French name; "Apple" is never added) |
| Health access sheet | fenêtre d'accès à Santé |
| Settings > Privacy & Security > Local Network | Réglages > Confidentialité et sécurité > Réseau local |
| Settings > Health > Data Access & Devices | Réglages > Santé > Accès aux données et appareils |
| Background App Refresh | Actualisation en arrière-plan |
| Low Power Mode | mode Économie d'énergie |
| Notifications | Notifications |
| Shortcuts, Automation | Raccourcis, Automatisation |
| Time of Day, Run Immediately, Next | Heure de la journée, Exécuter immédiatement, Suivant |
| action (in Shortcuts) | action |
| Keychain | trousseau |
| Files | Fichiers |
| Screen Time | Temps d'écran |
| Reconfigure (Home Assistant) | Reconfigurer |
| Resting Heart Rate, Active Energy, Blood Oxygen | Fréquence cardiaque au repos, Énergie active, Oxygène sanguin |
| Workouts, Water, Menstruation | Entraînements, Eau, Règles |

#### Android system words

| English | French |
|---|---|
| Health Connect | Santé Connect |
| Steps, Distance, Heart rate | Pas, Distance, Fréquence cardiaque |
| Resting heart rate | Fréquence cardiaque au repos |
| Active calories burned, Total calories burned | Calories brûlées en activité, Total des calories brûlées |
| Exercise sessions, Mindfulness, Hydration | Séances d'exercice, Pleine conscience, Hydratation |
| Body fat, Lean body mass, Bone mass, Body water mass | Masse grasse, Masse maigre, Masse osseuse, Masse hydrique corporelle |
| Basal metabolic rate, Skin temperature | Métabolisme de base, Température cutanée |
| Settings path for certificates | Sécurité, Chiffrement et identifiants, Installer un certificat, Certificat CA |
| Usage access | accès aux données d'utilisation |
| Battery optimization | optimisation de la batterie |
| Screen Time (app section) | Temps d'écran |
| Xiaomi Battery saver, Huawei Phone Manager, Samsung Device Care | Économiseur de batterie, Gestionnaire du téléphone, Maintenance de l'appareil |

Google Apps Script deployment dialog labels (iOS key "HTTP %lld: Google asked for a sign-in..."): **"Qui a accès"** and **"Tout le monde"**, in straight double quotes like nl and de.

### Spanish (`es`)

Informal tú throughout, as Apple and Google write Spanish, with imperatives such as "Toca", "Revisa",
"Agrega", "Ingresa". Neutral Spanish for Spain and Latin America: agregar (not añadir), ingresar,
teléfono (never móvil or celular), Configuración for Settings, no vosotros. Sentence case, straight
double quotes where the English has them (required for the Apps Script labels), no dashes; "Sincronizar
ahora" is quoted identically wherever a sentence names the button. Plural many = other.

#### The app's words

| English | Spanish |
|---|---|
| sync (verb) | sincronizar |
| sync (noun) | sincronización (never shortened) |
| Sync Now | Sincronizar ahora |
| Sync Schedule, sync time(s) | Horario de sincronización, hora(s) de sincronización |
| Sync History | Historial de sincronización |
| Sync Interval | Intervalo de sincronización |
| Last sync | Última sincronización |
| health data | datos de salud |
| data type | tipo de datos |
| record(s) | registro(s) |
| log(s), Logs tab | log(s), pestaña Logs (kept, see reviewer notes) |
| webhook, webhook URL | webhook, URL del webhook / URL de webhook |
| custom headers, header | encabezados personalizados, encabezado |
| signing secret | secreto de firma |
| payload | payload (el payload) |
| permission | permiso |
| queue, queued for retry | cola, en cola para reintentar |
| outbox (Android) | cola de salida |
| Delivered, Published, Failed, Interrupted | Entregado, Publicado, Fallido, Interrumpido |
| delivery | entrega |
| Backfill (button), Backfill History | Recuperar, Recuperar historial |
| backfill (noun) | la recuperación (del historial) |
| window, chunk (of a backfill) | bloque |
| time window (data resolution) | intervalo |
| daily totals | totales diarios |
| quiet hours | horas de silencio |
| pair, pairing, pairing code | vincular, vinculación, código de vinculación |
| receiver, destination | receptor, destino |
| the Life Dashboard integration | la integración Life Dashboard |
| plain HTTP | HTTP sin cifrar |
| test ping | ping de prueba |
| broker, topic, base topic | broker, tema, tema base |
| Receive (Android) | Recibir |
| day boundary | cambio de día |
| Add, Remove, Delete, Clear | Agregar, Quitar, Eliminar, Borrar |
| Cancel, Done | Cancelar, OK |
| Health (the tab) | Salud |
| Screen Time (Android section) | Tiempo de pantalla |

#### iOS words

| English | Spanish |
|---|---|
| Apple Health, the Health app | la app Salud (title: App Salud) |
| Health access sheet | la hoja de acceso a Salud |
| Settings > Privacy & Security > Local Network | Configuración > Privacidad y seguridad > Red local |
| Settings > Health > Data Access & Devices | Configuración > Salud > Acceso a datos y dispositivos |
| Background App Refresh | Actualización en segundo plano |
| Low Power Mode | Modo de bajo consumo |
| Notifications | Notificaciones |
| Shortcuts, Automation | Atajos, Automatización |
| Time of Day, Run Immediately, Next | Hora del día, Ejecutar inmediatamente, Siguiente |
| action (in Shortcuts) | acción |
| Keychain | llavero |
| Files | Archivos |
| Reconfigure (Home Assistant) | Reconfigurar |
| Active Energy / Total Calories | Energía activa / Energía total |
| Resting Heart Rate | Frecuencia cardiaca en reposo |
| Blood Oxygen (Oxygen Saturation) | Oxígeno en sangre |
| Body Fat | Porcentaje de grasa corporal |
| Hydration | Agua |
| Exercise Sessions | Entrenamientos |
| Intermenstrual Bleeding (Spotting) | Manchado |
| Cervical Mucus | Calidad del moco cervical |
| Ovulation Test | Resultado de prueba de ovulación |
| VO2 Max | VO2 máx. |
| Apps Script: "Who has access", "Anyone" | "Quién tiene acceso", "Cualquier usuario" |

#### Android system words

| English | Spanish |
|---|---|
| Health Connect | Health Connect (Google keeps the name) |
| Steps, Heart Rate, Resting Heart Rate | Pasos, Frecuencia cardíaca, Frecuencia cardíaca en reposo |
| Active Calories, Total Calories | Calorías activas, Calorías totales |
| Oxygen Saturation, Exercise Sessions | Saturación de oxígeno, Sesiones de ejercicio |
| Intermenstrual Bleeding, Cervical Mucus | Sangrado intermenstrual, Moco cervical |
| Android Settings | configuración de Android |
| Security > Encryption & credentials > Install a certificate > CA certificate | Seguridad > Encriptación y credenciales > Instalar un certificado > Certificado de CA |
| usage access | acceso a datos de uso |
| Battery optimization | Optimización de batería |
| Xiaomi Battery saver, Huawei Phone Manager, Samsung Device Care | Ahorro de batería, Gestor del teléfono, Mantenimiento del dispositivo |
| share sheet | menú para compartir |
| BPM | LPM |

### Italian (`it`)

Informal "tu" throughout, as Apple and Google write Italian; buttons are imperatives in the
second person ("Sincronizza ora", "Annulla", "Aggiungi"), as on iOS and Android. Sentence case,
straight quotes "..." for quoted labels on iOS (escaped \" on Android, plus \' for every
apostrophe). Failed states use "non riuscito/a" (Apple and Google style) instead of "fallito".

#### The app's words

| English | Italian |
|---|---|
| sync (verb) | sincronizzare |
| sync (noun) | sincronizzazione; "sync" only where space is short (Pianificazione sync, Cronologia sync) |
| Sync Now | Sincronizza ora |
| Sync Schedule, sync time | Pianificazione sync, orario di sincronizzazione |
| Sync History | Cronologia sync |
| Last sync | Ultima sincronizzazione |
| health data | dati sulla salute (iOS: "dati di Salute" where it means the Health app's data) |
| data type | tipo di dati |
| record(s) | record (invariable, as usual for this loanword in Italian) |
| webhook URL | URL webhook (plural: URL dei webhook) |
| custom headers | header personalizzati |
| signing secret | segreto di firma |
| payload | il payload |
| permission | autorizzazione |
| queue, queued for retry | coda, in coda per un nuovo tentativo |
| Delivered, Published, Failed, Interrupted | Consegnato, Pubblicato, Non riuscito, Interrotto |
| delivery | consegna |
| Backfill, Backfill History | Recupero (dello storico), Recupera storico |
| window, chunk (of a backfill) | blocco |
| time window (data resolution) | intervallo |
| daily totals | totali giornalieri |
| quiet hours | ore di silenzio |
| pair, pairing code | associare, codice di associazione |
| receiver, destination | destinatario, destinazione |
| the Life Dashboard integration | l'integrazione Life Dashboard |
| plain HTTP | HTTP non crittografato |
| test ping | ping di prova |
| Cancel, Done | Annulla, Fine |
| Health (the tab) | Salute |
| Logs (tab) | Log |
| Nerd Stats | Statistiche da nerd |
| day boundary | inizio giornata |

#### iOS words

| English | Italian |
|---|---|
| Apple Health, the Health app | Salute, l'app Salute ("App Salute" as a standalone label) |
| Health access sheet | schermata di accesso di Salute |
| Settings > Privacy & Security > Local Network | Impostazioni > Privacy e sicurezza > Rete locale |
| Settings > Health > Data Access & Devices | Impostazioni > Salute > Accesso ai dati e dispositivi |
| Background App Refresh | Aggiorna app in background |
| Low Power Mode | modalità Risparmio energetico |
| Notifications | Notifiche |
| Shortcuts, Automation | Comandi Rapidi, Automazione |
| Time of Day, Run Immediately, Next | Ora del giorno, Esegui immediatamente, Avanti |
| action (in Shortcuts) | azione |
| Keychain | portachiavi |
| Files | File |
| Reconfigure (Home Assistant) | Riconfigura |
| Active Energy / Resting Heart Rate | Energia attiva / Frequenza cardiaca a riposo |
| Apps Script "Who has access" / "Anyone" | "Chi ha accesso" / "Chiunque" |

#### Android system words

| English | Italian |
|---|---|
| Health Connect | Connessione Salute (Google localizes the name in Italian) |
| Screen Time / Digital Wellbeing | Tempo di utilizzo / Benessere digitale |
| usage access | accesso ai dati di utilizzo |
| Steps, Resting heart rate | Passi, Frequenza cardiaca a riposo |
| Active calories burned, Total calories burned | Calorie attive bruciate, Calorie totali bruciate |
| Exercise | Sessioni di allenamento |
| Security > Encryption & credentials > Install a certificate | Sicurezza > Crittografia e credenziali > Installa un certificato |
| Battery optimization | Ottimizzazione batteria |

### Portuguese (Brazil) (`pt-BR`)

"Você" throughout, as Apple and Google do in Brazilian Portuguese, with imperatives in the você form ("Toque", "Confira", "Digite"). Brazilian vocabulary only (celular, tela, arquivo, usuário, registro, baixar), sentence case on Android and in the app's own labels, Apple's Title Case only where the term is Apple's own (Health data types, settings items, Shortcuts labels). Typographic quotes “ ” in sentences; straight quotes only in the Apps Script line, as in every language.

#### The app's words

| English | Portuguese (Brazil) |
|---|---|
| sync (verb) | sincronizar |
| sync (noun) | sincronização |
| Sync Now | Sincronizar agora |
| Sync Schedule, sync time | Agenda de sincronização, horário de sincronização |
| Sync History | Histórico de sincronização |
| Last sync | Última sincronização |
| health data | dados de saúde |
| data type | tipo de dado (plural: tipos de dados) |
| record(s) | registro(s) |
| log(s), Logs tab | log(s), aba Logs (kept, because "registro" is taken by record) |
| webhook URL | URL do webhook (feminine: a URL) |
| custom headers | cabeçalhos personalizados |
| signing secret | segredo de assinatura |
| payload | o payload |
| permission | permissão |
| queue, queued for retry | fila, na fila para nova tentativa (Android outbox: fila de saída) |
| Delivered, Published, Failed, Interrupted | Entregue, Publicado, Falhou, Interrompido |
| delivery | entrega |
| Backfill (button/tab action), Backfill History | Histórico, Enviar histórico |
| backfill (noun), backfilling | envio do histórico, enviando histórico |
| window, chunk (of a backfill) | bloco |
| window (of data resolution) | janela |
| daily totals | totais diários |
| quiet hours | horário de silêncio |
| pair, pairing code | parear, código de pareamento |
| receiver, destination | receptor, destino |
| the Life Dashboard integration | a integração Life Dashboard |
| plain HTTP | HTTP sem criptografia |
| test ping | ping de teste |
| day boundary | virada do dia |
| Cancel, Done | Cancelar, OK (iOS) |
| Health (the tab) | Saúde |
| Screen Time (the Android feature) | Tempo de tela |
| phone | celular |

#### iOS words

| English | Portuguese (Brazil) |
|---|---|
| Apple Health, the Health app | app Saúde (standalone label "App Saúde"); "os dados do Saúde" |
| Health access sheet | tela de acesso do Saúde |
| Settings | Ajustes |
| Settings > Privacy & Security > Local Network | Ajustes > Privacidade e Segurança > Rede Local |
| Settings > Health > Data Access & Devices | Ajustes > Saúde > Acesso a Dados e Dispositivos |
| Background App Refresh | Atualização em 2º Plano |
| Low Power Mode | Modo de Pouca Energia |
| Notifications | Notificações |
| Shortcuts, Automation | Atalhos, Automação |
| Time of Day, Run Immediately, Next | Hora do Dia, Executar Imediatamente, Seguinte |
| action (in Shortcuts) | ação |
| Keychain | Chaves (as in "Chaves do iCloud") |
| Files | Arquivos |
| Reconfigure (Home Assistant) | Reconfigurar |
| Health data types | Title Case as Apple's Health app: Passos, Energia Ativa, Energia Total, Frequência Cardíaca em Repouso, Oxigênio no Sangue, Água, Treinos, VO2 máx. ... |
| Siri intent title | Sincronizar dados de saúde (no "Apple") |
| Siri phrases | "Sincronizar meus dados de saúde com o ${applicationName}", "Sincronizar o ${applicationName}" |
| Apps Script "Who has access", "Anyone" | "Quem pode acessar", "Qualquer pessoa" |

#### Android system words

| English | Portuguese (Brazil) |
|---|---|
| Health Connect | Conexão Saúde (treated as masculine: "o Conexão Saúde", i.e. "o app") |
| Steps, Resting heart rate | Passos, Frequência cardíaca em repouso |
| Active calories burned, Total calories burned | Calorias ativas queimadas, Total de calorias queimadas |
| Exercise, Hydration, Blood glucose | Exercícios, Hidratação, Glicemia |
| Settings path for certificates | Configurações: Segurança, Criptografia e credenciais, Instalar um certificado, Certificado CA |
| Usage access | acesso aos dados de uso |
| Battery optimization | otimização de bateria |
| Xiaomi Battery saver, Huawei Phone Manager, Samsung Device Care | Economia de bateria, Gerenciador do telefone, Assistência do aparelho |
| Share sheet | menu de compartilhamento |
| Clipboard | área de transferência |

### Japanese (`ja`)

Polite desu/masu throughout, as Apple and Google do in Japanese; the user is never addressed with
あなた except in two headline-style strings ("Your health data, your server", "Your control").
Buttons and toggles are short nouns or verb stems (保存, 削除, 今すぐ同期, 設定を書き出す), titles have
no final punctuation. Full-width punctuation (、。：（）「」？), button names quoted with 「」, no spaces
between Japanese and Latin words (Apple style: "Webhook URLを追加"), Western digits everywhere.
Ranges use 〜 (wave dash), never a dash.

#### The app's words

| English | Japanese |
|---|---|
| sync (verb) | 同期する |
| sync (noun) | 同期 |
| Sync Now | 今すぐ同期 |
| Sync Schedule, sync time | 同期スケジュール, 同期時刻 |
| Sync History | 同期履歴 |
| Last sync | 最終同期 |
| health data | 健康データ (iOS system context: ヘルスケアデータ, as Apple says) |
| data type | データタイプ |
| record(s) | レコード; counter "件" |
| webhook URL | Webhook URL |
| custom headers | カスタムヘッダー |
| signing secret | 署名シークレット |
| payload | ペイロード |
| permission | 権限 (Apple Health access: アクセス) |
| queue, queued for retry | キュー, 再試行待ち |
| Delivered, Published, Failed, Interrupted | 配信済み, 公開済み, 失敗, 中断 |
| delivery | 配信 |
| Backfill, Backfill History | 過去データ送信 (both; verb 過去データを送信) |
| window, chunk (of a backfill) | ブロック |
| daily totals | 日別合計 |
| quiet hours | 休止時間帯 |
| pair, pairing code | ペアリング, ペアリングコード |
| receiver, destination | 受信側, 送信先 |
| the Life Dashboard integration | Life Dashboard統合 |
| plain HTTP | 暗号化されていないHTTP |
| Cancel, Done | キャンセル, 完了 |
| Health (the tab) | 健康 (quoted as 「健康」タブ) |
| Screen Time (the tab/feature) | スクリーンタイム |
| Logs (tab) | ログ |
| Advanced | 詳細設定 |
| Export, Import (settings) | 書き出し, 読み込み |
| Nerd Stats | マニア向け統計 |
| test ping | テストPing |
| time window (data resolution) | 時間枠 |

#### iOS words

| English | Japanese |
|---|---|
| Apple Health, the Health app | ヘルスケア, ヘルスケアApp |
| Settings > Privacy & Security > Local Network | 「設定」>「プライバシーとセキュリティ」>「ローカルネットワーク」 |
| Settings > Health > Data Access & Devices | 「設定」>「ヘルスケア」>「データアクセスとデバイス」 |
| Background App Refresh | Appのバックグラウンド更新 |
| Low Power Mode | 低電力モード |
| Notifications | 通知 |
| Shortcuts, Automation | ショートカット, オートメーション |
| Time of Day, Run Immediately, Next | 時刻, すぐに実行, 次へ |
| action (in Shortcuts) | アクション |
| Keychain | キーチェーン |
| Reconfigure (Home Assistant) | 再設定 |
| Resting Heart Rate, Active Energy | 安静時心拍数, アクティブエネルギー |
| Workouts, Oxygen Saturation, VO2 Max | ワークアウト, 血中酸素ウェルネス, 最大酸素摂取量 |
| Ovulation Test, Cervical Mucus | 排卵検査結果, 頸管粘液の状態 |

#### Android system words

| English | Japanese |
|---|---|
| Health Connect | ヘルスコネクト |
| Steps, Resting heart rate, Active calories burned | 歩数, 安静時心拍数, アクティブ消費カロリー |
| Total calories, Exercise, Hydration | 総消費カロリー, エクササイズ, 水分補給 |
| Settings path for certificates | セキュリティ, 暗号化と認証情報, 証明書のインストール, CA証明書 |
| Usage access | 使用状況へのアクセス |
| Battery optimization | 電池の最適化 |
| Device Care (Samsung), Phone Manager (Huawei) | デバイスケア, スマートフォンマネージャー |

#### Google Apps Script labels (deployment dialog)

- "Who has access" = "アクセスできるユーザー"
- "Anyone" = "全員"

Used in straight double quotes: `"アクセスできるユーザー"を"全員"にして`.

### Arabic (`ar`)

Gender-neutral throughout: buttons, labels, switches and titles are verbal nouns (إضافة، المزامنة الآن، تصدير
الإعدادات), status lines use passives with تم or impersonal forms, and "your" is the unvoweled suffix ـك, which
reads for anyone. Running instructions in body text ("أزل الترويسة"، "اضغط على") use the plain imperative, as
Apple and Google do in Arabic, because a verbal noun there reads like a manual. Arabic punctuation (، ؛ ؟),
«» for quoted button and tab names, straight "..." only for the Apps Script labels and header names in %@. Tap is اضغط على on iOS (Apple) and انقر على on Android (Google).

Digits: every number that is literal in the English text (3, 7, 15, 30, 34, 100, 700, 8883, 65535,
192.168.1.10, KvK 81085583) is written with Western digits 0-9, as the code and the tests expect. Numbers coming from placeholders are formatted by the system; on a phone set to Arabic with
Arabic-Indic digits they will show as ٠-٩, so a screen may mix both. Check it in the screenshots.

No invisible direction marks (LRM/RLM) are used; add one only where a screenshot shows a string
laid out wrong.

Plurals: all six CLDR cases. one and two drop the number and use the singular with واحد/واحدة and the dual;
few uses the plural (3-10), many the singular accusative (11-99, e.g. إدخالًا، مزامنةً), zero and other the
singular genitive after the number. Where a verb or adjective would have to agree with a count in many places,
the text uses تم + verbal noun ("تم إرسال ...") so only the noun changes.

#### The app's words

| English | Arabic |
|---|---|
| sync (verb / noun) | مزامنة (verbal noun for both); plural مزامنات |
| Sync Now | المزامنة الآن (quoted in sentences as «المزامنة الآن») |
| Sync Schedule, sync time | جدول المزامنة، وقت المزامنة |
| Sync History | سجل المزامنة |
| Last sync | آخر مزامنة |
| health data | البيانات الصحية |
| data type | نوع البيانات، أنواع البيانات |
| record(s) | إدخال، إدخالات (not سجل, which is reserved for logs) |
| log(s), Logs tab | سجل، السجلات؛ علامة التبويب «السجلات» |
| webhook, webhook URL | webhook (kept Latin)؛ عنوان webhook، عناوين webhook |
| custom headers, header | ترويسات مخصصة، ترويسة |
| signing secret | سر التوقيع |
| payload | الحمولة، الحمولات |
| permission | إذن، أذونات |
| queue, queued for retry | قائمة الانتظار؛ في قائمة الانتظار لإعادة المحاولة |
| Delivered, Published, Failed, Interrupted | تم التسليم، تم النشر، فشل، انقطع |
| delivery | تسليم، عمليات التسليم |
| Backfill, Backfill History | استكمال، استكمال البيانات السابقة |
| window, chunk (of a backfill) | دفعة، دفعات |
| time window (data resolution) | فترة (متوسط لكل فترة) |
| daily totals | المجاميع اليومية |
| quiet hours | ساعات الهدوء |
| pair, pairing code | إقران، رمز الإقران |
| receiver | جهة الاستقبال |
| destination | الوجهة، الوجهات |
| the Life Dashboard integration | تكامل Life Dashboard |
| plain HTTP | HTTP غير المشفّر |
| broker, topic, base topic | الوسيط، الموضوع، الموضوع الأساسي |
| sensor | مستشعر |
| test ping | اختبار الاتصال |
| Cancel, Done | إلغاء، تم |
| Health (the tab) | الصحة |
| Screen Time (the Android feature/tab) | مدة استخدام الشاشة |

#### iOS words

| English | Arabic |
|---|---|
| Apple Health, the Health app | صحتي، تطبيق صحتي (the standalone label "Apple Health" is just صحتي) |
| Health access sheet | نافذة الوصول إلى صحتي |
| Settings > Privacy & Security > Local Network | الإعدادات > الخصوصية والأمن > الشبكة المحلية |
| Settings > Health > Data Access & Devices | الإعدادات > صحتي > الوصول إلى البيانات والأجهزة |
| Background App Refresh | تحديث التطبيقات في الخلفية |
| Low Power Mode | وضع الطاقة المنخفضة |
| Notifications | الإشعارات |
| Shortcuts, Automation | الاختصارات، الأتمتة |
| Time of Day, Run Immediately, Next | وقت من اليوم، التشغيل فورًا، التالي |
| action (in Shortcuts) | إجراء |
| Keychain | سلسلة المفاتيح |
| Reconfigure (Home Assistant) | إعادة التكوين |
| Resting Heart Rate, Active Energy, Heart Rate, HRV | معدل نبض القلب أثناء الراحة، الطاقة النشطة، نبض القلب، تقلب معدل نبض القلب |
| Oxygen Saturation, Hydration, Intermenstrual Bleeding | أكسجين الدم، الماء، التبقيع |
| Apps Script "Who has access" / "Anyone" | "مَن يمكنه الوصول" / "أي شخص" (best guess, see below) |

#### Android system words

| English | Arabic |
|---|---|
| Health Connect | Health Connect (Google keeps the Latin name in Arabic) |
| Steps, Resting heart rate, Active calories burned | الخطوات، معدّل النبض أثناء الراحة، السعرات الحرارية المحروقة نتيجة ممارسة نشاط بدني |
| Total calories burned, Heart rate variability | إجمالي السعرات الحرارية المحروقة، تغيُّر معدّل نبضات القلب |
| Oxygen saturation, Blood glucose, Mindfulness | نسبة الأكسجين في الدم، الغلوكوز في الدم، الاسترخاء |
| Security, Encryption & credentials, Install a certificate | الأمان، التشفير وبيانات الاعتماد، تثبيت شهادة |
| usage access | الوصول إلى بيانات الاستخدام |
| Battery optimization | تحسين البطارية |
| Battery saver (Xiaomi), Phone Manager (Huawei), Device Care (Samsung) | موفر البطارية، مدير الهاتف، العناية بالجهاز |

### Hindi (`hi`)

आप throughout, polite imperative (-एं / -ें) for buttons, gender-neutral phrasing where possible (e.g. "इसे बाद में सेट करें" instead of a first-person masculine "करूंगा"). Common English tech loanwords in Devanagari (सिंक, वेबहुक, पेलोड, सर्टिफ़िकेट, ब्रोकर) as Apple and Google Hindi do; names, wire keys and protocols stay Latin. Sentences end with the danda (।) as in Apple and Google Hindi UIs; Western digits everywhere. Spelling follows each platform: iOS uses chandrabindu (सूचनाएँ, हटाएँ) and "सेटिंग्ज़" like Apple, Android uses anusvara (सूचनाएं, हटाएं) and "सेटिंग" like Google.

#### The app's words

| English | Hindi |
|---|---|
| sync (verb) | सिंक करना (button: सिंक करें) |
| sync (noun) | सिंक (plural also सिंक) |
| Sync Now | अभी सिंक करें |
| Sync Schedule, sync time | सिंक शेड्यूल, सिंक का समय |
| Sync History | सिंक इतिहास |
| Last sync | पिछला सिंक |
| health data | स्वास्थ्य डेटा |
| data type | डेटा टाइप |
| record(s) | रिकॉर्ड (invariable) |
| webhook, webhook URL | वेबहुक, वेबहुक URL |
| custom headers | कस्टम हेडर |
| signing secret | साइनिंग सीक्रेट |
| payload | पेलोड |
| permission | अनुमति (plural अनुमतियां on Android, अनुमतियाँ on iOS) |
| queue, queued for retry | कतार, फिर से कोशिश के लिए कतार में |
| Delivered, Published, Failed, Interrupted | डिलीवर हुआ, पब्लिश हुआ, विफल, बाधित |
| delivery | डिलीवरी |
| Backfill, Backfill History | बैकफ़िल, इतिहास बैकफ़िल करें |
| window, chunk (of a backfill) | हिस्सा / हिस्से |
| time window (data resolution) | विंडो |
| daily totals | दैनिक योग |
| quiet hours | शांत समय |
| pair, pairing code | पेयर करें, पेयरिंग कोड |
| receiver | रिसीवर |
| destination | गंतव्य |
| the Life Dashboard integration | Life Dashboard इंटीग्रेशन |
| plain HTTP | बिना एन्क्रिप्शन वाला HTTP |
| Receive (Android section) | पाएं |
| measurement | मेज़रमेंट |
| Cancel, Done | रद्द करें, पूर्ण (iOS) |
| Health (the tab) | स्वास्थ्य |
| Screen Time | स्क्रीन टाइम |
| Logs | लॉग |
| Advanced | बेहतर सेटिंग |
| error | त्रुटि (iOS), गड़बड़ी (Android, Google style) |

#### iOS words

| English | Hindi |
|---|---|
| Apple Health, the Health app | Apple स्वास्थ्य, स्वास्थ्य ऐप |
| Settings > Privacy & Security > Local Network | सेटिंग्ज़ > गोपनीयता और सुरक्षा > स्थानीय नेटवर्क |
| Settings > Health > Data Access & Devices | सेटिंग्ज़ > स्वास्थ्य > डेटा ऐक्सेस और डिवाइस |
| Background App Refresh | बैकग्राउंड ऐप रीफ़्रेश |
| Low Power Mode | लो पावर मोड |
| Notifications | सूचनाएँ |
| Shortcuts, Automation | शॉर्टकट्स, ऑटोमेशन |
| Time of Day, Run Immediately, Next | दिन का समय, तुरंत चलाएँ, अगला |
| action (in Shortcuts) | क्रिया |
| Keychain | कीचेन |
| Reconfigure (Home Assistant) | फिर से कॉन्फ़िगर करें |
| Steps, Heart Rate, Resting Heart Rate, HRV | क़दम, हृदय गति, विश्राम हृदय गति, हृदय गति परिवर्तनशीलता |
| Blood Pressure, Blood Glucose, Respiratory Rate | रक्तचाप, रक्त ग्लूकोज़, श्वसन दर |
| Active Calories (app label) | सक्रिय कैलोरी |
| Apps Script: "Who has access", "Anyone" | "किसके पास ऐक्सेस है", "कोई भी" |

#### Android system words

| English | Hindi |
|---|---|
| Health Connect | Health Connect (Google keeps the name in Latin in Hindi) |
| Steps, Heart Rate, Resting heart rate | क़दम, हृदय गति, आराम के समय हृदय गति |
| Active calories, Total calories | ऐक्टिव कैलोरी, कुल कैलोरी |
| Settings > Security, Encryption & credentials, Install a certificate | सेटिंग > सुरक्षा, एन्क्रिप्शन और क्रेडेंशियल, सर्टिफ़िकेट इंस्टॉल करें |
| usage access | इस्तेमाल का ऐक्सेस |
| Battery optimization | बैटरी ऑप्टिमाइज़ेशन |
| Notifications | सूचनाएं |

### Simplified Chinese (`zh-Hans`)

Android keeps 您, as Google writes zh-CN Android and as the existing file does. iOS uses 你,
as Apple does in Simplified Chinese (iOS, Health, Settings). iOS follows Apple's word choices
for platform verbs and nouns (App, 轻点, 拷贝, 共享, 存储), Android keeps Google's (应用, 点按,
复制, 分享); the app's own concepts are identical on both. Full-width punctuation, Chinese
quotes “” around button and tab names, a space between Chinese and Latin or digits, no em dash
or Chinese double dash.

#### The app's words (same on both platforms)

| English | zh-Hans |
|---|---|
| sync (verb, noun) | 同步 |
| Sync Now | 立即同步 |
| Sync Schedule, sync time | 同步计划, 同步时间 |
| Sync History | 同步历史记录 |
| Last sync | 上次同步 |
| health data | 健康数据 |
| data type | 数据类型 |
| record(s) | 记录 (counted: N 条记录) |
| webhook, webhook URL | Webhook, Webhook 网址 |
| address (of a destination) | 地址 |
| custom headers | 自定义请求头 (header: 请求头) |
| signing secret, secret | 签名密钥, 密钥 |
| payload | 数据包 |
| permission | 权限 |
| queue, queued for retry | 队列 / 待发送队列, 已加入重试队列 |
| Delivered, Published, Failed, Interrupted | 已送达, 已发布, 失败, 已中断 |
| delivery | 传送 |
| Backfill, Backfill History | 补全, 补全历史数据 |
| window, chunk (of a backfill) | 批 ("第 1 批（共 5 批）", "每批 3 天") |
| daily totals | 每日总计 |
| quiet hours | 免打扰时段 |
| pair, pairing code | 配对, 配对码 |
| receiver, destination | 接收端, 目标地址 |
| the Life Dashboard integration | Life Dashboard 集成 |
| MQTT broker | MQTT 代理服务器 |
| plain HTTP | 普通 HTTP |
| test ping | 测试 Ping |
| Cancel, Done | 取消, 完成 |
| Health (the tab), Logs (the tab) | “健康”标签页, “日志”标签页 |
| Nerd Stats | 极客统计 |

#### iOS words

| English | zh-Hans |
|---|---|
| Apple Health, the Health app | Apple 健康, “健康”App |
| Health access sheet | 健康访问权限页面 |
| Settings > Privacy & Security > Local Network | “设置”>“隐私与安全性”>“本地网络” |
| Settings > Health > Data Access & Devices | “设置”>“健康”>“数据访问与设备” |
| Background App Refresh | 后台 App 刷新 |
| Low Power Mode | 低电量模式 |
| Notifications | 通知 |
| Shortcuts, Automation | 快捷指令, 自动化 |
| Time of Day, Run Immediately, Next | 特定时间, 立即运行, 下一步 |
| action (in Shortcuts) | 操作 |
| Keychain | 钥匙串 |
| Copy, Share, Save | 拷贝, 共享, 存储 |
| tap, swipe | 轻点, 轻扫 |
| app | App |
| Active Energy / Total | 活动能量 / 总能量 |
| Resting Heart Rate, Heart Rate Variability | 静息心率, 心率变异性 |
| Body Fat, Lean Body Mass | 体脂率, 去脂体重 |
| Oxygen Saturation, Respiratory Rate | 血氧饱和度, 呼吸速率 |
| Workouts (Exercise Sessions) | 体能训练 |
| Spotting (Intermenstrual Bleeding), Cervical Mucus Quality, Ovulation Test Result | 点滴出血, 宫颈黏液质量, 排卵测试结果 |
| Water (Hydration), Mindfulness, Sexual Activity | 饮水, 正念, 性行为 |

#### Android system words

| English | zh-CN |
|---|---|
| Health Connect | 健康数据共享 (quoted “健康数据共享” in running text, as the existing file does) |
| Steps, Resting heart rate, Active calories | 步数, 静息心率, 运动消耗的卡路里 |
| Bone mass, Skin temperature | 骨质密度, 体表温度 (Google's own zh-CN Health Connect data type page uses exactly these) |
| Screen time / usage access | 屏幕使用时间 / 使用情况访问权限 |
| Battery optimization | 电池优化 |
| Settings path (certificates) | 安全、加密与凭据 > 安装证书 |
| tap | 点按 |

## Checking the layout

German and French run about a third longer than English, and Arabic runs right to left. Run the
app in German, French and Arabic before a release, or after changing a screen: in Xcode set the scheme's App Language (Edit Scheme > Run >
Options), or launch the simulator app with `-AppleLanguages "(de)" -AppleLocale de_DE`. The Debug
launch arguments `-ld.tab 1`, `-ld.about YES`, `-ld.nerd YES`, `-ld.privacy YES`, `-ld.expand YES`,
`-ld.step 0...4` and `-ld.scroll 0.5` open every page directly.

In Arabic, check that the layout mirrors (back arrows, chevrons, progress), that numbers, URLs,
hosts and MQTT topics read left to right inside the Arabic sentence, and that a settings path such
as "الإعدادات > الخصوصية والأمان" keeps its order. Placeholders format numbers the way the phone is
set up, so a screen can show Arabic-Indic digits next to the Western digits that are literal in a
sentence.
