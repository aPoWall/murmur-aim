import { constants, type BigIntStats } from 'node:fs';
import { lstat, mkdir, open, readdir, realpath, rmdir, unlink } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import * as TOML from '@iarna/toml';
import { validateConfig } from './config.js';
import { sameClientFileIdentity } from './file-identity.js';
import { verifyPrivateFileAccess } from './private-file.js';
import type { ServiceContext } from './types.js';

const DAY = 86_400_000;
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const POLICY = { days: 30, minimumCopies: 5 } as const;
const digest = (value: unknown) => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const identity = (s: BigIntStats) => [s.dev, s.ino, s.size, s.mtimeNs, s.ctimeNs, s.uid, s.mode, s.nlink].map(String);
export interface BackupSelection { kind: 'agent' | 'client'; configFile?: string; keepFiles?: readonly string[] }

async function readFile(file: string, privateBackup: boolean) {
  const before = await lstat(file, { bigint: true });
  if (!before.isFile() || before.nlink !== 1n || before.size > 4n * 1024n * 1024n
    || (process.getuid && before.uid !== BigInt(process.getuid()))) throw new Error('backups.file-invalid');
  const handle = await open(file, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const opened = await handle.stat({ bigint: true });
    if (!sameClientFileIdentity(before, opened)) throw new Error('backups.file-changed');
    if (privateBackup) await verifyPrivateFileAccess(file, opened);
    const text = await handle.readFile('utf8');
    const after = await lstat(file, { bigint: true });
    if (digest(identity(before)) !== digest(identity(after)) || !sameClientFileIdentity(after, opened)) throw new Error('backups.file-changed');
    return { text, fingerprint: [identity(after), digest(text)], modifiedAt: Number(after.mtimeMs), size: Number(after.size) };
  } finally { await handle.close(); }
}

function validateDocument(text: string, selection: BackupSelection, file: string) {
  try {
    const value: unknown = file.endsWith('.toml') ? TOML.parse(text) : JSON.parse(text);
    if (selection.kind === 'agent') validateConfig(value);
    else if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
  } catch { throw new Error('backups.config-invalid'); }
}

async function selected(c: ServiceContext, selection: BackupSelection) {
  if (!['agent', 'client'].includes(selection.kind)) throw new Error('backups.kind-required');
  if (selection.kind === 'agent' && selection.configFile !== undefined) throw new Error('backups.selection-conflict');
  const file = selection.kind === 'agent' ? c.configPath : selection.configFile;
  if (!file || !path.isAbsolute(file) || path.normalize(file) !== file) throw new Error('backups.absolute-config-file-required');
  if (selection.kind === 'client' && !/\.(json|toml)$/.test(file)) throw new Error('backups.client-format-invalid');
  const directory = await realpath(path.dirname(file));
  if (directory === path.parse(directory).root) throw new Error('backups.directory-invalid');
  const info = await lstat(directory, { bigint: true });
  if (!info.isDirectory() || (process.getuid && (info.uid !== BigInt(process.getuid()) || (info.mode & 0o022n) !== 0n))) {
    throw new Error('backups.directory-invalid');
  }
  // The service's selected path is unchanged. Only cleanup targets use this verified canonical parent.
  const configFile = path.join(directory, path.basename(file));
  const escaped = path.basename(file).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const pattern = selection.kind === 'agent' ? new RegExp(`^agent-config\\.backup-${UUID}\\.json$`)
    : new RegExp(`^${escaped}\\.murmur-backup-${UUID}$`);
  return { directory, configFile, pattern, directoryIdentity: identity(info).slice(0, 2),
    lock: selection.kind === 'agent' ? path.join(directory, '.setup-write.lock') : `${configFile}.murmur-lock` };
}

async function inspect(c: ServiceContext, selection: BackupSelection, now: number) {
  const source = await selected(c, selection), current = await readFile(source.configFile, false);
  validateDocument(current.text, selection, source.configFile);
  const cutoff = Math.floor(now / DAY) * DAY - POLICY.days * DAY;
  const files: Array<Awaited<ReturnType<typeof readFile>> & { path: string }> = [];
  for (const name of (await readdir(source.directory)).filter(name => source.pattern.test(name))) {
    const file = path.join(source.directory, name), snapshot = await readFile(file, true);
    // Corrupted recovery material needs investigation; never automatically classify it as disposable.
    validateDocument(snapshot.text, selection, source.configFile);
    files.push({ path: file, ...snapshot });
  }
  files.sort((a, b) => b.modifiedAt - a.modifiedAt || a.path.localeCompare(b.path));
  const kept = new Set(selection.keepFiles ?? []);
  if ([...kept].some(file => !files.some(item => item.path === file))) throw new Error('backups.keep-file-invalid');
  const entries = files.map((file, index) => ({ path: file.path, size: file.size, modifiedAt: new Date(file.modifiedAt).toISOString(),
    action: kept.has(file.path) || index < POLICY.minimumCopies || file.modifiedAt >= cutoff ? 'keep' as const : 'remove' as const,
    reason: kept.has(file.path) ? 'explicit-keep' : index < POLICY.minimumCopies ? 'newest-five' : file.modifiedAt >= cutoff ? 'recovery-window' : 'outside-retention' }));
  const planId = digest([selection.kind, source.configFile, source.directoryIdentity, current.fingerprint, cutoff,
    files.map(file => [file.path, file.fingerprint]), entries]);
  return { source, files, report: { schema: 'murmur.backup-plan/1', kind: selection.kind, configFile: source.configFile,
    policy: POLICY, cutoff: new Date(cutoff).toISOString(), expiresAt: new Date((Math.floor(now / DAY) + 1) * DAY).toISOString(),
    planId, entries, removable: entries.filter(entry => entry.action === 'remove').length } };
}

/** No chmod, lock, directory creation, metadata write or automatic migration during preview. */
export async function previewBackups(c: ServiceContext, selection: BackupSelection, now = Date.now()) {
  return (await inspect(c, selection, now)).report;
}

/** Explicit deletion requires an unchanged, same-day preview and the existing setup writer's lock. */
export async function cleanupBackups(c: ServiceContext, selection: BackupSelection, expectedPlan: string, now = Date.now()) {
  if (!/^[a-f0-9]{64}$/.test(expectedPlan)) throw new Error('backups.plan-required');
  const source = await selected(c, selection);
  await mkdir(source.lock, { mode: 0o700 });
  const removed: string[] = [];
  try {
    const plan = await inspect(c, selection, now);
    if (plan.report.planId !== expectedPlan) throw new Error('backups.plan-stale');
    for (const entry of plan.report.entries.filter(entry => entry.action === 'remove')) {
      const current = await selected(c, selection);
      if (current.directory !== source.directory || digest(current.directoryIdentity) !== digest(source.directoryIdentity)) throw new Error('backups.directory-changed');
      const saved = plan.files.find(file => file.path === entry.path)!;
      if (digest((await readFile(entry.path, true)).fingerprint) !== digest(saved.fingerprint)) throw new Error('backups.plan-stale');
      await unlink(entry.path);
      removed.push(entry.path);
    }
    return { schema: 'murmur.backup-cleanup/1', kind: selection.kind, configFile: plan.report.configFile,
      planId: expectedPlan, removed, retained: plan.report.entries.filter(entry => entry.action === 'keep').map(entry => entry.path) };
  } finally { await rmdir(source.lock); }
}
