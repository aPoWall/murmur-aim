#!/usr/bin/env python3
"""Stamp the companion edition settings into a built app's Info.plist.

The operator values live outside the repository, in packaging/aim-edition.local.json (ignored by
git), or in the file named by MURMUR_AIM_EDITION_CONFIG. The repository carries only
aim-edition.example.json. The app validates every value again at launch.
"""
import json
import os
import plistlib
import re
import sys
from pathlib import Path

PATTERNS = {
    'AIMOwnerSSHHost': r'[A-Za-z0-9][A-Za-z0-9._-]{0,62}',
    'AIMServerRoot': r'[A-Za-z0-9_.][A-Za-z0-9._-]*(/[A-Za-z0-9_.][A-Za-z0-9._-]*)*',
    'AIMServerDatabase': r'[A-Za-z0-9_.][A-Za-z0-9._-]*(/[A-Za-z0-9_.][A-Za-z0-9._-]*)*',
    'AIMServerLabel': r'[A-Za-z0-9 ._·-]{1,48}',
    'AIMBoardURL': r'https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?',
    'AIMOwnerResponsibility': r'[a-z0-9_]{1,40}',
}
LISTS = {'AIMAvatarPeople': r'[a-z0-9_]{1,40}', 'AIMPrivatePeers': r'[a-z0-9][a-z0-9._-]{0,62}'}


def main(plist_path, edition):
    here = Path(__file__).resolve().parent
    source = Path(os.environ.get('MURMUR_AIM_EDITION_CONFIG', here / 'aim-edition.local.json'))
    settings = json.loads(source.read_text())
    with open(plist_path, 'rb') as stream:
        info = plistlib.load(stream)
    info['AIMShellEdition'] = int(edition)
    # The edition lives in the menu bar; a stock build keeps its Dock icon.
    info['LSUIElement'] = True
    for key, pattern in PATTERNS.items():
        value = settings.get(key)
        if value is None:
            continue
        if not isinstance(value, str) or not re.fullmatch(pattern, value) or '..' in value.split('/'):
            raise SystemExit(f'invalid {key} in {source.name}')
        info[key] = value
    for key, pattern in LISTS.items():
        values = settings.get(key, [])
        if not isinstance(values, list) or not all(isinstance(v, str) and re.fullmatch(pattern, v) for v in values):
            raise SystemExit(f'invalid {key} in {source.name}')
        info[key] = values
    if 'AIMOwnerSSHHost' not in info:
        raise SystemExit('AIMOwnerSSHHost is required for an edition build')
    with open(plist_path, 'wb') as stream:
        plistlib.dump(info, stream)
    print(f'Stamped edition {edition} from {source.name}')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: stamp-aim-edition.py INFO_PLIST EDITION')
    main(sys.argv[1], sys.argv[2])
