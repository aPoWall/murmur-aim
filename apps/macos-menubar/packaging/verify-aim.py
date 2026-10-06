#!/usr/bin/env python3
"""Fail the build on drift in vendored AIM components or missing font assets."""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parent.parent
receipt=json.loads((root/'aim-shared-receipt.json').read_text())
for entry in receipt['files']:
    name,digest=entry['path'],entry['sha256']
    assert hashlib.sha256((root/'Sources/MurmurMenuBar/AIMShared'/name).read_bytes()).hexdigest()==digest,name
for name in ['plex-mono-400.ttf','plex-mono-500.ttf','plex-mono-600.ttf','IBM-Plex-LICENSE.txt']:
    assert (root/'Sources/MurmurMenuBar/Resources'/name).stat().st_size>100,name
print('AIM N1 shared components and fonts verified')
