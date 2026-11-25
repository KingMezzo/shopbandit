# Kategorien / Categories – ShopBandit 1.1.0

## Verhalten

Die zwölf Standardkategorien gehören zum Haushalt. Ihre PocketBase-ID ist
`sha256("<household>|category|<key>").substring(0, 15)` und stimmt auf allen Geräten
überein. Leere Namen werden auf Deutsch oder Englisch angezeigt; ein selbst
vergebener Name hat in beiden Sprachen Vorrang. Zurücksetzen leert nur den Namen.

Einstellungen → **Kategorien verwalten**: erstellen, umbenennen und per langem
Drücken/Drag oder Menü sortieren. Standardkategorien bleiben erhalten. Beim
Löschen einer eigenen Kategorie werden alle Produkte, auch ausgeblendete
Katalogprodukte, atomar nach **Sonstiges** verschoben. `deleted` ist ein dauerhafter
Soft-Delete; eine neue Kategorie erhält eine neue ID. Im PocketBase-Dashboard sind
alle Kategorien sichtbar. Dort zum Entfernen einer eigenen Kategorie `deleted`
setzen; ein physisches Löschen wird zum Schutz der Offline-Geräte abgewiesen.
Beim Löschen eines verlassenen Haushalts darf PocketBase seine Daten weiter per
Cascade entfernen.

Offene Listeneinträge sind nach `sort_order` gruppiert und aufklappbar. Die
Kategorieauswahl im Produktdialog speichert sofort, auch beim anschließenden
Abbrechen der Mengenänderung. Sie gehört zum Katalogprodukt und gilt für spätere
Einkäufe. Mengen werden weiterhin mit **Speichern** übernommen. Im Artikelkatalog
gibt es Suche, Kategorieanzeige, Filter, Kategorieauswahl und die bisherige
Löschfunktion. Kategorien und Zuordnungen lassen sich vollständig offline ändern.

## Daten und Synchronisierung

- Neue additive Migration: `server/pb_migrations/1795600000_categories.js`.
  Die ursprüngliche Migration bleibt unverändert. Die neue Migration legt
  Kategorien für bestehende Haushalte an und kategorisiert den bestehenden
  Katalog einmalig. Namen, IDs, Kaufstatistiken und Listeneinträge bleiben erhalten.
- `categories`: `household`, `key`, `name`, `is_default`, `sort_order`, `icon`,
  `color`, `deleted`, `created`, `updated`. `(household, key)` ist eindeutig.
- `catalog_items`: zusätzliche Relation `category`, außerdem `category_manual`
  und `category_version`. Fehlende Zuordnungen alter Clients werden serverseitig
  gefüllt. Neue Haushalte erhalten die Standards im selben Schreibvorgang.
- Drift-Schema 2 erweitert die vorhandene Datenbank mit `CREATE TABLE` und
  `ALTER TABLE`; Katalog und Liste werden weder ersetzt noch gelöscht.
  Haushaltsstart initialisiert lokale Standards auch ohne Internet.
- Manuelle Zuordnungen sind dauerhaft markiert. Automatische Zuweisungen können
  eine vorhandene manuelle Auswahl serverseitig nicht überschreiben.
- Kategorieänderungen laufen über dieselbe transaktionale Outbox, Pull-Cursor und
  PocketBase-Realtime wie die bisherigen Daten. Ein wiederholtes `create` setzt
  weder bestehende Kategorienamen noch Kaufzähler/manuelle Zuordnungen zurück.
- Bei konkurrierenden Umbenennungen/Reihenfolgen gilt die zuletzt am Server
  angenommene Änderung pro Datensatz. Bei gleichen Sortierwerten entscheidet die
  ID, sodass alle Geräte dieselbe Reihenfolge anzeigen. **Löschen gewinnt** über
  eine verspätete Umbenennung, Wiederherstellung oder Produktzuordnung.
- Tombstones korrigieren auch noch nicht gesendete lokale Produktzuordnungen.
  Bereits übersprungene Datensätze werden nach Outbox-Verarbeitung erneut gelesen.
- Reguläre Haushaltsmitglieder dürfen Kategorien und Produkte schreiben. Regeln
  und Modell-Hooks prüfen die Haushaltstrennung; die Modell-Hooks schützen auch
  Änderungen im Admin-Dashboard. Kategorieidentität und Standardstatus sind fest.

Das Wörterbuch enthält 792 eindeutige vollständige Namen/Synonyme mit Schwerpunkt
Deutsch, dazu Englisch. Normalisiert werden Großschreibung, Leerzeichen,
Bindestriche und einfache Umlautvarianten. Es gibt keine Teilstring-Suche, externe
KI oder Netzwerkabhängigkeit. Unbekannte Produkte landen in Sonstiges.

Zum Erweitern `tools/category_dictionary.json` bearbeiten und
`python tools/generate-categories.py` ausführen. Dart und Serverdaten werden aus
derselben Quelle erzeugt; CI prüft sie mit `--check`. Der Wörterbuch-Snapshot in
der veröffentlichten Migration bleibt eingefroren. Neue Wörter gelten für neue
Produkte; bestehende manuelle Kategorien werden nicht neu berechnet.

## Bauen und lokal prüfen

Voraussetzungen: Flutter **3.47.7** / Dart **3.13.5**, Java 17 oder kompatibler
Android-JDK, Android SDK/NDK, Python 3, Docker/Buildx. SQLite wird wie bisher aus
den im Repository festgelegten Quellen gebaut. Für Linux-Tests wird `clang`
benötigt. Keine Abhängigkeit wurde für die Erweiterung herabgestuft.

```sh
# Repository-Wurzel, Linux/macOS oder geeignete Bash-Umgebung
bash tools/verify-categories.sh

# ARM64-Image für Raspberry Pi 5, nur lokal laden
docker buildx build --platform linux/arm64 --load \
  -t shopbandit-server:categories-1.1.0 server

# Separater Testserver: eigenes anonymes Volume, nur localhost
docker run -d --name shopbandit-category-test -p 127.0.0.1:18090:8090 \
  shopbandit-server:categories-1.1.0
python3 server/scripts/category-test.py http://127.0.0.1:18090

# Echte App-Synchronisierung mit zwei SQLite-Datenbanken und Realtime
cd app
flutter test test/pocketbase_sync_integration_test.dart \
  --dart-define=SHOPBANDIT_TEST_URL=http://127.0.0.1:18090
cd ..

# Erstellt eigene alte Testdaten, kopiert deren gestopptes Volume, migriert
# ausschließlich die Kopie und prüft Datenerhalt sowie einen Neustart.
# Entfernt anschließend nur die selbst erzeugten Testcontainer und -volumes.
python3 server/scripts/test-category-upgrade.py \
  --image shopbandit-server:categories-1.1.0
```

Für einen Multiarch-Release den bestehenden Workflow verwenden oder nach eigener
Freigabe `docker buildx build --platform linux/amd64,linux/arm64 --push -t <registry>/<image>:1.1.0 server`.
Ein lokaler Build lädt oder veröffentlicht nichts auf dem Raspberry Pi.

Test-APK: `app/build/app/outputs/flutter-apk/app-debug.apk`. Die Debug-Signatur ist
anders als eine reguläre Release-Signatur. Auf einem separaten Testgerät/Emulator
testen. Zum Erhalt einer vorhandenen Installation ein Release mit demselben
Keystore und erhöhtem Versionscode bauen; die App nicht deinstallieren.
Release-Signierung: [RELEASE.md](RELEASE.md). App-Version: **1.1.0+6**.

## Produktives Update auf dem Raspberry Pi

Diese Anleitung ist manuell auszuführen. Die Implementierung führt keine
Verbindung zum Pi aus und ändert keine produktiven Docker-, Caddy- oder
Tailscale-Dienste. **Server zuerst, Android-App danach aktualisieren.** Der neue
Client setzt das neue Serverschema voraus. Alte Clients können weiterhin Listen
und Produkte verwenden; fehlende Kategorien werden durch den neuen Server ergänzt.

1. Alle Geräte zunächst synchronisieren lassen. Aktuelle Image-ID/Digest und
   Compose-Dateien sichern. Vor dem Wartungsfenster die Mounts des tatsächlich
   verwendeten PocketBase-Containers prüfen. Im beschriebenen System muss
   `/mnt/ssd/projects/shopbandit/server/pb_data/` nach `/pb/pb_data` zeigen.
   Das Repository-Beispiel verwendet hingegen ein benanntes Volume. Diese
   Konfiguration nicht ungeprüft über die vorhandene Installation kopieren.
2. Einen konsistenten vollständigen Backupstand anlegen. Für die sicherste
   Dateikopie PocketBase gezielt stoppen und das gesamte `pb_data` sichern,
   einschließlich SQLite-Dateien und Storage. Das folgende Beispiel ist für
   das Wartungsfenster gedacht; `pocketbase` muss der tatsächliche Servicename sein:

   ```sh
   # Aus dem Verzeichnis der tatsächlich verwendeten Compose-Datei
   docker compose stop pocketbase
   stamp=$(date +%Y%m%d-%H%M%S)
   backup_dir=/mnt/ssd/backups/shopbandit
   mkdir -p "$backup_dir"
   backup="$backup_dir/pb-data-before-categories-$stamp.tar.gz"
   tar -C /mnt/ssd/projects/shopbandit/server -czf "$backup" pb_data
   chmod 600 "$backup"
   sha256sum "$backup" > "$backup.sha256"
   tar -tzf "$backup" > /dev/null
   ```

   Bei einem laufenden Server alternativ das vorhandene `server/scripts/backup.sh`
   verwenden; niemals nur eine laufende `data.db` per `cp` kopieren. Den alten
   Image-Digest aufbewahren, weil `latest` später auf ein anderes Image zeigen kann.
3. Das Backup in einen **neuen separaten Testordner** entpacken. Beispiel:

   ```sh
   test_dir=$(mktemp -d /mnt/ssd/projects/shopbandit/category-test.XXXXXX)
   tar -C "$test_dir" -xzf "$backup"
   docker network create --internal shopbandit-category-isolated
   docker run -d --name shopbandit-real-copy-test \
     --network shopbandit-category-isolated \
     -p 127.0.0.1:18090:8090 \
     -v "$test_dir/pb_data:/pb/pb_data" \
     shopbandit-server:categories-1.1.0
   docker logs shopbandit-real-copy-test
   ```

   Den Zielpfad vorher prüfen: Er darf **nicht** der produktive `pb_data`-Pfad
   sein. Bei Berechtigungsproblemen ausschließlich die Testkopie für UID 10001
   les-/schreibbar machen. In der Testkopie keine SMTP- oder Push-Konfiguration
   aktivieren. Ein echtes Backup kann gespeicherte SMTP-Einstellungen enthalten;
   das Beispiel verwendet deshalb ein internes Docker-Netz ohne ausgehende
   Verbindung. Darin bleibt auch der vorhandene Push-Cron vom Internet
   getrennt. Keine Produktionsgeheimnisse in Logs oder Testberichte übernehmen.
4. In der Kopie Produkt-/Listenzahlen, IDs und Kaufzähler vor/nach der Migration
   vergleichen. Mit einem normalen Testmitglied Kategorien erstellen/umbenennen,
   offline ändern, auf einem zweiten Testgerät synchronisieren und eine eigene
   Kategorie mit Produkten löschen. Standardkategorien müssen erhalten bleiben.
   Der API-Test legt zusätzliche Wegwerfkonten an und ist für eine vollständig
   isolierte Datenkopie gedacht.
5. Erst nach erfolgreicher Probe in der **bestehenden** Compose-Konfiguration
   ausschließlich PocketBase auf das geprüfte versionierte Image bzw. dessen
   Digest setzen. Den vorhandenen Daten-Mount unverändert beibehalten.
   `docker compose up -d --no-deps pocketbase` startet nur diesen Dienst.
   Logs und `/api/health` kontrollieren. ntfy, Caddy und Tailscale bleiben unverändert.
6. Danach signierte Android-Updates installieren. Nach dem ersten Start prüfen:
   vorhandene Artikel bleiben erhalten, Kategorien sind sichtbar und die Outbox
   wird geleert. App-Update migriert die lokale Datenbank auch ohne Verbindung.

## Rollback

Ein altes Image allein stellt die vorherige Datenbank nicht wieder her. Es gibt
bewusst keine destruktive Down-Migration. Vor dem Rollback PocketBase stoppen und
den aktuellen Zustand zusätzlich sichern. Den aktualisierten Datenordner zur
Diagnose **umbenennen und aufbewahren**, dann das Backup in einen neuen `pb_data`-
Ordner entpacken und mit dem gespeicherten alten Image-Digest starten. Mountpfad,
Besitzer und Rechte prüfen. Keine Verzeichnisse löschen, kein `docker compose down -v`.

Änderungen seit dem Backup vorher separat sichern; sie sind im alten Backup
nicht enthalten. Android-App nach Möglichkeit erst nach bestätigtem Serverupdate
verteilen. Eine bereits auf Schema 2 migrierte lokale Datenbank nicht mit einem
erzwungenen App-Downgrade öffnen; den reparierten Server bevorzugen und alle
ausstehenden lokalen Änderungen erhalten.

## Prüfumfang und Grenzen

Lokal verifiziert am **25.11.2026**:

| Prüfung | Ergebnis |
|---|---|
| `flutter analyze --fatal-infos --no-pub` | Keine Befunde |
| Gesamte Flutter-Suite mit echtem PocketBase-Testserver | **49 Tests bestanden**, kein übersprungener Test |
| Drift v1 → v2 mit gefüllter SQLite-Datenbank | Bestand und ausstehende Outbox erhalten |
| PocketBase-Kategorien-API auf ARM64 | Rechte, Haushaltstrennung, parallele Änderungen und Löschschutz bestanden |
| Bestehender Server-Smoke-Test auf dem endgültigen Image | Listen, Kaufzähler, Einladungen, Mitgliederrechte und Push-Endpunktprüfung bestanden |
| Gefüllte alte PocketBase-Testdatenbank kopieren → Upgrade → Neustart | Bestanden, Quelldatenbank unverändert |
| Android Debug APK | Gebaut, Paket `at.macrobandit.shopbandit`, Version `1.1.0`, Code `6` |
| Docker | Lokales ARM64-Image `shopbandit-server:categories-1.1.0` gebaut und getestet |

Die APK liegt unter `app/build/app/outputs/flutter-apk/app-debug.apk`; die
Prüfsumme wird daneben als `app-debug.apk.sha256` abgelegt. App-Testprotokoll im
lokalen Checkout: `.test-artifacts/final-tests.log` (bewusst nicht versioniert).

Die automatischen Tests umfassen Wörterbuch und Übersetzungen, Standard-/eigene
Kategorien, manuelle Auswahl, Soft-Delete/Wiederherstellung, Offline-Outbox, zwei
Geräte, verspätete Creates/Realtime-Ereignisse, Haushaltstrennung, Migration einer
echten SQLite-v1-Struktur, Listenbedienung und Katalogsuche. Echte PocketBase-Tests
prüfen außerdem parallele Schreibzugriffe, die regulären API-Rechte sowie Upgrade
und Neustart einer Kopie einer gefüllten alten Testdatenbank. Die bisherige
Server-Smoke-Suite bleibt Bestandteil der Prüfung. Der separate App-Integrationstest
verwendet den echten PocketBase-SDK-Adapter, zwei SQLite-Datenbanken, einen
simulierten Verbindungsabbruch und eine echte Realtime-Subscription. Ohne
`SHOPBANDIT_TEST_URL` wird nur dieser Netzwerktest übersprungen; CI führt ihn
zusätzlich gegen einen eigens gestarteten Testserver aus.

Die produktive Pi-Datenbank wurde nicht bereitgestellt und nicht angefasst.
Der Test mit ihrer tatsächlichen Kopie ist deshalb der oben dokumentierte
Schritt vor dem produktiven Update. Ein physischer Android-/Push-End-to-End-Test
auf zwei Geräten bleibt zusätzlich zur automatischen Prüfung sinnvoll.

## English update notes

Update the server before the Android app. Back up the complete PocketBase data
directory and pin the current server image digest. Test the new image against a
separate restored copy, never the production mount. The additive migration keeps
catalog/list IDs, names and purchase statistics. Drift upgrades in place offline.
Household defaults have deterministic IDs; custom names override translations.
Manual product categories are never replaced by automatic classification.
Deleting a custom category atomically moves its products to Other; deletion wins
over stale offline edits. Default categories cannot be removed.

Build with the existing Flutter toolchain or `bash tools/verify-categories.sh`.
Use `docker buildx build --platform linux/arm64 --load -t shopbandit-server:categories-1.1.0 server`
for Raspberry Pi 5. Run `category-test.py` and `test-category-upgrade.py` only with
disposable local servers. Debug APKs need a separate test device when the installed
production APK has a different signing key. Preserve the original signing key for
in-place updates. Roll back by restoring the pre-update backup together with its
old server image; preserve the migrated directory and any newer writes first.
No production services or data are changed automatically.
