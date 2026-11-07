"""Export only AY Translate's bounded, content-free processing journal."""
import json
import re
import plistlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
fields = {"id", "started", "updated", "context", "target", "stage", "outcome", "event", "memoryWarnings", "footprintBytes", "peakFootprintBytes", "availableBytes", "version", "build", "processSession", "ocrFallback"}
records = {}
for path in root.rglob("*.plist"):
    if not path.name.startswith(("com.bahaanajjar.ScreenTranslate", "group.com.bahaanajjar.ScreenTranslate")) or path.stat().st_size > 1_000_000:
        continue
    try:
        preferences = plistlib.loads(path.read_bytes())
        for key in ["processing.diagnostics.app", "processing.diagnostics.share"]:
            data = preferences.get(key)
            if not isinstance(data, bytes) or len(data) > 32_000:
                continue
            for record in json.loads(data)[-8:]:
                clean = {key: value for key, value in record.items() if key in fields}
                checkpoints = record.get("checkpoints", [])
                if isinstance(checkpoints, list):
                    clean["checkpoints"] = [
                        {"point": sample["point"], **{key: sample[key] for key in ["footprintBytes", "availableBytes"]
                          if isinstance(sample.get(key), int) and sample[key] >= 0}}
                        for sample in checkpoints[:20] if isinstance(sample, dict)
                        and isinstance(sample.get("point"), str) and re.fullmatch(r"[a-z0-9_]{1,64}", sample["point"])
                    ]
                identifier = clean.get("id")
                if isinstance(identifier, str) and (identifier not in records or clean.get("updated", 0) > records[identifier].get("updated", 0)):
                    records[identifier] = clean
    except (OSError, ValueError, TypeError, AttributeError, plistlib.InvalidFileException):
        continue
print(json.dumps(sorted(records.values(), key=lambda record: record.get("started", 0), reverse=True), indent=2))
