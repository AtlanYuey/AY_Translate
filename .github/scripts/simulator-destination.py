#!/usr/bin/env python3
"""Pick an available iPhone runtime satisfying the app's deployment target."""
import json
import re
import sys

devices = json.load(sys.stdin)["devices"]
candidates = []
for runtime, entries in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match or tuple(map(int, match.groups())) < (26, 5):
        continue
    for device in entries:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            candidates.append((tuple(map(int, match.groups())), device["name"], device["udid"]))
if not candidates:
    sys.exit("No available iPhone simulator with iOS >= 26.5. This is a runner/SDK prerequisite failure, not a source compilation result.")
print("platform=iOS Simulator,id=" + sorted(candidates, reverse=True)[0][2])
