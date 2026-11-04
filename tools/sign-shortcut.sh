#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
shortcut_output="$project_root/ScreenTranslate/Resources/TranslateScreen.shortcut"
mkdir -p "$(dirname "$shortcut_output")"
shortcuts sign --mode anyone --input "$project_root/Shortcuts/TranslateScreen.unsigned.plist" --output "$shortcut_output"
python3 - "$shortcut_output" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1])
if not path.exists() or path.read_bytes()[:4] != b'AEA1':
    raise SystemExit('No valid signed Shortcut was generated. Open Shortcuts on this Mac, sign in to iCloud, and run this script again.')
print('Signed Shortcut ready:',path)
PY
