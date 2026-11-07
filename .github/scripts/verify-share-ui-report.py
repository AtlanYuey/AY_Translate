"""Require evidence that the Share UI test reached every functional assertion.

An expected layout failure can otherwise end a test early while XCTest reports
it as passing. The completion attachment is emitted only after both real return
paths succeed, before that final known layout assertion.
"""
import json
import sys
from pathlib import Path

folder = Path(sys.argv[1])
manifest = json.loads((folder / "manifest.json").read_text())
expected = {"recognized": True, "originalToggled": True,
            "closeReturnedToSource": True, "swipeReturnedToSource": True,
            "completedInvocations": 6}
proofs = []
for test in manifest:
    if "testRealShareExtensionRecognizesTogglesAndReturnsToInvokingApp" not in test["testIdentifier"]:
        continue
    for attachment in test["attachments"]:
        if attachment["suggestedHumanReadableName"].startswith("ShareInteractionCompleted"):
            proof = json.loads((folder / attachment["exportedFileName"]).read_text())
            if proof != expected:
                raise SystemExit("Share UI completion proof is incomplete")
            proofs.append(proof)
if not proofs:
    raise SystemExit("Share UI test did not finish its interaction checks; a passing XCTest status is insufficient")
print(json.dumps({"completedShareInteractions": proofs, "evidence": "exported XCTest attachment"}, indent=2))
