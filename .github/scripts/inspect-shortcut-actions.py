"""Read platform action metadata for diagnostic research; never invoke private APIs."""
import json,plistlib,subprocess
from pathlib import Path
metadata=json.loads(subprocess.check_output(['xcrun','simctl','list','runtimes','--json']))
found=[]
def visit(value):
    if isinstance(value,dict):
        for key,child in value.items():
            if 'runextension' in key.lower() or 'sharewithapp' in key.lower(): found.append({key:child})
            else: visit(child)
    elif isinstance(value,list):
        for child in value:visit(child)
for runtime in metadata['runtimes']:
    if not runtime.get('isAvailable'):continue
    base=Path(runtime.get('bundlePath','/nonexistent'))/'Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks/WorkflowKit.framework'
    if not base.exists():continue
    for path in base.rglob('*.plist'):
        try:visit(plistlib.loads(path.read_bytes()))
        except Exception:continue
print(json.dumps(found,ensure_ascii=False,indent=2,default=str))
