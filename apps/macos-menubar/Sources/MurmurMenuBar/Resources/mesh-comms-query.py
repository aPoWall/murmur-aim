#!/usr/bin/env python3
"""Bundled owner SSH reader. Executed in memory; installs nothing on the server.

Only imports the existing operator dashboard readers. No inbox read marks, wakes,
sends, private message bodies or credentials. JSON request travels on stdin.
"""
import contextlib
import importlib.util
import io
import json
import sys
from pathlib import Path

ROOT = Path.home() / 'mesh-comms'
OWNER_THREADS = {'agent-jarvis': {
    'title': 'OPS · Murmur · Васильев–JARVIS',
    'url': 'codex://threads/01a0ed94-6541-7423-a18f-42545746f731',
}}
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
    data.update(private_contours=contours, owner_threads=OWNER_THREADS,
                questions=questions[:100], pending_count=len(questions),
                decision_count=sum(q['responsibility'] == 'alex' for q in questions),
                question_scope='Recorded open questions; delivery is not a semantic answer.')
    return data


def dispatch(request, root=ROOT):
    if not isinstance(request, dict):
        raise ValueError('invalid_request')
    action = request.get('action')
    if action == 'snapshot':
        companion = load('murmur_companion_reader', 'companion.py', root)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            companion.main()
        return augment(json.loads(output.getvalue()), json.loads((root/'monitor.json').read_text()), json.loads((root/'share-data.json').read_text()))
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
