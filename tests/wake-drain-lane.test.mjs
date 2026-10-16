import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { DatabaseSync } from 'node:sqlite';
import { readWakeReaders } from '../packages/setup/dist/src/wake-readers.js';

test('two chats in one project wake only once and a later chat cannot replay the same row', { timeout: 30000 }, async t => {
  const home = await mkdtemp(path.join(os.tmpdir(), 'murmur-lane-'));
  const dbPath = path.join(home, 'murmur.db');
  const db = new DatabaseSync(dbPath);
  db.exec('CREATE TABLE local_messages (msg_id TEXT PRIMARY KEY, created_at TEXT, sender TEXT, conversation_id TEXT, direction TEXT, text TEXT)');
  const children = [];
  t.after(async () => { for (const p of children) if (p.exitCode === null && p.signalCode === null) p.kill(); db.close(); await rm(home, { recursive: true, force: true }); });
  function reader(session, once = false) {
    const p = spawn(process.execPath, ['--no-warnings', 'scripts/wake-drain-claude.mjs', '--db', dbPath,
      '--session-key', 'desk1234', '--max-seconds', '20', ...(once ? ['--once'] : [])],
    { env: { ...process.env, HOME: home, USERPROFILE: home, CLAUDE_CODE_SESSION_ID: session, MURMUR_WAKE_POLL_MS: '50' }, stdio: ['ignore', 'pipe', 'pipe'] });
    children.push(p); let output = '';
    p.stdout.on('data', b => output += b); p.stderr.on('data', b => output += b);
    return { p, done: new Promise((resolve, reject) => { p.on('error', reject); p.on('close', code => resolve({ code, output })); }) };
  }
  const first = reader('chat-one');
  const deadline = Date.now() + 10000;
  while (!(await readdir(home)).some(name => name.startsWith('.murmur-wake-lock-'))) {
    assert.ok(Date.now() < deadline, 'first reader never took its lock'); await delay(25);
  }
  const second = await reader('chat-two').done;
  assert.equal(second.code, 0, second.output); assert.equal(second.output, '');
  if (['linux', 'darwin'].includes(process.platform)) {
    assert.equal((await readWakeReaders({ storePath: dbPath }, home)).active, 1, 'one live drain, not a count of lock files');
  }
  db.prepare("INSERT INTO local_messages VALUES ('one', ?, 'synthetic-peer', 'thread', 'inbound', 'one delivery')").run(new Date().toISOString());
  const woke = await first.done;
  assert.equal(woke.code, 2, woke.output); assert.match(woke.output, /synthetic-peer/);
  const later = await reader('chat-three', true).done;
  assert.equal(later.code, 0, later.output); assert.equal(later.output, '');
  if (['linux', 'darwin'].includes(process.platform)) assert.equal((await readWakeReaders({ storePath: dbPath }, home)).active, 0);
  assert.equal((await readdir(home)).filter(name => name.startsWith('.murmur-wake-cursor-')).length, 1);
});
