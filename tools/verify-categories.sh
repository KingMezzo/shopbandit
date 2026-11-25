#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../app"
# read_text normalizes a Windows checkout's CRLF for the existing fetch script.
python3 - <<'PY'
import pathlib, subprocess
subprocess.run(['bash', '-c', pathlib.Path('../tools/fetch-sqlite.sh').read_text()], check=True)
PY
flutter pub get
dart run build_runner build
flutter gen-l10n
python3 ../tools/generate-categories.py --check
flutter analyze --fatal-infos
flutter test
flutter build apk --debug
