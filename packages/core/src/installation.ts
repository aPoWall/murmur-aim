import path from 'node:path';
import { homedir } from 'node:os';
import { constants, openSync, closeSync, fstatSync, lstatSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';

export interface InstallationOptions {
  dataDir?: string; installationFile?: string; env?: NodeJS.ProcessEnv;
  platform?: NodeJS.Platform; home?: string; requireConfig?: boolean;
}
export interface InstallationDescriptor {
  schema: 'murmur.installation/1'; dataDir: string; agentId: string; identityFingerprint: string;
}
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value);
const pathsFor = (platform = process.platform) => platform === 'win32' ? path.win32 : path.posix;

function descriptorAccess(file: string): void {
  if (process.platform !== 'win32') return;
  const script = `$ErrorActionPreference='Stop'
$env:PSModulePath=[System.IO.Path]::Combine($PSHOME,'Modules')
$acl=Get-Acl -LiteralPath $env:MURMUR_DESCRIPTOR_CHECK
$user=[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$allowed=@($user,'S-1-5-18') | Select-Object -Unique
if (!$acl.AreAccessRulesProtected -or $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $user) { throw 'invalid' }
$rules=@($acl.GetAccessRules($true,$true,[System.Security.Principal.SecurityIdentifier]))
if ($rules.Count -ne $allowed.Count) { throw 'invalid' }
foreach ($rule in $rules) {
 if ($allowed -notcontains $rule.IdentityReference.Value -or $rule.AccessControlType -ne 'Allow' -or $rule.IsInherited -or
  $rule.FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl) { throw 'invalid' }
}`;
  try {
    execFileSync(path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
      ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')],
      { env: { ...process.env, MURMUR_DESCRIPTOR_CHECK: file }, windowsHide: true, timeout: 60_000, stdio: 'pipe', maxBuffer: 64 * 1024 });
  } catch { throw new Error('installation.descriptor-permissions'); }
}

/** Normalize separators only; never resolve filesystem aliases used to identify a service. */
export function installationDataDir(value: string, platform: NodeJS.Platform = process.platform): string {
  const paths = pathsFor(platform);
  if (!value) throw new Error('config.data-dir-empty');
  if (!paths.isAbsolute(value)) throw new Error('config.data-dir-must-be-absolute');
  const selected = paths.normalize(value);
  if (selected.length > paths.parse(selected).root.length && /[\\/]$/.test(selected)) throw new Error('profile.trailing-separator');
  return selected;
}

export function installationFile(options: InstallationOptions = {}): string {
  const env = options.env ?? process.env, platform = options.platform ?? process.platform;
  const paths = pathsFor(platform), home = options.home ?? homedir();
  const parent = platform === 'win32' ? (env.LOCALAPPDATA || paths.join(home, 'AppData', 'Local'))
    : platform === 'darwin' ? paths.join(home, 'Library', 'Application Support')
    : (env.XDG_CONFIG_HOME || paths.join(home, '.config'));
  const file = options.installationFile ?? env.MURMUR_INSTALLATION_FILE ?? paths.join(parent, platform === 'linux' ? 'murmur' : 'Murmur', 'installation.json');
  if (!file || !paths.isAbsolute(file)) throw new Error('installation.file-must-be-absolute');
  return paths.normalize(file);
}

function readDocument(file: string, kind: 'descriptor' | 'profile'): unknown {
  let handle: number | undefined;
  try {
    const before = lstatSync(file, { bigint: true });
    if (!before.isFile()) throw new Error(`installation.${kind}-invalid`);
    handle = openSync(file, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
    const info = fstatSync(handle, { bigint: true });
    const same = (a: typeof info, b: typeof info) => a.ino === b.ino
      && (process.platform === 'win32' || a.dev === b.dev) && a.size === b.size && a.mtimeNs === b.mtimeNs;
    if (!info.isFile() || info.size > BigInt(kind === 'descriptor' ? 16384 : 4 * 1024 * 1024)
      || !same(before, info) || (kind === 'descriptor' && info.nlink !== 1n)
      || (kind === 'descriptor' && process.getuid && info.uid !== BigInt(process.getuid()))
      || (kind === 'descriptor' && process.platform !== 'win32' && (info.mode & 0o077n) !== 0n)) {
      throw new Error(`installation.${kind}-invalid`);
    }
    if (kind === 'descriptor') descriptorAccess(file);
    const value: unknown = JSON.parse(readFileSync(handle, 'utf8'));
    if (!same(info, lstatSync(file, { bigint: true }))) throw new Error(`installation.${kind}-changed`);
    return value;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') throw new Error(`installation.${kind}-missing`);
    if (error instanceof Error && /^installation\.[a-z-]+$/.test(error.message)) throw error;
    throw new Error(`installation.${kind}-unreadable`);
  } finally { if (handle !== undefined) closeSync(handle); }
}

export function readInstallationDescriptor(file: string, platform: NodeJS.Platform = process.platform): InstallationDescriptor {
  const value = readDocument(file, 'descriptor');
  if (Array.isArray(value) || (object(value) && ('profiles' in value || 'installations' in value))) throw new Error('installation.ambiguous');
  if (!object(value) || value.schema !== 'murmur.installation/1' || typeof value.dataDir !== 'string'
    || typeof value.agentId !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(value.agentId)
    || typeof value.identityFingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(value.identityFingerprint)
    || Object.keys(value).some(key => !['schema', 'dataDir', 'agentId', 'identityFingerprint'].includes(key))) throw new Error('installation.descriptor-invalid');
  if (installationDataDir(value.dataDir, platform) !== value.dataDir) throw new Error('installation.descriptor-invalid');
  return value as unknown as InstallationDescriptor;
}

export function installationIdentity(dataDir: string): { agentId: string; identityFingerprint: string } {
  const profile = readDocument(path.join(dataDir, 'agent-config.json'), 'profile');
  const keys = object(profile) && object(profile.keys) ? profile.keys : null;
  const signing = keys && object(keys.signing) ? keys.signing.publicKey : null;
  const encryption = keys && object(keys.encryption) ? keys.encryption.publicKey : null;
  const validKey = (value: unknown) => typeof value === 'string' && Buffer.from(value, 'base64').length === 32
    && Buffer.from(value, 'base64').toString('base64') === value;
  if (!object(profile) || typeof profile.agentId !== 'string' || !validKey(signing) || !validKey(encryption)) throw new Error('installation.profile-invalid');
  return { agentId: profile.agentId, identityFingerprint: createHash('sha256').update(JSON.stringify([profile.agentId, signing, encryption])).digest('hex') };
}

/** Shared read-only resolution: explicit profile, agreeing environment, then one pinned descriptor. */
export function resolveInstallation(options: InstallationOptions = {}) {
  const env = options.env ?? process.env, platform = options.platform ?? process.platform;
  let value = options.dataDir, source: 'argument' | 'environment' | 'installation' = 'argument';
  let descriptor: InstallationDescriptor | null = null, descriptorFile: string | null = null;
  if (value === undefined) {
    source = 'environment';
    if (env.DATA_DIR !== undefined && env.MURMUR_DATA_DIR !== undefined
      && installationDataDir(env.DATA_DIR, platform) !== installationDataDir(env.MURMUR_DATA_DIR, platform)) throw new Error('config.data-dir-conflict');
    value = env.DATA_DIR ?? env.MURMUR_DATA_DIR;
  }
  if (value === undefined) {
    descriptorFile = installationFile(options);
    descriptor = readInstallationDescriptor(descriptorFile, platform);
    value = descriptor.dataDir; source = 'installation';
  }
  const dataDir = installationDataDir(value, platform);
  if (descriptor) {
    const identity = installationIdentity(dataDir);
    if (identity.agentId !== descriptor.agentId || identity.identityFingerprint !== descriptor.identityFingerprint) throw new Error('installation.identity-changed');
  } else if (options.requireConfig) {
    const profile = readDocument(path.join(dataDir, 'agent-config.json'), 'profile');
    if (!object(profile) || typeof profile.agentId !== 'string' || !profile.agentId) throw new Error('installation.profile-invalid');
  }
  return { dataDir, source, descriptorFile, descriptor };
}

/** Auxiliary environment paths must agree with the selected installation, never open another store. */
export function installationStorePath(dataDir: string, basename: string, override?: string): string {
  const expected = path.join(dataDir, basename);
  if (override !== undefined && (!path.isAbsolute(override) || path.normalize(override) !== expected)) throw new Error('installation.store-conflict');
  return expected;
}
