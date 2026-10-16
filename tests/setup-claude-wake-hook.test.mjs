import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { configureClient, previewClientConfiguration } from '../packages/setup/dist/src/clients.js';
import { resolveContext } from '../packages/setup/dist/src/paths.js';
import { main } from '../packages/setup/dist/src/cli.js';

const repoRoot = fileURLToPath(new URL('../', import.meta.url));
const slash = value => value.replaceAll('\\', '/');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'murmur-claude-hook- пробел кириллица-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const home = path.join(root, 'home'), configPath = path.join(home, '.claude.json');
  const settingsPath = path.join(home, '.claude', 'settings.json');
  await fs.mkdir(home);
  const context = resolveContext({ dataDir: path.join(root, 'profile'), repoRoot });
  const adapter = { detectClients: async () => [{ id: 'claude-code', installed: true, configPath, format: 'json' }] };
  const settings = async () => JSON.parse(await fs.readFile(settingsPath, 'utf8'));
  const ourHooks = async () => (await settings()).hooks.Stop.flatMap(group => group.hooks).filter(hook => hook.command.includes('wake-drain-claude'));
  return { root, home, configPath, settingsPath, context, adapter, settings, ourHooks };
}

test('claude-code gets the MCP entry and the Stop wake hook for this profile', async t => {
  const f = await fixture(t);
  const result = await configureClient(f.context, f.adapter, 'claude-code');
  assert.equal(result.changed, true);
  assert.equal(result.wakeHook.action, 'add'); assert.equal(result.wakeHook.backup, null);
  assert.ok(JSON.parse(await fs.readFile(f.configPath, 'utf8')).mcpServers.murmur);
  const [hook] = await f.ourHooks();
  assert.equal(hook.type, 'command'); assert.equal(hook.asyncRewake, true);
  assert.equal(hook.timeout, 28800, 'the entry must carry its own timeout: Claude Code ends asyncRewake hooks after 600 s otherwise (#273)');
  assert.equal(hook.command, `"${slash(f.context.nodePath)}" --no-warnings "${slash(path.join(repoRoot, 'scripts', 'wake-drain-claude.mjs'))}" --db "${slash(f.context.storePath)}" --max-seconds 28800`);
  assert.doesNotMatch(hook.command, /\.sh"/);
  // Idempotent: a second run changes nothing and never duplicates the hook.
  const again = await configureClient(f.context, f.adapter, 'claude-code');
  assert.equal(again.changed, false); assert.equal(again.wakeHook.action, 'unchanged');
  assert.equal((await f.ourHooks()).length, 1);
});

test('other settings and hooks are kept, with a private backup of the original', async t => {
  const f = await fixture(t);
  await fs.mkdir(path.dirname(f.settingsPath));
  const original = { model: 'user-choice', hooks: { Stop: [{ matcher: '', hooks: [{ type: 'command', command: 'notify-done' }] }], PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: 'guard' }] }] } };
  const originalText = JSON.stringify(original, null, 2);
  await fs.writeFile(f.settingsPath, originalText);
  const result = await configureClient(f.context, f.adapter, 'claude-code');
  assert.equal(await fs.readFile(result.wakeHook.backup, 'utf8'), originalText);
  const next = await f.settings();
  assert.equal(next.model, 'user-choice');
  assert.deepEqual(next.hooks.PreToolUse, original.hooks.PreToolUse);
  assert.deepEqual(next.hooks.Stop[0], original.hooks.Stop[0]);
  assert.equal((await f.ourHooks()).length, 1);
});

test('a dedicated Claude project gets project MCP/settings and one stable wake key', async t => {
  const f = await fixture(t);
  const project = path.join(f.home, 'Murmur'); await fs.mkdir(project);
  const context = { ...f.context, clientProjectDir: project };
  await main(['init', '--agent-id', 'project-test', '--broker-url', 'nats://127.0.0.1:1', '--data-dir', context.dataDir], { manager: 'none' });
  const plan = await previewClientConfiguration(context, f.adapter, 'claude-code');
  assert.equal(plan.configPath, path.join(project, '.mcp.json'));
  assert.equal(plan.wakeHook.settingsPath, path.join(project, '.claude', 'settings.json'));
  const result = await configureClient(context, f.adapter, 'claude-code', false, plan.planId);
  const settings = JSON.parse(await fs.readFile(result.wakeHook.settingsPath, 'utf8'));
  assert.match(settings.hooks.Stop[0].hooks[0].command, /--session-key [a-f0-9]{8}$/);
  const lane = settings.hooks.Stop[0].hooks[0].command.match(/--session-key ([a-f0-9]{8})$/)[1];
  const mcp = JSON.parse(await fs.readFile(path.join(project, '.mcp.json'), 'utf8'));
  assert.equal(plan.serverName, `murmur-${lane}`);
  assert.equal(mcp.mcpServers[plan.serverName].env.MURMUR_WAKE_SESSION_KEY, lane, 'reply bindings and the shared reader must name the same lane');
  assert.equal((await configureClient(context, f.adapter, 'claude-code')).changed, false);
  await assert.rejects(fs.stat(f.configPath), { code: 'ENOENT' });
  await assert.rejects(fs.stat(f.settingsPath), { code: 'ENOENT' });
  await assert.rejects(configureClient({ ...context, clientProjectDir: path.join(f.home, 'absent') }, f.adapter, 'claude-code'), /client.project-directory-required/);
});

test('project MCP has its own name when Desktop and user scope already have Murmur', async t => {
  const f = await fixture(t);
  const project = path.join(f.home, 'Murmur'); await fs.mkdir(project);
  const context = { ...f.context, clientProjectDir: project };
  await main(['init', '--agent-id', 'project-test', '--broker-url', 'nats://127.0.0.1:1', '--data-dir', context.dataDir], { manager: 'none' });
  const desktop = path.join(f.home, 'claude_desktop_config.json');
  const before = '{"mcpServers":{"murmur":{"command":"keep-working-identity"}}}\n';
  await fs.writeFile(f.configPath, before); await fs.writeFile(desktop, before);
  const adapter = { detectClients: async () => [...await f.adapter.detectClients(), { id: 'claude-desktop', installed: true, configPath: desktop, format: 'json' }] };
  const plan = await previewClientConfiguration(context, adapter, 'claude-code');
  const result = await configureClient(context, adapter, 'claude-code', false, plan.planId);
  assert.equal(result.serverName, plan.serverName);
  const entries = JSON.parse(await fs.readFile(plan.configPath, 'utf8')).mcpServers;
  assert.deepEqual(Object.keys(entries), [plan.serverName]);
  assert.equal(entries[plan.serverName].env.DATA_DIR, context.dataDir);
  assert.equal(await fs.readFile(f.configPath, 'utf8'), before);
  assert.equal(await fs.readFile(desktop, 'utf8'), before);
  for (const occupied of [f.configPath, desktop]) {
    const shadow = JSON.stringify({ mcpServers: { [plan.serverName]: { command: 'foreign' } } });
    await fs.writeFile(occupied, shadow);
    const projectBefore = await fs.readFile(plan.configPath, 'utf8');
    await assert.rejects(previewClientConfiguration(context, adapter, 'claude-code'), /client.inherited-mcp-entry-conflict/);
    await assert.rejects(configureClient(context, adapter, 'claude-code', true), /client.inherited-mcp-entry-conflict/);
    assert.equal(await fs.readFile(plan.configPath, 'utf8'), projectBefore);
    assert.equal(await fs.readFile(occupied, 'utf8'), shadow);
    await fs.writeFile(occupied, before);
  }
});

test('reconnecting an older project migrates only its owned Murmur entry after confirmation', async t => {
  const f = await fixture(t);
  const project = path.join(f.home, 'Murmur'); await fs.mkdir(project);
  const context = { ...f.context, clientProjectDir: project };
  await main(['init', '--agent-id', 'project-test', '--broker-url', 'nats://127.0.0.1:1', '--data-dir', context.dataDir], { manager: 'none' });
  const target = path.join(project, '.mcp.json');
  const foreign = { command: 'keep-unrelated-tool' };
  const before = JSON.stringify({ mcpServers: { foreign, murmur: { command: process.execPath, args: [path.join(f.root, 'old-runtime', 'packages', 'mcp-server', 'dist', 'src', 'index.js')], env: { DATA_DIR: context.dataDir, MURMUR_STORE_PATH: context.storePath } } } });
  await fs.writeFile(target, before);
  const plan = await previewClientConfiguration(context, f.adapter, 'claude-code');
  assert.equal(plan.action, 'replace');
  await assert.rejects(configureClient(context, f.adapter, 'claude-code', false, plan.planId), /client.murmur-entry-conflict/);
  assert.equal(await fs.readFile(target, 'utf8'), before);
  const result = await configureClient(context, f.adapter, 'claude-code', true, plan.planId);
  assert.equal(await fs.readFile(result.backup, 'utf8'), before);
  const entries = JSON.parse(await fs.readFile(target, 'utf8')).mcpServers;
  assert.equal(entries.murmur, undefined);
  assert.deepEqual(entries.foreign, foreign);
  assert.equal(entries[plan.serverName].env.DATA_DIR, context.dataDir);
});

test('project connection refuses an inherited wake hook without rewriting global or project files', async t => {
  const f = await fixture(t);
  const project = path.join(f.home, 'Murmur'); await fs.mkdir(project);
  await configureClient(f.context, f.adapter, 'claude-code');
  const before = await fs.readFile(f.settingsPath, 'utf8');
  await assert.rejects(configureClient({ ...f.context, clientProjectDir: project }, f.adapter, 'claude-code', true), /client.inherited-wake-hook-conflict/);
  assert.equal(await fs.readFile(f.settingsPath, 'utf8'), before);
  await assert.rejects(fs.stat(path.join(project, '.mcp.json')), { code: 'ENOENT' });
  await assert.rejects(fs.stat(path.join(project, '.claude')), { code: 'ENOENT' });
});

for (const scope of ['project', 'parent', 'global']) test(`project connection refuses a ${scope} settings.local.json wake hook before any write`, async t => {
  const f = await fixture(t);
  const parent = path.join(f.home, 'work');
  const project = path.join(parent, 'Murmur'); await fs.mkdir(project, { recursive: true });
  const dir = scope === 'project' ? project : scope === 'parent' ? parent : f.home;
  const local = path.join(dir, '.claude', 'settings.local.json');
  await fs.mkdir(path.dirname(local), { recursive: true });
  const before = '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"node /old/wake-drain-claude.mjs"}]}]},"model":"keep"}\n';
  await fs.writeFile(local, before);
  const context = { ...f.context, clientProjectDir: project };
  await assert.rejects(previewClientConfiguration(context, f.adapter, 'claude-code'), /client.inherited-wake-hook-conflict/);
  await assert.rejects(configureClient(context, f.adapter, 'claude-code', true), /client.inherited-wake-hook-conflict/);
  assert.equal(await fs.readFile(local, 'utf8'), before);
  for (const file of [f.configPath, f.settingsPath, path.join(project, '.mcp.json'), path.join(project, '.claude', 'settings.json')]) {
    await assert.rejects(fs.stat(file), { code: 'ENOENT' });
  }
  assert.deepEqual(await fs.readdir(path.dirname(local)), ['settings.local.json']);
});

test('a different Murmur wake hook is replaced only on request, and the .sh variant goes', async t => {
  const f = await fixture(t);
  await fs.mkdir(path.dirname(f.settingsPath));
  const shell = { type: 'command', command: '/opt/murmur/scripts/wake-drain-claude.sh', asyncRewake: true };
  const other = { type: 'command', command: 'notify-done' };
  const before = JSON.stringify({ hooks: { Stop: [{ hooks: [shell, other] }] } });
  await fs.writeFile(f.settingsPath, before);
  await assert.rejects(configureClient(f.context, f.adapter, 'claude-code'), /client\.wake-hook-conflict/);
  assert.equal(await fs.readFile(f.settingsPath, 'utf8'), before);
  await assert.rejects(fs.stat(f.configPath), { code: 'ENOENT' }); // refused before the MCP entry was written
  const replaced = await configureClient(f.context, f.adapter, 'claude-code', true);
  assert.equal(replaced.wakeHook.action, 'replace');
  const hooks = (await f.settings()).hooks.Stop.flatMap(group => group.hooks);
  assert.deepEqual(hooks.filter(hook => !hook.command.includes('wake-drain-claude')), [other]);
  assert.equal((await f.ourHooks()).length, 1);
  assert.doesNotMatch((await f.ourHooks())[0].command, /\.sh/);
});

test('an entry written by 2.11.0 (no timeout) makes the whole plan a replace, so apps ask once and upgrade it', async t => {
  const f = await fixture(t);
  await main(['init', '--agent-id', 'hook-upgrade', '--broker-url', 'nats://127.0.0.1:4222', '--data-dir', f.context.dataDir], { manager: 'none' });
  // First configure with the current engine, then strip the timeout the way 2.11.0 wrote it.
  await configureClient(f.context, f.adapter, 'claude-code');
  const current = await f.settings();
  for (const group of current.hooks.Stop) for (const hook of group.hooks) if (hook.command.includes('wake-drain-claude')) delete hook.timeout;
  await fs.writeFile(f.settingsPath, JSON.stringify(current));
  const plan = await previewClientConfiguration(f.context, f.adapter, 'claude-code');
  assert.equal(plan.wakeHook.action, 'replace');
  assert.equal(plan.action, 'replace', 'the MCP entry is unchanged, but the plan must still say replace for the Mac app to pass --replace');
  await assert.rejects(configureClient(f.context, f.adapter, 'claude-code'), /client\.wake-hook-conflict/);
  const upgraded = await configureClient(f.context, f.adapter, 'claude-code', true);
  assert.equal(upgraded.changed, true); assert.equal(upgraded.wakeHook.action, 'replace');
  const [hook] = await f.ourHooks();
  assert.equal(hook.timeout, 28800);
  const settled = await previewClientConfiguration(f.context, f.adapter, 'claude-code');
  assert.equal(settled.action, 'unchanged'); assert.equal(settled.wakeHook.action, 'unchanged');
});

test('the confirmation plan covers the hook and goes stale when settings change', async t => {
  const f = await fixture(t);
  await main(['init', '--agent-id', 'hook-test', '--broker-url', 'nats://127.0.0.1:4222', '--data-dir', f.context.dataDir], { manager: 'none' });
  const plan = await previewClientConfiguration(f.context, f.adapter, 'claude-code');
  assert.deepEqual(plan.wakeHook, { settingsPath: f.settingsPath, action: 'add' });
  await assert.rejects(fs.stat(path.dirname(f.settingsPath)), { code: 'ENOENT' }); // preview writes nothing
  await fs.mkdir(path.dirname(f.settingsPath));
  await fs.writeFile(f.settingsPath, '{"model":"changed-after-preview"}');
  await assert.rejects(configureClient(f.context, f.adapter, 'claude-code', false, plan.planId), /client\.plan-stale/);
  const fresh = await previewClientConfiguration(f.context, f.adapter, 'claude-code');
  const done = await configureClient(f.context, f.adapter, 'claude-code', false, fresh.planId);
  assert.equal(done.planId, fresh.planId); assert.equal(done.wakeHook.action, 'add');
});

test('the wake drain reads the store given by --db, as the hook passes it', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'murmur-drain-db- пробел-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const db = path.join(root, 'profile', 'murmur.db');
  await fs.mkdir(path.dirname(db));
  const store = new DatabaseSync(db);
  store.exec('CREATE TABLE local_messages (msg_id TEXT PRIMARY KEY, created_at TEXT, sender TEXT, conversation_id TEXT, direction TEXT, text TEXT)');
  const env = { ...process.env, HOME: root, USERPROFILE: root, MURMUR_DB: path.join(root, 'wrong.db'), MURMUR_WAKE_SESSION_KEY: 'hooktest' };
  const drain = () => spawnSync(process.execPath, ['--no-warnings', path.join(repoRoot, 'scripts', 'wake-drain-claude.mjs'), '--once', '--db', db], { env, encoding: 'utf8' });
  assert.equal(drain().status, 0, 'first run seeds the cursor at the empty tip');
  store.prepare("INSERT INTO local_messages VALUES ('m1','2026-09-24T00:00:00.000Z','agent-peer','conv','inbound','wake up')").run();
  store.close();
  const woke = drain();
  assert.equal(woke.status, 2, woke.stdout + woke.stderr);
  assert.match(woke.stdout + woke.stderr, /agent-peer/);
});

test('--max-seconds bounds the drain poll and wins over MURMUR_WAKE_MAX_SECONDS', async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'murmur-drain-window-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const db = path.join(root, 'murmur.db');
  const store = new DatabaseSync(db);
  store.exec('CREATE TABLE local_messages (msg_id TEXT PRIMARY KEY, created_at TEXT, sender TEXT, conversation_id TEXT, direction TEXT, text TEXT)');
  store.close();
  const env = { ...process.env, HOME: root, USERPROFILE: root, MURMUR_WAKE_SESSION_KEY: 'window', MURMUR_WAKE_MAX_SECONDS: '3600', MURMUR_WAKE_POLL_MS: '200' };
  const drain = extra => spawnSync(process.execPath, ['--no-warnings', path.join(repoRoot, 'scripts', 'wake-drain-claude.mjs'), '--db', db, ...extra], { env, encoding: 'utf8', timeout: 20_000 });
  assert.equal(drain(['--once']).status, 0); // seed the cursor
  const started = Date.now();
  const polled = drain(['--max-seconds', '2']);
  assert.equal(polled.error, undefined, 'the environment hour must not apply');
  assert.equal(polled.status, 0, polled.stdout + polled.stderr);
  assert.ok(Date.now() - started < 15_000, `poll lasted ${Date.now() - started} ms`);
});

test('no hook is installed when this runtime does not ship the wake drain', async t => {
  const f = await fixture(t);
  const bare = path.join(f.root, 'runtime-without-drain');
  await fs.mkdir(path.join(bare, 'scripts'), { recursive: true });
  const context = resolveContext({ dataDir: f.context.dataDir, repoRoot: bare });
  await assert.rejects(configureClient(context, f.adapter, 'claude-code'), /^Error: client\.wake-drain-missing$/);
  await assert.rejects(fs.stat(f.configPath), { code: 'ENOENT' });
  await assert.rejects(fs.stat(f.settingsPath), { code: 'ENOENT' });
});

test('the released runtime and npm package carry the script the installed hook runs', async () => {
  const { SCRIPTS } = await import('../scripts/build-runtime-bundle.mjs');
  assert.ok(SCRIPTS.includes('wake-drain-claude.mjs'));
  for (const script of SCRIPTS) assert.ok((await fs.stat(path.join(repoRoot, 'scripts', script))).isFile(), script);
});

// A ten-minute Stop window made people add their own drain hooks under other events. After an
// upgrade those kept an older script and shared one session cursor with the new one, silently.
test('hand-written drain hooks under other events are repointed at this runtime, keeping their flags', async t => {
  const f = await fixture(t);
  await main(['init', '--agent-id', 'hook-repoint', '--broker-url', 'nats://127.0.0.1:4222', '--data-dir', f.context.dataDir], { manager: 'none' });
  await fs.mkdir(path.dirname(f.settingsPath), { recursive: true });
  const stale = '/opt/murmur-2.11/scripts/wake-drain-claude.mjs';
  const before = JSON.stringify({ hooks: {
    PostToolUse: [{ hooks: [{ type: 'command', command: `node --no-warnings ${stale} --once`, asyncRewake: true }] }],
    SessionStart: [{ matcher: '', hooks: [{ type: 'command', command: `node ${stale} --session`, timeout: 120 },
      { type: 'command', command: 'unrelated-tool' }] }],
  } });
  await fs.writeFile(f.settingsPath, before);

  const plan = await previewClientConfiguration(f.context, f.adapter, 'claude-code');
  assert.equal(plan.wakeHook.action, 'replace');
  assert.deepEqual(plan.wakeHook.repointed, ['PostToolUse', 'SessionStart'], 'the preview names the events it would touch');
  // Hooks a person wrote are never rewritten without the same consent the Stop hook needs.
  await assert.rejects(configureClient(f.context, f.adapter, 'claude-code'), /client\.wake-hook-conflict/);
  assert.equal(await fs.readFile(f.settingsPath, 'utf8'), before);

  const result = await configureClient(f.context, f.adapter, 'claude-code', true);
  assert.deepEqual(result.wakeHook.repointed, ['PostToolUse', 'SessionStart']);
  const next = await f.settings(), drain = slash(path.join(repoRoot, 'scripts', 'wake-drain-claude.mjs'));
  const post = next.hooks.PostToolUse[0].hooks[0], [session, untouched] = next.hooks.SessionStart[0].hooks;
  assert.equal(post.command, `node --no-warnings "${drain}" --once`, 'only the script path moves');
  assert.equal(post.asyncRewake, true);
  assert.equal(session.command, `node "${drain}" --session`);
  assert.equal(session.timeout, 120, 'a timeout the person chose is not overwritten');
  assert.deepEqual(untouched, { type: 'command', command: 'unrelated-tool' });
  assert.equal(next.hooks.SessionStart[0].matcher, '');
  // One script version in the file now, and a second run has nothing left to do.
  const commands = Object.values(next.hooks).flatMap(groups => groups.flatMap(group => group.hooks))
    .filter(hook => hook.command.includes('wake-drain-claude')).map(hook => hook.command);
  assert.equal(commands.length, 3);
  for (const command of commands) assert.ok(command.includes(drain), command);
  const settled = await previewClientConfiguration(f.context, f.adapter, 'claude-code');
  assert.equal(settled.wakeHook.action, 'unchanged');
  assert.equal(settled.wakeHook.repointed, undefined);
});

test('a drain hook already on this runtime, and an event that is not hook groups, are both left alone', async t => {
  const f = await fixture(t);
  await main(['init', '--agent-id', 'hook-settled', '--broker-url', 'nats://127.0.0.1:4222', '--data-dir', f.context.dataDir], { manager: 'none' });
  await configureClient(f.context, f.adapter, 'claude-code');
  const drain = slash(path.join(repoRoot, 'scripts', 'wake-drain-claude.mjs'));
  const current = await f.settings();
  current.hooks.PostToolUse = [{ hooks: [{ type: 'command', command: `node "${drain}" --once` }] }];
  current.hooks.Notification = { channel: 'desktop' }; // not hook groups: another product's shape
  await fs.writeFile(f.settingsPath, JSON.stringify(current));
  const plan = await previewClientConfiguration(f.context, f.adapter, 'claude-code');
  assert.equal(plan.wakeHook.action, 'unchanged', 'a hook already pointing here is not a reason to ask for --replace');
  assert.equal(plan.wakeHook.repointed, undefined);
  const after = await f.settings();
  assert.deepEqual(after.hooks.Notification, { channel: 'desktop' });
  assert.equal(after.hooks.PostToolUse[0].hooks[0].command, `node "${drain}" --once`);
});
