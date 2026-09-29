import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { claudeWakeHookState, configureClient } from '../packages/setup/dist/src/clients.js';
import { resolveContext } from '../packages/setup/dist/src/paths.js';
import { main } from '../packages/setup/dist/src/cli.js';

// doctor called every Claude Code setup wake.no-responder: the daemon has no responder of its
// own there, and the Stop hook that wakes the session was never read (#293).
const repoRoot = fileURLToPath(new URL('../', import.meta.url));

async function fixture(t, { agentId = 'wake-hook' } = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'murmur-doctor-wake- пробел кириллица-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const home = path.join(root, 'home'), configPath = path.join(home, '.claude.json');
  const settingsPath = path.join(home, '.claude', 'settings.json');
  await fs.mkdir(home);
  const context = resolveContext({ dataDir: path.join(root, 'profile'), repoRoot });
  const adapter = { manager: 'none', detectClients: async () => [{ id: 'claude-code', installed: true, configPath, format: 'json' }] };
  await main(['init', '--agent-id', agentId, '--broker-url', 'nats://127.0.0.1:4222', '--data-dir', context.dataDir], adapter);
  return { root, home, configPath, settingsPath, context, adapter };
}

test('a profile with no Claude Code settings still reports no responder', async t => {
  const f = await fixture(t);
  assert.equal(await claudeWakeHookState(f.context, f.adapter), 'absent');
  // An undetected or uninstalled client is not a reason to claim anything either.
  assert.equal(await claudeWakeHookState(f.context, { detectClients: async () => [] }), 'absent');
  assert.equal(await claudeWakeHookState(f.context, { detectClients: async () => [{ id: 'claude-code', installed: false, configPath: f.configPath, format: 'json' }] }), 'absent');
  // A detector that throws must not take the whole wake stage down with it.
  assert.equal(await claudeWakeHookState(f.context, { detectClients: async () => { throw new Error('boom'); } }), 'absent');
});

test('the hook this version installs reads as current, and a 2.11.0 entry as outdated', async t => {
  const f = await fixture(t);
  await configureClient(f.context, f.adapter, 'claude-code');
  assert.equal(await claudeWakeHookState(f.context, f.adapter), 'current');

  // 2.11.0 wrote the same command without a timeout, so its real window was 600 s (#273).
  const settings = JSON.parse(await fs.readFile(f.settingsPath, 'utf8'));
  for (const group of settings.hooks.Stop) for (const hook of group.hooks) if (hook.command.includes('wake-drain-claude')) delete hook.timeout;
  await fs.writeFile(f.settingsPath, JSON.stringify(settings));
  assert.equal(await claudeWakeHookState(f.context, f.adapter), 'outdated');
});

test('a hook belonging to another profile is not read as this profile is wake', async t => {
  const f = await fixture(t);
  await configureClient(f.context, f.adapter, 'claude-code');
  const other = resolveContext({ dataDir: path.join(f.root, 'other-profile'), repoRoot });
  // The settings file is shared by every profile on the machine; this one names a different store.
  assert.equal(await claudeWakeHookState(other, f.adapter), 'absent');
  assert.equal(await claudeWakeHookState(f.context, f.adapter), 'current');
});

test('settings that are missing, unreadable or shaped differently never throw', async t => {
  const f = await fixture(t);
  await fs.mkdir(path.dirname(f.settingsPath), { recursive: true });
  for (const text of ['', '   ', 'not json', '[]', '{"hooks":[]}', '{"hooks":{"Stop":{}}}', '{"hooks":{"Stop":[{"hooks":"no"}]}}', '{"hooks":{"Stop":[{"hooks":[{"command":"other-tool"}]}]}}']) {
    await fs.writeFile(f.settingsPath, text);
    assert.equal(await claudeWakeHookState(f.context, f.adapter), 'absent', text || '(empty)');
  }
});
