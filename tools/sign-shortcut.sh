#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
shortcut_output="$project_root/ScreenTranslate/Resources/TranslateScreen.shortcut"
mkdir -p "$(dirname "$shortcut_output")"
shortcut_stage="$(mktemp -d "${TMPDIR:-/tmp}/translate-screen-shortcut.XXXXXX")"
trap 'rm -rf "$shortcut_stage"' EXIT
shortcuts sign --mode anyone --input "$project_root/Shortcuts/TranslateScreen.unsigned.plist" --output "$shortcut_stage/TranslateScreen.shortcut"
python3 - "$shortcut_stage/TranslateScreen.shortcut" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1])
if not path.exists() or path.read_bytes()[:4] != b'AEA1':
    raise SystemExit('No valid signed Shortcut was generated. Open Shortcuts on this Mac, sign in to iCloud, and run this script again.')
PY
mv "$shortcut_stage/TranslateScreen.shortcut" "$shortcut_output"
printf 'Signed Shortcut ready: %s\n' "$shortcut_output"
