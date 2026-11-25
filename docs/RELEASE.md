# Releases im Fork KingMezzo/shopbandit

Die Workflows veröffentlichen ausschließlich nach
`https://github.com/KingMezzo/shopbandit/releases` und
`ghcr.io/kingmezzo/shopbandit-server`. Der `upstream`-Git-Remote und Hinweise auf
den ursprünglichen Autor sind keine Veröffentlichungsziele. Produktive Server,
Datenbanken, Caddy, Tailscale und laufende Deployments werden nicht angesprochen.

## Auslöser und Ablauf

| Ereignis | CI (`ci.yml`) | Server image (`server-image.yml`) | Release (`release.yml`) | Mirror (`mirror.yml`) |
|---|---|---|---|---|
| Push nach `main` | Workflow-Lint, Release-Policy-Tests, Flutter-/PocketBase-Tests und Debug-APK | Kein automatischer Lauf | Kein Lauf | Kein Lauf |
| Push auf andere Branches ohne PR | Kein automatischer Lauf | Kein Lauf | Kein Lauf | Kein Lauf |
| PR öffnen, neue Commits im PR, PR erneut öffnen (gegen jeden Zielbranch) | Vollständige CI; keine Signierung und keine Release-Secrets | Bei Änderungen unter `server/**` oder an `server-image.yml`: Multiarch-Build ohne Login/Push | Kein Lauf | Kein Lauf |
| Push eines Tags `vX.Y.Z` im eigenen Fork | Vollständige CI als wiederverwendbarer Workflow aus Release | Vom Release nach erfolgreicher CI und APK-Signierung aufgerufen; veröffentlicht exakt `:X.Y.Z` | Signierte APKs und Serververweis als stabiles GitHub Release | Kein Lauf |
| Push eines Tags `vX.Y.Z-rc.N`, `-beta.N`, `-alpha.N` | Wie beim stabilen Tag | Ausschließlich der vollständige Vorabversions-Tag | Als GitHub-Prerelease | Kein Lauf |
| Ungültiger `v*`-Tag oder abweichende Basisversion | Versionsprüfung bricht vor Tests/Signierung/Veröffentlichung ab | Kein Aufruf | Kein Release | Kein Lauf |
| Manuelles Veröffentlichen/Bearbeiten eines Releases in der GitHub-Oberfläche | Kein zusätzlicher Lauf | Kein zusätzlicher Lauf | Kein zusätzlicher Lauf: kein `release`-Event konfiguriert | Kein Lauf |
| Mirror manuell über Actions anstoßen | – | – | – | Einzige Jobbedingung ist `false`; übersprungen, keine Schreibaktion |

Ein Tag-Push startet `release.yml`; der Image-Workflow hat absichtlich keinen
eigenständigen Tag-Trigger. Damit kann er keine Images vor bestandener CI oder
bei fehlender APK-Signierung veröffentlichen. Aufrufkette:

`Version prüfen → CI vollständig → APKs signieren/prüfen → ARM64+AMD64-Image → GitHub Release`

Ein Fehler stoppt abhängige Jobs. Ein bereits in GHCR veröffentlichtes Image und
ein GitHub Release sind zwei getrennte Dienste: Scheitert nur der letzte Schritt,
kann das versionierte Image bereits vorhanden sein. Das Release wird zunächst
als Draft mit allen Dateien aufgebaut und erst danach veröffentlicht. Das hilft
auch bei aktivierter GitHub Release Immutability. Bereits abgeschlossene Releases
nicht mit demselben Tag überschreiben; für weitere Tests eine neue Nummer verwenden.

## Prüfungen in CI

- `actionlint:1.7.7` einschließlich ShellCheck prüft alle Workflow-Dateien.
- Python-Tests unter `tools/tests` prüfen die Versions-/Vorabversionsregeln.
- `python3 tools/generate-categories.py --check` prüft das gemeinsame Wörterbuch
  und die Standardübersetzungen (Deutsch/Englisch).
- Flutter 3.47.7 / Java 17: Abhängigkeiten, Drift-Codegenerierung, `flutter gen-l10n`,
  `flutter analyze --fatal-infos`, alle regulären Flutter-Tests und Debug-APK.
- Separater PocketBase-Testcontainer für echte Offline-/Zwei-Geräte-/Realtime-
  Tests des Flutter-Sync-Adapters; der sonst übersprungene Netzwerktest läuft
  explizit mit `SHOPBANDIT_TEST_URL`.
- Separater Serverjob: bestehender Smoke-Test, Kategorien-API, Haushaltstrennung,
  Löschschutz, parallele Änderungen sowie Migration einer Kopie einer gefüllten
  v1-Testdatenbank und anschließender Neustart.
- Innerhalb dieses Jobs bekommen Smoke-Test (`pb`, Port 8090), Kategorien-API
  (`pb-category`, Port 8091) und Rate-Limit-Prüfung (`pb-rate`, Port 8092)
  jeweils einen eigenen frischen PocketBase-Prozess mit eigener Wegwerfdatenbank.
  Nur der Kategorienserver erhält den read-only gemounteten Snapshot-Test-Hook.
  Alle drei verwenden dieselben aktiven, unveränderten Produktionslimits.
- `server/scripts/rate-limit-test.py` prüft auf seiner eigenen Instanz die
  Gast-Erstellung (2/5 s), Anmeldung (2/3 s), deren normale Erholung nach Ablauf
  des Fensters und den gemeinsamen Einladungs-Präfix (10/60 s) über zwei Benutzer.
  Der elfte Einladungsrequest muss HTTP 429 liefern. Kein Limit wird zurückgesetzt
  oder heraufgesetzt und abgewiesene Schreibvorgänge werden nicht wiederholt.
- Healthchecks lassen den Job bei nicht bereitem PocketBase fehlschlagen.
  Testserver binden ausschließlich an localhost und werden am Ende entfernt.
- PR-Server-Builds und veröffentlichte Images verwenden
  `platforms: linux/amd64,linux/arm64`, Buildx und QEMU.

CI erzeugt das kurzlebige Actions-Artefakt `debug-apk` (7 Tage), kein GitHub
Release. Keine der Tests benötigt Produktionsdaten oder Produktions-Zugangsdaten.

### Warum die Server-Suiten getrennte Instanzen brauchen

Die Regel `/api/shopbandit/invites/` erlaubt insgesamt zehn Requests je IP in
60 Sekunden, gemeinsam für `create`, `check`, `accept` und `revoke`. Auch später
fachlich abgelehnte Requests zählen. Neue Testbenutzer erhalten keinen eigenen
IP-Zähler. Der Smoke-Test erzeugt neun solche Requests; die Kategorien-Suite
weitere zwei. Bei gemeinsamer Instanz kann deren abschließender Beitritt damit
als elfter Request korrekt HTTP 429 liefern. Das wurde mit der alten CI-Abfolge
und derselben Client-IP reproduziert; der Kategorie-/Berechtigungstest selbst
war dabei nicht die Ursache.

Frische Prozesse und Datenbanken isolieren die Tests voneinander, ohne das
produktive Verhalten zu ändern. Ein zusätzliches CI-Rate-Limit-Profil ist nicht
nötig. Die Produktions-Hooks, Einstellungen und Docker-Konfiguration bleiben
unverändert. Der API-Test meldet bei unerwartetem 429 zusätzlich seine Request-
Zähler und einen Hinweis auf notwendige Isolation. Er akzeptiert 429 weiterhin
nicht als Ersatz für den erwarteten Erfolg oder Berechtigungsfehler.

Die frühere Kombination auf einer gemeinsamen Instanz wurde lokal mit genau
dem 429 beim abschließenden `invites/accept` reproduziert. Anschließend bestanden
drei komplette Server-Durchläufe in der neuen isolierten Abfolge: Smoke-Test,
Kategorien mit `--stale-snapshot-tests` und jeweils zwölf Konfliktrunden,
Rate-Limit-Prüfung und Datenbankkopie-/Upgrade-/Neustarttest. Die Kategorien-Suite
erzeugt dabei 159 API-Requests ohne Healthchecks, davon nur zwei im Einladungs-
Präfix. Die Produktions-Rate-Limit-Konfiguration wurde nicht verändert.

## Secrets für Android-Signierung

Im **eigenen Repository** unter *Settings → Secrets and variables → Actions →
Repository secrets* hinterlegen:

| Secret | Inhalt |
|---|---|
| `SHOPBANDIT_KEYSTORE_BASE64` | Vollständige Keystore-Datei als Base64-Zeichenfolge |
| `SHOPBANDIT_KEYSTORE_PASSWORD` | Passwort des Keystores |
| `SHOPBANDIT_KEY_ALIAS` | Alias des privaten Signaturschlüssels im Keystore |
| `SHOPBANDIT_KEY_PASSWORD` | Passwort dieses privaten Schlüssels |

Für In-place-Updates denselben Keystore verwenden wie für bereits installierte
eigene Releases. Ein anderer Schlüssel erlaubt kein direktes Update derselben
App-Installation. Den Keystore separat sichern, niemals ins Repository aufnehmen.
Die bestehende `.gitignore` schließt `*.jks`, `*.keystore` und `key.properties` aus.
Base64 ist nur Kodierung und ebenfalls geheim zu halten. Den Wert lokal erzeugen,
beispielsweise unter Linux mit `base64 -w0 /privater/pfad/release.jks`, und direkt
als Secret hinterlegen; nicht in Skripte, Dokumente oder Logs kopieren.

Fehlende Secrets führen zum Abbruch. Der Releasejob prüft Keystore-Passwort und
Alias mit `keytool`, baut Universal-APK und drei ABI-APKs und verifiziert jede APK
mit `apksigner`. Ein fehlgeschlagener oder unsignierter Build wird nicht
veröffentlicht. Die temporäre Keystore-Datei liegt im Runner-Temp-Verzeichnis
und wird über `if: always()` auch bei Fehlern entfernt. Nur signierte APKs und
Prüfsummen werden als Artefakte weitergereicht.

Für GHCR und GitHub Releases wird der automatisch von GitHub bereitgestellte
`GITHUB_TOKEN` verwendet. Dafür ist **kein eigenes PAT-Secret** nötig. Standard
ist `contents: read`; nur der Image-Publisher erhält `packages: write`, nur der
Release-Publisher `contents: write`. Die wiederverwendbare CI bekommt keine
Signierungs-Secrets vererbt. Bei einem bereits existierenden GHCR-Paket muss
unter dessen Actions-Zugriffsrechten `KingMezzo/shopbandit` schreiben dürfen.
Organisations-/Repository-Richtlinien dürfen diese Berechtigungen nicht sperren.

`GITLAB_MIRROR_TOKEN` wird nirgends mehr verwendet und kann in den GitHub-Settings
entfernt werden, falls es im Fork überhaupt eingerichtet wurde. Die lokale
Anpassung verändert keine GitHub-Secrets oder Repository-Einstellungen.

## Versionen, Test-Releases und Artefakte

Aktueller Stand: `app/pubspec.yaml` enthält `1.1.0+6`. Erlaubte Beispiele:

- `v1.1.0-rc.1` → GitHub-Prerelease, Image
  `ghcr.io/kingmezzo/shopbandit-server:1.1.0-rc.1`.
- `v1.1.0` → stabiles Release, Image
  `ghcr.io/kingmezzo/shopbandit-server:1.1.0`.

Die Basisversion muss zu `pubspec.yaml` passen; ein exakt passender
Prerelease-Eintrag in pubspec ist ebenfalls zulässig. Die APK erhält den
vollständigen Release-Versionsnamen, etwa `1.1.0-rc.1`. Für jede weitere verteilte
App-Version den Build-/Versionscode erhöhen und die Changelogs unter
`fastlane/metadata/android/{de-DE,en-US}/changelogs/` pflegen.

Es werden **keine Docker-Aliase `latest`, `1.1` oder `sha-*`** erzeugt. Ein Test
kann damit keinen produktiv verwendeten Alias verschieben. Auch der GitHub-
Release bekommt nicht automatisch das Label „Latest“ (`make_latest: false`).

Das GitHub Release enthält:

- signierte APKs für `arm64-v8a`, `armeabi-v7a`, `x86_64` sowie eine Universal-APK;
- `SHA256SUMS` zur Prüfung der APKs und des Serververweises;
- `SERVER_IMAGE.txt` mit eigenem GHCR-Versions-Tag und unveränderlichem Digest
  des Multiarch-Manifests. Das Docker-Image selbst liegt in GHCR.

Vor einem späteren freigegebenen Tag-Push die Origin-URL, Secrets, Version und
erfolgreiche CI im eigenen Fork prüfen. Diese Änderung erstellt keinen Commit,
Push, Tag, Merge, Release oder Deployment. Ein späterer Tag-Push löst dagegen
die beschriebene Veröffentlichung aus; das reine Veröffentlichen eines Releases
für einen schon vorhandenen Tag startet keinen Build.

## Produktive Aktualisierung

Keiner der Workflows startet Container auf dem Pi oder greift auf die produktive
Datenbank zu. Die vorhandene Server-Konfiguration wird lokal nicht geändert.
Insbesondere verweist das unveränderte historische Compose-Beispiel weiterhin
auf das ursprüngliche Image: Für einen eigenen späteren Betrieb müsste das Ziel
ausdrücklich auf `ghcr.io/kingmezzo/shopbandit-server:<geprüfte-version>` bzw. den
Digest umgestellt werden. Das ist ein gesonderter, hier nicht ausgeführter Schritt.
Backup, Testkopie und die Reihenfolge Server vor App beschreibt
[CATEGORIES.md](CATEGORIES.md).

## Lokale Konfigurationsprüfung

```sh
docker run --rm -v "$PWD:/repo:ro" -w /repo rhysd/actionlint:1.7.7 -color
python3 -B -m unittest discover -s tools/tests -p 'test_*.py'
python3 tools/generate-categories.py --check
git diff --check
```

Diese Konfigurationsprüfungen wurden lokal ausgeführt. Eine Ausführung auf
GitHub, die Verfügbarkeit der dort konfigurierten Secrets und eine tatsächliche
Release-Signierung/Veröffentlichung wurden nicht angestoßen oder vorgetäuscht.

Referenzen: [Wiederverwendbare GitHub-Workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows),
[Berechtigungen und Secrets](https://docs.github.com/en/actions/reference/security/secure-use),
[Docker Buildx Action](https://github.com/docker/build-push-action),
[Release-Action-Eingaben](https://github.com/softprops/action-gh-release/blob/v2/action.yml).
