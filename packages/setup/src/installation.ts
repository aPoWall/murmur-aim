import { constants } from 'node:fs';
import { lstat, mkdir, open, rename, rmdir, unlink } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { installationFile, installationIdentity, readInstallationDescriptor, resolveInstallation, type InstallationDescriptor } from '@murmurv2/core';
import { protectPrivateFile } from './private-file.js';
import { loadConfig } from './config.js';
import type { ServiceContext } from './types.js';

export function showInstallation(file?: string) {
  const descriptorFile = installationFile({ installationFile: file });
  // Show the registered choice, not an ambient DATA_DIR override.
  const selected = resolveInstallation({ installationFile: descriptorFile, env: {} });
  return { ...selected.descriptor, descriptorFile };
}

export function checkInstallationSelection(c: ServiceContext, options: { file?: string; replace?: boolean } = {}) {
  const file = installationFile({ installationFile: options.file });
  const relative = path.relative(c.dataDir, file);
  if ((!relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative))
    && relative !== 'installation.json') throw new Error('installation.file-conflict');
  try {
    const previous = readInstallationDescriptor(file);
    if (!options.replace && (previous.dataDir !== c.dataDir || !isDeepStrictEqual(
      { agentId: previous.agentId, identityFingerprint: previous.identityFingerprint }, installationIdentity(c.dataDir)))) {
      throw new Error('installation.selection-conflict');
    }
  } catch (error) {
    if (!(error instanceof Error && error.message === 'installation.descriptor-missing')) throw error;
  }
}

/** Explicitly register an existing profile; never relocate it, rotate keys or rewrite client/service settings. */
export async function selectInstallation(c: ServiceContext, options: { file?: string; replace?: boolean } = {}) {
  checkInstallationSelection(c, options);
  await loadConfig(c);
  const identity = installationIdentity(c.dataDir), file = installationFile({ installationFile: options.file });
  if (file === c.configPath || file === c.storePath) throw new Error('installation.file-conflict');
  const desired: InstallationDescriptor = { schema: 'murmur.installation/1', dataDir: c.dataDir, ...identity };
  await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const lock = `${file}.murmur-lock`; await mkdir(lock, { mode: 0o700 });
  const read = () => {
    try { return readInstallationDescriptor(file); }
    catch (error) { if (error instanceof Error && error.message === 'installation.descriptor-missing') return null; throw error; }
  };
  const temporary = `${file}.${randomUUID()}.tmp`;
  try {
    const previous = read();
    if (isDeepStrictEqual(previous, desired)) return { ...desired, descriptorFile: file, changed: false, existingConsumersChanged: false };
    if (previous && !options.replace) throw new Error('installation.selection-conflict');
    const handle = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | (constants.O_NOFOLLOW ?? 0), 0o600);
    try { await protectPrivateFile(temporary, handle); await handle.writeFile(JSON.stringify(desired, null, 2) + '\n'); await handle.sync(); }
    finally { await handle.close(); }
    if (!isDeepStrictEqual(previous, read()) || !isDeepStrictEqual(identity, installationIdentity(c.dataDir))) throw new Error('installation.selection-changed');
    if (!previous) {
      // A non-cooperating creator appearing while we prepared the descriptor must not be overwritten.
      try { await lstat(file); throw new Error('installation.selection-changed'); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
    }
    await rename(temporary, file);
    return { ...desired, descriptorFile: file, changed: true, existingConsumersChanged: false };
  } finally { await unlink(temporary).catch(() => {}); await rmdir(lock); }
}
