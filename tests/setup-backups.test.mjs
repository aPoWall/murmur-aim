import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { previewBackups, cleanupBackups } from '../packages/setup/dist/src/backups.js';
import { protectPrivateFile } from '../packages/setup/dist/src/private-file.js';
import { resolveContext } from '../packages/setup/dist/src/paths.js';
import { main } from '../packages/setup/dist/src/cli.js';
import { assertPrivateFile, addExplicitAccessFixture } from './helpers/private-files.mjs';

const now = Date.UTC(2026, 9, 16, 12), day = 86400000;
const key = Buffer.alloc(32, 7).toString('base64');
const config = { agentId: 'test-agent', subject: 'msg.test-agent', natsUrl: 'nats://localhost:4222', peers: {},
  keys: { signing: { publicKey: key, privateKey: key }, encryption: { publicKey: key, privateKey: key } } };

async function fixture(t, kind = 'agent', format = 'json', count = 7) {
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'murmur-backups-'));
  const root = await fs.realpath(temporary);
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const context = resolveContext({ dataDir: root });
  const source = kind === 'agent' ? context.configPath : path.join(root, `client.${format}`);
  const text = kind === 'agent' ? JSON.stringify(config) : format === 'toml' ? '[mcp_servers]\n' : '{"mcpServers":{}}';
  await fs.writeFile(source, text, { mode: 0o600 });
  const files = [];
  const add = async (age, contents = text) => {
    const file = kind === 'agent' ? path.join(root, `agent-config.backup-${randomUUID()}.json`) : `${source}.murmur-backup-${randomUUID()}`;
    const handle = await fs.open(file, 'wx', 0o600);
    try { await protectPrivateFile(file, handle); await handle.writeFile(contents); } finally { await handle.close(); }
    await fs.utimes(file, new Date(now - age * day), new Date(now - age * day));
    files.push(file); return file;
  };
  for (let i = 0; i < count; i++) await add(40 + i);
  return { root, context, source, files, add, text, selection: { kind, ...(kind === 'client' ? { configFile: source } : {}) } };
}

for (const [kind, format] of [['agent', 'json'], ['client', 'json'], ['client', 'toml']]) {
  test(`${kind}/${format}: explicit preview keeps recovery window, five copies and a named restore point`, async t => {
    const f = await fixture(t, kind, format), recent = await f.add(2), pin = f.files.at(-2);
    const selection = { ...f.selection, keepFiles: [pin] };
    const unrelated = path.join(f.root, 'other-config.murmur-backup-' + randomUUID());
    await fs.writeFile(unrelated, 'unrelated');
    const before = await fs.readdir(f.root);
    const plan = await previewBackups(f.context, selection, now);
    assert.deepEqual(await fs.readdir(f.root), before, 'preview creates no lock or metadata');
    assert.equal(plan.entries.length, 8); assert.equal(plan.removable, 2);
    assert.equal(plan.entries.find(x => x.path === pin).reason, 'explicit-keep');
    assert.equal(plan.entries.find(x => x.path === recent).action, 'keep');
    assert.equal(JSON.stringify(plan).includes(key), false);
    const result = await cleanupBackups(f.context, selection, plan.planId, now);
    assert.deepEqual(result.removed, plan.entries.filter(x => x.action === 'remove').map(x => x.path));
    assert.equal(await fs.readFile(f.source, 'utf8'), f.text);
    assert.equal(await fs.readFile(unrelated, 'utf8'), 'unrelated');
    for (const file of result.retained) await assertPrivateFile(file);
    assert.equal((await previewBackups(f.context, selection, now)).removable, 0);
    assert.equal((await fs.readdir(f.root)).some(x => x.includes('lock')), false);
  });
}

test('all recent backups survive even when there are more than five', async t => {
  const f = await fixture(t, 'agent', 'json', 0);
  for (let i = 0; i < 6; i++) await f.add(3);
  assert.equal((await previewBackups(f.context, f.selection, now)).removable, 0);
});

for (const change of ['content-with-original-mtime', 'current-config', 'new-backup', 'next-day']) {
  test(`cleanup refuses stale ${change} preview before deleting anything`, async t => {
    const f = await fixture(t), plan = await previewBackups(f.context, f.selection, now);
    if (change === 'content-with-original-mtime') {
      const target = f.files.at(-1), stat = await fs.stat(target);
      await fs.writeFile(target, JSON.stringify({ ...config, wake: { enabled: false } }));
      await fs.utimes(target, stat.atime, stat.mtime);
    } else if (change === 'current-config') await fs.writeFile(f.source, JSON.stringify({ ...config, wake: { enabled: false } }));
    else if (change === 'new-backup') await f.add(1);
    await assert.rejects(cleanupBackups(f.context, f.selection, plan.planId, change === 'next-day' ? now + day : now), /backups.plan-stale/);
    for (const file of f.files) assert.equal((await fs.lstat(file)).isFile(), true);
    assert.equal((await fs.readdir(f.root)).some(x => x.includes('lock')), false);
  });
}

test('matching unsafe file and invalid current config stop cleanup; no permission repair', async t => {
  const f = await fixture(t), file = f.files.at(-1);
  if (process.platform === 'win32') await addExplicitAccessFixture(file);
  else await fs.chmod(file, 0o644);
  await assert.rejects(previewBackups(f.context, f.selection, now), /backups.permissions-invalid/);
  assert.equal((await fs.readdir(f.root)).length, 8);
  if (process.platform !== 'win32') assert.equal((await fs.stat(file)).mode & 0o777, 0o644);
  await fs.writeFile(f.source, '{broken');
  await assert.rejects(previewBackups(f.context, f.selection, now), /backups.config-invalid/);
});

test('symlinks and hard links cannot be cleanup targets', async t => {
  const f = await fixture(t, 'client', 'json', 0), target = `${f.source}.murmur-backup-${randomUUID()}`;
  await fs.link(f.source, target);
  await assert.rejects(previewBackups(f.context, f.selection, now), /backups.file-invalid/);
  await fs.unlink(target);
  try { await fs.symlink(f.source, target); }
  catch (error) { if (process.platform === 'win32' && error.code === 'EPERM') { t.diagnostic('symlink unavailable to this Windows account; hardlink refusal verified'); return; } throw error; }
  await assert.rejects(previewBackups(f.context, f.selection, now), /backups.file-invalid/);
  assert.equal(await fs.readFile(f.source, 'utf8'), f.text);
});

test('existing writer lock is preserved and prevents cleanup', async t => {
  const f = await fixture(t), plan = await previewBackups(f.context, f.selection, now);
  const lock = path.join(f.root, '.setup-write.lock'); await fs.mkdir(lock);
  await assert.rejects(cleanupBackups(f.context, f.selection, plan.planId, now), { code: 'EEXIST' });
  assert.equal((await fs.stat(lock)).isDirectory(), true);
  assert.equal((await fs.readdir(f.root)).length, 9);
});

test('CLI requires explicit kind, exact client path and preview digest', async t => {
  const f = await fixture(t, 'client', 'json', 0);
  const args = ['--data-dir', f.root];
  await assert.rejects(main(['backups', 'preview', ...args]), /cli.required-option:kind/);
  await assert.rejects(main(['backups', 'cleanup', '--kind', 'client', '--config-file', f.source, ...args]), /cli.required-option:plan-id/);
  await assert.rejects(main(['backups', 'preview', '--kind', 'client', '--config-file', 'relative.json', ...args]), /backups.absolute-config-file-required/);
  const plan = await main(['backups', 'preview', '--kind', 'client', '--config-file', f.source, ...args]);
  const independent = await main(['backups', 'preview', '--kind', 'client', '--config-file', f.source,
    '--installation-file', path.join(f.root, 'missing-installation.json')]);
  assert.equal(independent.planId, plan.planId, 'client backup cleanup does not require an agent installation');
  const result = await main(['backups', 'cleanup', '--kind', 'client', '--config-file', f.source, '--plan-id', plan.planId, ...args]);
  assert.deepEqual(result.removed, []);
});
