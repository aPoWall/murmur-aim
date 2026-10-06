#!/usr/bin/env python3
"""Vendor only receipt-verified shared files already adopted by Murmur."""
import hashlib, json, shutil, sys
from pathlib import Path
root = Path(__file__).resolve().parent.parent
source = Path(sys.argv[1]).resolve()
receipt_path = root / 'aim-shared-receipt.json'
local = json.loads(receipt_path.read_text())
export = json.loads((source / 'aim-mini-apps.receipt.json').read_text())
# Validate the whole scoped batch before writing any file.
for entry in local['files']:
    name = entry['path']
    expected = export['artifacts'][name]
    assert hashlib.sha256((source / name).read_bytes()).hexdigest() == expected, name
for entry in local['files']:
    name = entry['path']
    shutil.copyfile(source / name, root / 'Sources/MurmurMenuBar/AIMShared' / name)
    entry['sha256'] = export['artifacts'][name]
local['export_version'] = export['version']
receipt_path.write_text(json.dumps(local, indent=2) + '\n')
print('Synced', len(local['files']), 'receipt-verified shared files')
