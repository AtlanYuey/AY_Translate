"""Verify Apple's AEA signature and compare the bundled workflow with its source.

macOS supplies aea/aa. No iCloud login, network request or workflow execution is
needed. See docs/全屏扩展与快捷指令调查.md for the public format references.
"""
import base64
import hashlib
import json
import plistlib
import ssl
import struct
import subprocess
import tempfile
from pathlib import Path

# SHA-256 of https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
APPLE_ROOT_G3 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"
project = Path(__file__).resolve().parents[2]
signed = project / "ScreenTranslate/Resources/TranslateScreen.shortcut"
source = plistlib.loads((project / "Shortcuts/TranslateScreen.unsigned.plist").read_bytes())
blob = signed.read_bytes()
if len(blob) < 12 or blob[:4] != b"AEA1":
    raise SystemExit("Missing signed Shortcut archive")
profile, size = struct.unpack_from("<II", blob, 4)
if profile != 0 or not 0 < size < len(blob) - 12:
    raise SystemExit("Unexpected Shortcut archive profile or auth length")
certificates = plistlib.loads(blob[12:12 + size])["SigningCertificateChain"]
if len(certificates) < 2 or hashlib.sha256(certificates[-1]).hexdigest() != APPLE_ROOT_G3:
    raise SystemExit("Shortcut certificate chain is not anchored to Apple Root CA G3")


def run(arguments, data=None):
    return subprocess.run(arguments, input=data, check=True, capture_output=True, timeout=60).stdout


with tempfile.TemporaryDirectory(prefix="shortcut-verification-") as folder:
    folder = Path(folder)
    leaf = folder / "leaf.der"
    leaf.write_bytes(certificates[0])
    pem_files = []
    for index, certificate in enumerate(certificates):
        path = folder / f"certificate-{index}.pem"
        path.write_text(ssl.DER_cert_to_PEM_cert(certificate))
        pem_files.append(path)
    intermediate = folder / "intermediates.pem"
    intermediate.write_text("".join(path.read_text() for path in pem_files[1:-1]))
    run(["openssl", "verify", "-purpose", "any", "-CAfile", str(pem_files[-1]),
         "-untrusted", str(intermediate), str(pem_files[0])])
    public_pem = run(["openssl", "x509", "-inform", "DER", "-in", str(leaf), "-pubkey", "-noout"])
    public_der = run(["openssl", "pkey", "-pubin", "-pubout", "-outform", "DER"], public_pem)
    point = public_der[-65:]
    if len(point) != 65 or point[0] != 4:
        raise SystemExit("Expected an uncompressed P-256 signing key")
    key = "base64:" + base64.b64encode(point).decode("ascii")
    archive = folder / "payload.aar"
    run(["aea", "decrypt", "-i", str(signed), "-o", str(archive), "-sign-pub-value", key])
    extracted = folder / "extracted"
    extracted.mkdir()
    run(["aa", "extract", "-i", str(archive), "-d", str(extracted)])
    workflows = list(extracted.glob("*.wflow"))
    if len(workflows) != 1:
        raise SystemExit("Expected one workflow in the signed archive")
    workflow = plistlib.loads(workflows[0].read_bytes())
    for field in ["WFWorkflowActions", "WFWorkflowImportQuestions", "WFWorkflowTypes"]:
        if workflow.get(field) != source.get(field):
            raise SystemExit(f"Signed Shortcut differs from its reviewed source: {field}")
    actions = workflow["WFWorkflowActions"]
    expected_ids = ["is.workflow.actions.takescreenshot", "is.workflow.actions.runextension"]
    if [action["WFWorkflowActionIdentifier"] for action in actions] != expected_ids:
        raise SystemExit("Expected exactly the screenshot and share-extension actions")
    app_id = plistlib.loads((project / "ScreenTranslate/Info.plist").read_bytes())["ContainingAppBundleIdentifier"]
    if actions[1]["WFWorkflowActionParameters"]["WFAppIdentifier"] != app_id:
        raise SystemExit("Shortcut targets a different containing app")

print(json.dumps({"sha256": hashlib.sha256(blob).hexdigest(), "appleCertificateChain": "verified",
                  "archiveSignature": "verified", "matchesReviewedActions": True,
                  "actions": expected_ids, "appIdentifier": app_id}, indent=2))
