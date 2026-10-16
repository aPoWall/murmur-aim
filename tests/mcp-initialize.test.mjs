import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { createInterface } from 'node:readline';
import { once } from 'node:events';
import { DatabaseSync } from 'node:sqlite';

test('initialize explains the connected workflow without exposing or changing the profile', { timeout: 45000 }, async t => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'murmur-initialize-'));
  let proc;
  t.after(async () => {
    if (proc && proc.exitCode === null && proc.signalCode === null) {
      const closed = once(proc, 'close'); proc.kill(); await closed;
    }
    await rm(dir, { recursive: true, force: true });
  });
  const env = { ...process.env, HOME: dir, DATA_DIR: dir,
    MURMUR_STORE_PATH: path.join(dir, 'murmur.db'), MURMUR_CHANNEL_ROSTER_PATH: path.join(dir, 'channel-roster.db'),
    MURMUR_UPDATE_CHECK: '0', NATS_URL: 'nats://127.0.0.1:1', NATS_TOKEN: 'synthetic-do-not-expose' };
  execFileSync(process.execPath, ['packages/setup/bin/murmur.mjs', 'init', '--agent-id', 'private-test-identity',
    '--broker-url', 'nats://127.0.0.1:1', '--data-dir', dir, '--json'], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  const configPath = path.join(dir, 'agent-config.json');
  const before = await readFile(configPath, 'utf8');
  proc = spawn(process.execPath, ['packages/mcp-server/dist/src/index.js'], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  proc.stderr.resume();
  const pending = new Map(); let counter = 0;
  createInterface({ input: proc.stdout }).on('line', line => {
    const value = JSON.parse(line); pending.get(value.id)?.(value);
  });
  async function rpc(method, params = {}) {
    const id = ++counter; let timer;
    try {
      const response = await new Promise((resolve, reject) => {
        pending.set(id, resolve);
        // A cold child takes ~1 s alone but exceeded 5 s in the full parallel suite.
        timer = setTimeout(() => reject(new Error(`MCP timed out: ${method}`)), 15000);
        proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
      });
      assert.equal(response.error, undefined, response.error?.message);
      return response.result;
    } finally { clearTimeout(timer); pending.delete(id); }
  }
  const initialized = await rpc('initialize', {
    protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'desktop-test', version: '1.0' },
  });
  assert.equal(initialized.protocolVersion, '2024-11-05');
  const packageInfo = JSON.parse(await readFile(new URL('../packages/mcp-server/package.json', import.meta.url), 'utf8'));
  assert.equal(initialized.serverInfo.version, packageInfo.version, 'MCP must advertise the packaged version');
  assert.deepEqual(initialized.capabilities, { tools: {} });
  const guide = initialized.instructions;
  assert.equal(typeof guide, 'string');
  assert.match(guide, /Claude Desktop Chat/);
  assert.match(guide, /Code tab/);
  assert.match(guide, /awaiting_reply/);
  assert.match(guide, /conversationId/);
  for (const privateValue of [dir, 'private-test-identity', env.NATS_TOKEN,
    JSON.parse(before).keys.signing.privateKey, JSON.parse(before).keys.encryption.privateKey]) {
    assert.ok(!JSON.stringify(initialized).includes(privateValue), 'initialize must not disclose profile data');
  }
  proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const { tools } = await rpc('tools/list');
  for (const name of new Set(guide.match(/\b(?:murmur_[a-z_]+|send_message)\b/g))) {
    assert.ok(tools.some(tool => tool.name === name), `instructions refer to missing tool ${name}`);
  }
  const peers = JSON.parse((await rpc('tools/call', { name: 'murmur_peers', arguments: {} })).content[0].text);
  assert.deepEqual(peers.peers, []);
  assert.equal(await readFile(configPath, 'utf8'), before, 'onboarding guidance must not rewrite identity');
  const db = new DatabaseSync(env.MURMUR_STORE_PATH, { readOnly: true });
  try { assert.equal(db.prepare('SELECT count(*) AS count FROM outbox').get().count, 0); }
  finally { db.close(); }
});
