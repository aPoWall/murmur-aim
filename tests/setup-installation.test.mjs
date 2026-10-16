import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { createServer } from 'node:net';
import { installationFile, resolveInstallation, SQLiteMessageStore } from '../packages/core/dist/src/index.js';
import { main } from '../packages/setup/dist/src/cli.js';
import { resolveContext } from '../packages/setup/dist/src/paths.js';
import { assertPrivateFile, addExplicitAccessFixture } from './helpers/private-files.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
const cli = path.join(repo, 'packages/setup/bin/murmur.mjs');
async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'murmur-installation-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const dataDir = path.join(root, 'profile'), descriptor = path.join(root, 'installation.json');
  const env = { ...process.env, MURMUR_INSTALLATION_FILE: descriptor, MURMUR_UPDATE_CHECK: '0' };
  for (const key of ['DATA_DIR', 'MURMUR_DATA_DIR', 'MURMUR_STORE_PATH', 'MURMUR_CHANNEL_ROSTER_PATH']) delete env[key];
  const init = async (url = 'nats://127.0.0.1:4222') => main(['init', '--agent-id', 'selected-agent', '--broker-url', url,
    '--data-dir', dataDir, '--select', '--installation-file', descriptor]);
  return { root, dataDir, descriptor, env, init };
}

test('descriptor locations are predictable on Linux, macOS and Windows', () => {
  assert.equal(installationFile({ platform: 'linux', home: '/home/test', env: {} }), '/home/test/.config/murmur/installation.json');
  assert.equal(installationFile({ platform: 'linux', home: '/home/test', env: { XDG_CONFIG_HOME: '/cfg' } }), '/cfg/murmur/installation.json');
  assert.equal(installationFile({ platform: 'darwin', home: '/Users/test', env: {} }), '/Users/test/Library/Application Support/Murmur/installation.json');
  assert.equal(installationFile({ platform: 'win32', home: 'C:\\Users\\test', env: {} }), 'C:\\Users\\test\\AppData\\Local\\Murmur\\installation.json');
  assert.throws(() => installationFile({ env: { MURMUR_INSTALLATION_FILE: '' } }), /file-must-be-absolute/);
});

test('init --select writes one private identity binding; explicit multi-profile selection preserves it', async t => {
  const f = await fixture(t), result = await f.init();
  assert.equal(result.installation.changed, true); await assertPrivateFile(f.descriptor);
  const selected = resolveInstallation({ env: f.env }); assert.equal(selected.dataDir, f.dataDir);
  assert.equal(selected.descriptor.agentId, 'selected-agent');
  assert.equal(resolveContext({ installationFile: f.descriptor, env: f.env }).serviceName, result.serviceName);
  const before = await fs.readFile(f.descriptor, 'utf8');
  const other = path.join(f.root, 'other');
  await main(['init', '--agent-id', 'other-agent', '--broker-url', 'nats://127.0.0.1:4222', '--data-dir', other]);
  assert.equal(resolveInstallation({ dataDir: other, env: f.env }).dataDir, other);
  assert.equal(await fs.readFile(f.descriptor, 'utf8'), before);
  await assert.rejects(main(['installation', 'select', '--data-dir', other, '--installation-file', f.descriptor]), /selection-conflict/);
  await main(['installation', 'select', '--data-dir', other, '--installation-file', f.descriptor, '--replace']);
  assert.equal((await main(['installation', 'show', '--installation-file', f.descriptor])).agentId, 'other-agent');
  await assertPrivateFile(f.descriptor);
});

test('legacy profile registration preserves its identity, bytes and path spelling', async t => {
  const f = await fixture(t);
  await main(['init', '--agent-id', 'legacy-agent', '--broker-url', 'nats://127.0.0.1:4222', '--data-dir', f.dataDir]);
  const config = path.join(f.dataDir, 'agent-config.json'), before = await fs.readFile(config);
  await assert.rejects(fs.stat(f.descriptor), { code: 'ENOENT' });
  let selectedPath = f.dataDir;
  if (process.platform !== 'win32') {
    selectedPath = path.join(f.root, 'profile-alias'); await fs.symlink(f.dataDir, selectedPath);
  }
  await main(['installation', 'select', '--data-dir', selectedPath, '--installation-file', f.descriptor]);
  assert.equal(resolveInstallation({ env: f.env }).dataDir, selectedPath);
  assert.deepEqual(await fs.readFile(config), before);
  assert.equal(resolveContext({ env: f.env }).serviceName, resolveContext({ dataDir: selectedPath }).serviceName);
});

test('missing, stale, ambiguous and conflicting selections fail without creating stores', async t => {
  const f = await fixture(t);
  assert.throws(() => resolveInstallation({ env: f.env }), /descriptor-missing/);
  assert.throws(() => resolveInstallation({ env: { DATA_DIR: f.dataDir, MURMUR_DATA_DIR: path.join(f.root, 'other') } }), /data-dir-conflict/);
  assert.throws(() => resolveInstallation({ env: { DATA_DIR: '' } }), /data-dir-empty/);
  await f.init();
  const original = await fs.readFile(f.descriptor, 'utf8'), file = path.join(f.dataDir, 'agent-config.json');
  const config = JSON.parse(await fs.readFile(file, 'utf8'));
  await fs.writeFile(file, JSON.stringify({ ...config, agentId: 'replaced-agent' }));
  assert.throws(() => resolveInstallation({ env: f.env }), /identity-changed/);
  await fs.writeFile(file, JSON.stringify({ ...config, keys: { ...config.keys,
    signing: { ...config.keys.signing, publicKey: Buffer.alloc(32, 9).toString('base64') } } }));
  assert.throws(() => resolveInstallation({ env: f.env }), /identity-changed/);
  await fs.writeFile(file, JSON.stringify(config));
  await fs.writeFile(f.descriptor, JSON.stringify({ profiles: [f.dataDir, path.join(f.root, 'other')] }));
  assert.throws(() => resolveInstallation({ env: f.env }), /installation.ambiguous/);
  await fs.writeFile(f.descriptor, original); await fs.unlink(file);
  assert.throws(() => resolveInstallation({ env: f.env }), /profile-missing/);
  await assert.rejects(fs.stat(path.join(f.dataDir, 'murmur.db')), { code: 'ENOENT' });
});

test('selection conflicts are refused before init creates another identity', async t => {
  const f = await fixture(t); await f.init();
  const other = path.join(f.root, 'other');
  await assert.rejects(main(['init', '--agent-id', 'other', '--broker-url', 'nats://localhost:4222', '--data-dir', other,
    '--select', '--installation-file', f.descriptor]), /selection-conflict/);
  await assert.rejects(fs.stat(other), { code: 'ENOENT' });
  await assert.rejects(main(['installation', 'select', '--data-dir', f.dataDir,
    '--installation-file', path.join(f.dataDir, 'future-runtime.db')]), /file-conflict/);
});

test('descriptor link and access violations are refused unchanged', async t => {
  const f = await fixture(t); await f.init();
  const alias = path.join(f.root, 'hardlink.json'); await fs.link(f.descriptor, alias);
  assert.throws(() => resolveInstallation({ installationFile: alias, env: {} }), /descriptor-invalid/);
  await fs.unlink(alias);
  if (process.platform === 'win32') await addExplicitAccessFixture(f.descriptor);
  else await fs.chmod(f.descriptor, 0o644);
  assert.throws(() => resolveInstallation({ env: f.env }), /descriptor-(invalid|permissions)/);
});

test('CLI and MCP from unrelated directories resolve the same selected store; bad launches create no .data', async t => {
  const f = await fixture(t); await f.init();
  const store = new SQLiteMessageStore(path.join(f.dataDir, 'murmur.db'));
  await store.append({ conversationId: 'fixture', msgId: 'selected-marker', direction: 'inbound', sender: 'peer', text: 'selected-store-marker', createdAt: new Date().toISOString() }); store.close();
  const directories = [path.join(f.root, 'cwd-a'), path.join(f.root, 'cwd-b')];
  for (const cwd of directories) {
    await fs.mkdir(cwd);
    const status = JSON.parse(execFileSync(process.execPath, [cli, 'status', '--json'], { cwd, env: f.env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
    assert.equal(status.agentId, 'selected-agent'); assert.equal(status.serviceName, resolveContext({ dataDir: f.dataDir }).serviceName);
    const child = spawn(process.execPath, [path.join(repo, 'packages/mcp-server/dist/src/index.js')], { cwd, env: f.env, stdio: ['pipe', 'pipe', 'pipe'] });
    t.after(() => { if (child.exitCode === null) child.kill(); });
    const response = new Promise((resolve, reject) => {
      let text = ''; const timer = setTimeout(() => reject(new Error('mcp-timeout')), 12000);
      child.once('exit', () => { clearTimeout(timer); reject(new Error('mcp-exited')); });
      child.stdout.on('data', chunk => { text += chunk; if (text.includes('\n')) { clearTimeout(timer); resolve(JSON.parse(text.split('\n')[0])); } });
    });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'murmur_inbox', arguments: { unread_only: false } } }) + '\n');
    assert.match(JSON.stringify(await response), /selected-store-marker/);
    const exit = once(child, 'exit'); child.kill(); await exit;
    assert.deepEqual(await fs.readdir(cwd), []);
  }
  for (const entry of [cli, path.join(repo, 'packages/mcp-server/dist/src/index.js'), path.join(repo, 'scripts/murmur-daemon.mjs')]) {
    const env = { ...f.env, MURMUR_INSTALLATION_FILE: path.join(f.root, 'absent.json') };
    const args = entry === cli ? [entry, 'status', '--json'] : [entry];
    const result = spawnSync(process.execPath, args, { cwd: directories[0], env, encoding: 'utf8', timeout: 5000 });
    assert.notEqual(result.status, 0); assert.match(result.stderr, /installation.descriptor-missing/);
    assert.deepEqual(await fs.readdir(directories[0]), []);
  }
  const conflict = spawnSync(process.execPath, [path.join(repo, 'packages/mcp-server/dist/src/index.js')], {
    cwd: directories[0], env: { ...f.env, MURMUR_STORE_PATH: path.join(f.root, 'wrong.db') }, encoding: 'utf8', timeout: 5000 });
  assert.notEqual(conflict.status, 0); assert.match(conflict.stderr, /installation.store-conflict/);
  await assert.rejects(fs.stat(path.join(f.root, 'wrong.db')), { code: 'ENOENT' });
});

test('real isolated daemon uses the selected identity from another cwd and pinned profile ignores another home', { timeout: 20000 }, async t => {
  try { execFileSync('nats-server', ['--version'], { stdio: 'ignore' }); } catch { t.skip('isolated broker unavailable'); return; }
  const f = await fixture(t), listener = createServer(); listener.listen(0, '127.0.0.1'); await once(listener, 'listening');
  const port = listener.address().port; await new Promise(resolve => listener.close(resolve));
  await f.init(`nats://127.0.0.1:${port}`);
  const cwd = path.join(f.root, 'unrelated'); await fs.mkdir(cwd);
  const broker = spawn('nats-server', ['-a', '127.0.0.1', '-p', String(port)], { stdio: 'ignore' });
  t.after(async () => { if (broker.exitCode === null) { broker.kill(); await once(broker, 'exit'); } });
  const daemon = spawn(process.execPath, [path.join(repo, 'scripts/murmur-daemon.mjs')], { cwd, env: f.env, stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(async () => { if (daemon.exitCode === null) { daemon.kill(); await once(daemon, 'exit'); } });
  let output = ''; daemon.stdout.on('data', chunk => { output += chunk; });
  for (let i = 0; i < 200 && !output.includes('Daemon ready'); i++) { if (daemon.exitCode !== null) break; await delay(25); }
  assert.match(output, /Daemon ready/); assert.match(output, /selected-agent/);
  assert.equal((await fs.stat(path.join(f.dataDir, 'murmur.db'))).isFile(), true);
  assert.deepEqual(await fs.readdir(cwd), []);
  const pinned = resolveInstallation({ env: { DATA_DIR: f.dataDir, HOME: '/other-account', MURMUR_INSTALLATION_FILE: '/absent/descriptor.json' }, requireConfig: true });
  assert.equal(pinned.source, 'environment'); assert.equal(pinned.dataDir, f.dataDir);
});
