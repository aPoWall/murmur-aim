#!/usr/bin/env python3
"""Bundled owner SSH reader. Executed in memory; installs nothing on the server.

Only imports the existing operator dashboard readers. No inbox read marks, wakes,
sends, private message bodies or credentials. JSON request travels on stdin.
"""
import base64
import os
import stat
import contextlib
import importlib.util
import io
import json
import sys
import sqlite3
from pathlib import Path

ROOT = Path.home() / 'mesh-comms'
OWNER_THREADS = {'agent-jarvis': {
    'title': 'OPS · Murmur · Васильев–JARVIS',
    'url': 'codex://threads/01a0ed94-6541-7423-a18f-42545746f731',
}}
AVATAR_IDS = {'alex', 'ira', 'dan', 'vlada', 'katya', 'anca', 'mykhailo', 'olya', 'vasiliev', 'sergey', 'khabarov', 'kirill_oleinichenko'}
AVATARS = {'person:' + pid: '/mesh-comms-avatar-' + pid + '.jpg' for pid in AVATAR_IDS}
MAX_AVATAR_BYTES = 262144
CLOSED = {'answered', 'no_reply_needed', 'reported_complete', 'cancelled'}


def load(name, filename, root=ROOT):
    spec = importlib.util.spec_from_file_location(name, root / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def responsibility(status):
    if status in {'awaiting_user', 'needs_owner_decision'}:
        return 'alex'
    if status in {'awaiting_implementation_owner', 'awaiting_agent'}:
        return 'agent'
    if status in {'awaiting_peer_human', 'awaiting_external_owner', 'awaiting_peer'}:
        return 'peer'
    return 'verify'


def augment(data, monitor, share):
    if data.get('privacy') != 'owner-metadata' or monitor.get('privacy') != 'operator-only-metadata' or share.get('privacy') != 'metadata-only':
        raise ValueError('safe_snapshot_unavailable')
    private = {'shaper-viola', 'agent-viola-alex', 'alex-viola'}
    contours = []
    for c in share.get('private_contours', []):
        private.update([c.get('local_identity'), c.get('peer_identity')])
        if c.get('privacy') != 'status-only':
            continue
        contours.append({
            'id': c.get('id'), 'name': c.get('peer_label') or 'Private connection',
            'privacy': 'status-only',
            **{k: c.get(k) for k in ['service_active', 'last_at', 'updated_at', 'inbound_count', 'outbound_count', 'failed_count', 'waiting_count']},
        })
    topics = list(monitor.get('topics', []))
    covered = {t.get('source_id') for t in topics if t.get('source_id')}
    topics += [q for q in monitor.get('questions', []) if not q.get('source_id') or q.get('source_id') not in covered]
    questions = []
    for t in topics:
        if t.get('peer') in private or t.get('status') in CLOSED:
            continue
        row = {k: t.get(k) for k in ['id', 'title', 'peer', 'status', 'source_date', 'reviewed_at', 'next_action', 'conversation', 'source_id']}
        row['responsibility'] = responsibility(t.get('status'))
        questions.append(row)
    questions.sort(key=lambda q: q.get('source_date') or '', reverse=True)
    for person in data.get('people', []):
        labels = person.setdefault('agent_labels', {})
        for peer in person.get('agents', []):
            if not isinstance(labels.get(peer), str) or labels[peer].strip() in {'', '-', '—', '–'}:
                labels[peer] = {'agent-kirill':'Кирилл','agent-danik':'zima blue','agent-jarvis':'JARVIS'}.get(peer, peer)
    data.update(private_contours=contours, owner_threads=OWNER_THREADS,
                questions=questions[:100], pending_count=len(questions),
                decision_count=sum(q['responsibility'] == 'alex' for q in questions),
                question_scope='Recorded open questions; delivery is not a semantic answer.')
    return data



def add_avatars(data, people, share):
    """Only current ordinary people with existing operator-approved exact assets."""
    private = {'shaper-viola', 'agent-viola-alex', 'alex-viola'}
    for contour in share.get('private_contours', []):
        private.update((contour.get('local_identity'), contour.get('peer_identity')))
    private_people = {b.get('person') for b in people.get('bindings', []) if b.get('agent') in private}
    source = {p.get('id'): p for p in people.get('people', [])}
    for person in data.get('people', []):
        for key in ('photo', 'photo_note', 'photo_privacy'):
            person.pop(key, None)
        p = source.get(person.get('id'), {})
        photo = AVATARS.get(person.get('id'))
        if (people.get('privacy') != 'operator_metadata_only_tailnet' or
            share.get('privacy') != 'metadata-only' or data.get('privacy') != 'owner-metadata' or
            not photo or p.get('photo') != photo or p.get('history') or
            p.get('privacy') in {'private', 'status-only'} or person.get('id') in private_people or
            not person.get('agents') or any(peer in private for peer in person['agents'])):
            continue
        person.update(photo=photo, photo_privacy='owner-approved-avatar',
                      photo_note=p.get('photo_note') if isinstance(p.get('photo_note'), str) else None)
    return data


def read_avatar(person, root=ROOT):
    # The request supplies an exact roster identity, never a URL or a file path.
    if person not in AVATARS:
        raise ValueError('avatar_unavailable')
    data = dispatch({'action': 'snapshot'}, root)
    row = next((p for p in data.get('people', []) if p.get('id') == person and
                p.get('photo_privacy') == 'owner-approved-avatar'), {})
    photo = row.get('photo')
    if photo != AVATARS[person]:
        raise ValueError('avatar_unavailable')
    reader = load('murmur_avatar_allowlist', 'serve.py', root)
    allowed = reader.ALLOWED.get(photo)
    if allowed != (photo[1:], 'image/jpeg'):
        raise ValueError('avatar_unavailable')
    # Exact allowlisted basename; no symlinks, directories or oversized reads.
    fd = os.open(root / allowed[0], os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_AVATAR_BYTES:
            raise ValueError('avatar_unavailable')
        image = stream.read(MAX_AVATAR_BYTES + 1)
    if len(image) > MAX_AVATAR_BYTES or not image.startswith(b'\xff\xd8\xff'):
        raise ValueError('avatar_unavailable')
    return {'privacy': 'owner-approved-avatar', 'person': person, 'photo': photo,
            'mime': allowed[1], 'data': base64.b64encode(image).decode('ascii')}


def dispatch(request, root=ROOT):
    if not isinstance(request, dict):
        raise ValueError('invalid_request')
    action = request.get('action')
    if action == 'snapshot':
        companion = load('murmur_companion_reader', 'companion.py', root)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            companion.main()
        share = json.loads((root/'share-data.json').read_text())
        data = augment(json.loads(output.getvalue()), json.loads((root/'monitor.json').read_text()), share)
        data = add_avatars(data, json.loads((root/'people-data.json').read_text()), share)
        # Expose fixed diagnostic codes only. Raw runner errors and session paths
        # stay on the server. A failed wake is separate from transport delivery.
        db_path = Path.home()/'.local/var/murmur-sasha/murmur.db'
        try:
            with sqlite3.connect('file:'+str(db_path)+'?mode=ro',uri=True) as db:
                for peer, item in data.get('peer_policy', {}).get('peers', {}).items():
                    row = db.execute("select wake_error from local_messages where direction='inbound' and sender=? order by created_at desc limit 1",(peer,)).fetchone()
                    error = str(row[0]) if row else ''
                    if error.startswith('codex-app-server-final-empty:'):
                        item['wake_reason'] = 'empty_final_reply'
                    elif error == 'audit-require-approval':
                        item['wake_reason'] = 'owner_approval_required'
        except sqlite3.Error:
            pass  # Preserve the existing source's unknown/recorded_error state.
        return data
    if action == 'avatar':
        if set(request) != {'action', 'person'} or not isinstance(request.get('person'), str):
            raise ValueError('invalid_avatar_request')
        return read_avatar(request['person'], root)
    if action not in {'search', 'read'}:
        raise ValueError('unsupported_action')
    reader = load('murmur_message_reader', 'serve.py', root)
    if action == 'search':
        query = request.get('query')
        if not isinstance(query, str) or not 2 <= len(query.strip()) <= 160:
            raise ValueError('query_length')
        code, result = reader.search_messages(query, root=root)
    else:
        store, mid = request.get('store'), request.get('id')
        if not isinstance(store, str) or not isinstance(mid, str):
            raise ValueError('invalid_message')
        code, result = reader.read_message(store, mid, root=root)
    if code != 200:
        raise ValueError(result.get('error', 'source_unavailable'))
    return result


def main():
    # Fixed owner location, never a path or command supplied by a request.
    sys.path.insert(0, str(ROOT))
    try:
        raw = sys.stdin.buffer.read(8193)
        if len(raw) > 8192:
            raise ValueError('request_too_large')
        result = dispatch(json.loads(raw))
        print(json.dumps(result, ensure_ascii=False))
    except Exception:
        # Tracebacks could reveal configuration/paths; return a bounded error.
        print(json.dumps({'error': 'owner_read_unavailable'}))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
