import * as TOML from '@iarna/toml';
import { constants } from 'node:fs';
import { lstat, mkdir, open, rename, rmdir, stat, unlink } from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import type { ClientDetection, PlatformAdapter, ServiceContext } from './types.js';
import { loadConfig } from './config.js';
import { sameClientFileIdentity } from './file-identity.js';
import { protectPrivateFile, preparePrivateReplacement } from './private-file.js';
export { sameClientFileIdentity } from './file-identity.js';
const object = (value: unknown): value is Record<string, any> => !!value && typeof value === 'object' && !Array.isArray(value);

async function selectedClient(c: ServiceContext, adapter: PlatformAdapter, clientId: string) {
  const clients = await adapter.detectClients(c);
  const client = clients.find(item => item.id === clientId);
  if (!client || !client.installed) throw new Error('client.not-detected');
  if (!client.configPath || !path.isAbsolute(client.configPath)) throw new Error('client.config-path-unverified');
  if (c.clientProjectDir) {
    if (clientId !== 'claude-code') throw new Error('client.project-only-for-claude-code');
    if (!path.isAbsolute(c.clientProjectDir) || !(await stat(c.clientProjectDir).catch(() => null))?.isDirectory()) throw new Error('client.project-directory-required');
    // An inherited global/ancestor hook would still wake other chats. Refuse before
    // writing anything; never silently remove a person's existing integration.
    const parents = new Set([path.dirname(client.configPath)]);
    let parent = path.dirname(c.clientProjectDir);
    while (true) { parents.add(parent); const next = path.dirname(parent); if (next === parent) break; parent = next; }
    // Local settings merge their hooks with project settings. They must not leave
    // a second reader behind even in the selected project itself.
    const local = await readClientFile(path.join(c.clientProjectDir, '.claude', 'settings.local.json'));
    if (local.text.includes('wake-drain-claude')) throw new Error('client.inherited-wake-hook-conflict');
    for (const dir of parents) {
      if (dir === c.clientProjectDir) throw new Error('client.project-must-be-dedicated');
      for (const name of ['settings.json', 'settings.local.json']) {
        const file = await readClientFile(path.join(dir, '.claude', name));
        if (file.text.includes('wake-drain-claude')) throw new Error('client.inherited-wake-hook-conflict');
      }
    }
    // Desktop forwards Chat/user MCP registrations ahead of project entries.
    // Refuse an occupied dedicated name instead of selecting a global identity.
    for (const global of clients.filter(item => ['claude-code', 'claude-desktop'].includes(item.id))) {
      if (!global.configPath || !path.isAbsolute(global.configPath)) continue;
      const file = await readClientFile(global.configPath);
      const { original, key } = clientDocument(global, file.text);
      if (original[key]?.[mcpEntryName(c)] !== undefined) throw new Error('client.inherited-mcp-entry-conflict');
    }
    return { ...client, configPath: path.join(c.clientProjectDir, '.mcp.json') };
  }
  return { ...client, configPath: client.configPath };
}
async function readClientFile(file: string) {
  let handle;
  try {
    // O_NOFOLLOW is unavailable on Windows. Inspect the link itself there too,
    // including dangling links, and bind the opened handle to the checked file.
    const before = await lstat(file, { bigint: true });
    if (!before.isFile()) throw new Error('client.config-file-invalid');
    handle = await open(file, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
    const info = await handle.stat({ bigint: true });
    const after = await lstat(file, { bigint: true });
    if (!info.isFile() || !after.isFile() || !sameClientFileIdentity(before, info)
      || !sameClientFileIdentity(after, info) || !sameClientFileIdentity(before, after) || info.size > 4n * 1024n * 1024n
      || (process.getuid && info.uid !== BigInt(process.getuid()))) throw new Error('client.config-file-invalid');
    return { text: await handle.readFile('utf8'), existed: true };
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === 'ENOENT') return { text: '', existed: false };
    throw e;
  } finally { await handle?.close(); }
}
function clientDocument(client: ClientDetection, text: string) {
  const parse = (value: string): Record<string, any> => {
    try {
      const result = value.trim() ? client.format === 'json' ? JSON.parse(value) : TOML.parse(value) : {};
      if (!object(result)) throw new Error();
      return result;
    } catch { throw new Error('client.config-parse-failed'); }
  };
  const original = parse(text), key = client.format === 'json' ? 'mcpServers' : 'mcp_servers';
  if (original[key] !== undefined && !object(original[key])) throw new Error('client.mcp-table-invalid');
  return { original, key, parse };
}
// Claude Code reads hooks from settings.json next to its config directory, not from ~/.claude.json.
const claudeSettingsPath = (configPath: string) => path.join(path.dirname(configPath), '.claude', 'settings.json');
// Forward slashes read the same in the bash and cmd that run hook commands; node accepts them.
const hookPath = (value: string) => `"${value.replaceAll('\\', '/')}"`;
// Eight hours after each turn instead of the drain's 20-minute default: a message that arrives
// during a working day still wakes the session (docs/wake-native.md, known limitation).
const WAKE_WINDOW_SECONDS = 28800;
const projectLane = (c: ServiceContext) => c.clientProjectDir
  ? createHash('sha256').update(c.clientProjectDir).digest('hex').slice(0, 8) : null;
const mcpEntryName = (c: ServiceContext) => c.clientProjectDir ? `murmur-${projectLane(c)}` : 'murmur';
/** The node wake drain (docs/wake-native.md): polls the store after each turn and wakes the session. */
function desiredWakeHook(c: ServiceContext) {
  // Claude Code ends a hook without its own `timeout` after 600 s (hooks reference, asyncRewake);
  // the entry carries the same window the drain script is asked for, or the script never gets it.
  const lane = projectLane(c);
  return { type: 'command', asyncRewake: true, timeout: WAKE_WINDOW_SECONDS,
    command: `${hookPath(c.nodePath)} --no-warnings ${hookPath(path.join(c.repoRoot, 'scripts', 'wake-drain-claude.mjs'))} --db ${hookPath(c.storePath)} --max-seconds ${WAKE_WINDOW_SECONDS}${lane ? ` --session-key ${lane}` : ''}` };
}
const isMurmurWakeHook = (hook: unknown): hook is Record<string, any> & { command: string } =>
  object(hook) && typeof hook.command === 'string' && hook.command.includes('wake-drain-claude');
const wakeGroups = (value: unknown): value is Array<Record<string, any>> =>
  Array.isArray(value) && value.every(group => object(group) && Array.isArray(group.hooks));
// The drain path inside a hook command, quoted or bare. Outside Stop it is the only part we
// rewrite, so flags and timeouts a person chose keep working.
const wakeScript = /"[^"]*wake-drain-claude[^"]*"|[^\s"]*wake-drain-claude[^\s"]*/;
const wakeScriptOf = (command: string) => command.match(wakeScript)?.[0].replaceAll('"', '').replaceAll('\\', '/');
/**
 * Plan the Stop hook edit; only Murmur's own wake hook is ever added, kept or replaced.
 * Hooks under other events keep their own flags and are only repointed at the script this
 * runtime ships, so one settings file never runs two versions of the drain against the same
 * session cursors (#294). Their events are reported, because they were written by hand.
 */
function planWakeHook(c: ServiceContext, text: string) {
  let settings: Record<string, any>;
  try { settings = text.trim() ? JSON.parse(text) : {}; } catch { throw new Error('client.settings-parse-failed'); }
  if (!object(settings) || (settings.hooks !== undefined && !object(settings.hooks))
    || (settings.hooks?.Stop !== undefined && !wakeGroups(settings.hooks.Stop))) throw new Error('client.hooks-invalid');
  const entry = desiredWakeHook(c), groups: Array<Record<string, any>> = settings.hooks?.Stop ?? [];
  const ours = groups.flatMap(group => group.hooks.filter(isMurmurWakeHook));
  const drain = path.join(c.repoRoot, 'scripts', 'wake-drain-claude.mjs');
  const installed = drain.replaceAll('\\', '/');
  // An event we cannot read as hook groups is left alone entirely: it is not ours to reshape.
  const others = Object.entries(settings.hooks ?? {}).filter(([event, value]) => event !== 'Stop' && wakeGroups(value));
  const repointed = others.filter(([, value]) => (value as Array<Record<string, any>>)
    .some(group => group.hooks.some((hook: unknown) => isMurmurWakeHook(hook) && wakeScriptOf(hook.command) !== installed)))
    .map(([event]) => String(event));
  if (ours.length === 1 && isDeepStrictEqual(ours[0], entry) && !repointed.length) {
    return { action: 'unchanged' as const, next: settings, repointed };
  }
  const kept = groups.map(group => ({ ...group, hooks: group.hooks.filter((hook: unknown) => !isMurmurWakeHook(hook)) })).filter(group => group.hooks.length);
  const hooks: Record<string, any> = { ...settings.hooks, Stop: [...kept, { hooks: [entry] }] };
  for (const [event, value] of others) {
    if (!repointed.includes(event)) continue;
    hooks[event] = (value as Array<Record<string, any>>).map(group => ({ ...group, hooks: group.hooks.map((hook: unknown) =>
      isMurmurWakeHook(hook) ? { ...hook, command: hook.command.replace(wakeScript, hookPath(drain)) } : hook) }));
  }
  const next = { ...settings, hooks };
  return { action: ours.length || repointed.length ? 'replace' as const : 'add' as const, next, repointed };
}
/** Write settings.json the same guarded way as the MCP entry: lock, private backup, atomic rename. */
async function configureWakeHook(c: ServiceContext, file: string, before: Awaited<ReturnType<typeof readClientFile>>) {
  await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const lock = `${file}.murmur-lock`;
  await mkdir(lock, { mode: 0o700 });
  try {
    const current = await readClientFile(file);
    if (!isDeepStrictEqual(current, before)) throw new Error('client.plan-stale');
    const { action, next, repointed } = planWakeHook(c, current.text);
    if (action === 'unchanged') return { settingsPath: file, action, changed: false, backup: null, repointed };
    const serialized = JSON.stringify(next, null, 2) + '\n';
    const backup = current.existed ? `${file}.murmur-backup-${randomUUID()}` : null;
    if (backup) {
      const out = await open(backup, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
      try { await protectPrivateFile(backup, out); await out.writeFile(current.text); await out.sync(); } finally { await out.close(); }
    }
    const temporary = `${file}.murmur-${randomUUID()}.tmp`;
    try {
      const out = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
      try { await preparePrivateReplacement(temporary, out, file); await out.writeFile(serialized); await out.sync(); } finally { await out.close(); }
      if (!isDeepStrictEqual(await readClientFile(file), current)) throw new Error('client.plan-stale');
      await rename(temporary, file);
    } finally { await unlink(temporary).catch(() => {}); }
    return { settingsPath: file, action, changed: true, backup, repointed };
  } finally { await rmdir(lock); }
}
function desiredEntry(c: ServiceContext) {
  const lane = projectLane(c);
  return { command: c.nodePath, args: [path.join(c.repoRoot, 'packages', 'mcp-server', 'dist', 'src', 'index.js')],
    env: { DATA_DIR: c.dataDir, MURMUR_STORE_PATH: c.storePath,
      ...(lane ? { MURMUR_WAKE_SESSION_KEY: lane } : {}) } };
}
type ClientFile = Awaited<ReturnType<typeof readClientFile>>;
function mcpChange(c: ServiceContext, original: Record<string, any>, key: string) {
  const entry = desiredEntry(c), name = mcpEntryName(c), previous = original[key]?.[name];
  const servers = { ...original[key] }, legacy = servers.murmur;
  // Only migrate the old project registration for this exact profile. Other
  // servers and identities remain intact, and replacement keeps a raw backup.
  const legacyOwned = !!c.clientProjectDir && object(legacy) && object(legacy.env)
    && legacy.env.DATA_DIR === c.dataDir && legacy.env.MURMUR_STORE_PATH === c.storePath
    && typeof legacy.command === 'string' && Array.isArray(legacy.args) && legacy.args.length === 1
    && typeof legacy.args[0] === 'string' && /[/\\]packages[/\\]mcp-server[/\\]dist[/\\]src[/\\]index\.js$/.test(legacy.args[0]);
  if (legacyOwned) delete servers.murmur;
  servers[name] = entry;
  const action = legacyOwned ? 'replace' : isDeepStrictEqual(previous, entry) ? 'unchanged' : previous === undefined ? 'add' : 'replace';
  return { entry, name, action, next: { ...original, [key]: servers } };
}
async function planFor(c: ServiceContext, client: ClientDetection & { configPath: string }, current: ClientFile, settings?: ClientFile) {
  const config = await loadConfig(c), { original, key } = clientDocument(client, current.text);
  const { entry, name, action: entryAction } = mcpChange(c, original, key);
  const plannedHook = settings && planWakeHook(c, settings.text);
  // The preview names the hand-written events it would repoint, so the person reads them before
  // confirming rather than finding a changed command afterwards (#294).
  const wakeHook = plannedHook && { settingsPath: claudeSettingsPath(client.configPath), action: plannedHook.action,
    ...(plannedHook.repointed.length ? { repointed: plannedHook.repointed } : {}) };
  // The plan's action speaks for both files: an app that sees 'replace' asks the person and
  // passes --replace, so a Stop hook written by an earlier version (no timeout, #273) is
  // upgraded instead of failing with client.wake-hook-conflict while the MCP entry is unchanged.
  const action = wakeHook?.action === 'replace' ? 'replace' : entryAction === 'unchanged' && wakeHook?.action === 'add' ? 'add' : entryAction;
  // Bind confirmation to the target, exact bytes and selected identity/runtime.
  // No existing commands, environment values, auth or config contents leave the engine.
  const planId = createHash('sha256').update(JSON.stringify([client.id, client.configPath, current,
    config.agentId, config.keys.signing.publicKey, config.keys.encryption.publicKey, name, entry, settings ?? null])).digest('hex');
  return { schema: 'murmur.client-plan/1', client: client.id, configPath: client.configPath,
    agentId: config.agentId, dataDir: c.dataDir, serverName: name, action, planId, configExisted: current.existed, restartRequired: true, ...(wakeHook ? { wakeHook } : {}) };
}

/**
 * Read-only: what Claude Code carries for this profile, for doctor's wake stage (#293).
 * `current` means the installed Stop hook is exactly the one this runtime writes; it says
 * nothing about a live session having been woken, which is a separate proof.
 */
export async function claudeWakeHookState(c: ServiceContext, adapter: PlatformAdapter): Promise<'current' | 'outdated' | 'absent'> {
  const client = await selectedClient(c, adapter, 'claude-code').catch(() => null);
  if (!client?.configPath) return 'absent';
  const settings = await readClientFile(claudeSettingsPath(client.configPath)).catch(() => null);
  if (!settings?.existed) return 'absent';
  let parsed: unknown;
  try { parsed = settings.text.trim() ? JSON.parse(settings.text) : {}; } catch { return 'absent'; }
  if (!object(parsed) || !object(parsed.hooks) || !wakeGroups(parsed.hooks.Stop)) return 'absent';
  // One settings file serves every profile on the machine, so only a hook that names this
  // profile's store says anything about this doctor run; another profile's is not ours to judge.
  const ours = parsed.hooks.Stop.flatMap(group => group.hooks.filter(isMurmurWakeHook))
    .filter(hook => hook.command.includes(hookPath(c.storePath)));
  if (!ours.length) return 'absent';
  return ours.some(hook => isDeepStrictEqual(hook, desiredWakeHook(c))) ? 'current' : 'outdated';
}

/** Read-only preview: even a missing parent directory is not created. */
export async function previewClientConfiguration(c: ServiceContext, adapter: PlatformAdapter, clientId: string) {
  const client = await selectedClient(c, adapter, clientId);
  const settings = client.id === 'claude-code' ? await readClientFile(claudeSettingsPath(client.configPath)) : undefined;
  return planFor(c, client, await readClientFile(client.configPath), settings);
}

/**
 * Patch only the selected Murmur entry; never execute a client or touch its auth. For Claude Code
 * also install the Stop wake hook, so a delivered message wakes the session without a human turn.
 */
export async function configureClient(c: ServiceContext, adapter: PlatformAdapter, clientId: string, replace = false, expectedPlan?: string) {
  const client = await selectedClient(c, adapter, clientId);
  if (expectedPlan !== undefined && !/^[a-f0-9]{64}$/.test(expectedPlan)) throw new Error('client.plan-invalid');
  if (client.id !== 'claude-code') return configureMcpEntry(c, client, replace, expectedPlan);
  const settingsFile = claudeSettingsPath(client.configPath), settings = await readClientFile(settingsFile);
  // A hook must never point at a file this runtime does not ship (an older or partial bundle).
  const drain = await stat(path.join(c.repoRoot, 'scripts', 'wake-drain-claude.mjs')).catch(() => null);
  if (!drain?.isFile()) throw new Error('client.wake-drain-missing');
  // Refuse a foreign variant of the hook before anything is written, as for the MCP entry.
  if (planWakeHook(c, settings.text).action === 'replace' && !replace) throw new Error('client.wake-hook-conflict');
  const result = await configureMcpEntry(c, client, replace, expectedPlan, settings);
  const wakeHook = await configureWakeHook(c, settingsFile, settings);
  return { ...result, changed: result.changed || wakeHook.changed, wakeHook };
}
async function configureMcpEntry(c: ServiceContext, client: ClientDetection & { configPath: string }, replace: boolean, expectedPlan?: string, settings?: ClientFile) {
  const clientId = client.id, file = client.configPath;
  await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const lock = `${file}.murmur-lock`;
  await mkdir(lock, { mode: 0o700 });
  try {
    const current = await readClientFile(file), { text, existed } = current;
    const plan = expectedPlan === undefined ? undefined : await planFor(c, client, current, settings);
    if (plan && plan.planId !== expectedPlan) throw new Error('client.plan-stale');
    const { original, key, parse } = clientDocument(client, text);
    const { name, action, next } = mcpChange(c, original, key);
    const confirmed = { ...(plan ? { planId: plan.planId, agentId: plan.agentId, dataDir: plan.dataDir } : {}), serverName: name };
    if (action === 'unchanged') return { schema: 'murmur.client/1', client: clientId, configPath: file, changed: false, backup: null, restartRequired: true, ...confirmed };
    if (action === 'replace' && !replace) throw new Error('client.murmur-entry-conflict');
    const serialized = client.format === 'json' ? JSON.stringify(next, null, 2) + '\n' : TOML.stringify(next);
    if (!isDeepStrictEqual(parse(serialized), next)) throw new Error('client.config-roundtrip-failed');
    const backup = existed ? `${file}.murmur-backup-${randomUUID()}` : null;
    if (backup) {
      const out = await open(backup, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
      try { await protectPrivateFile(backup, out); await out.writeFile(text); await out.sync(); } finally { await out.close(); }
    }
    const temporary = `${file}.murmur-${randomUUID()}.tmp`;
    try {
      const out = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
      try { await preparePrivateReplacement(temporary, out, file); await out.writeFile(serialized); await out.sync(); } finally { await out.close(); }
      // A client can save its config while the confirmation window is open or
      // while we prepare the backup. Refuse a changed target instead of losing it.
      if (!isDeepStrictEqual(await readClientFile(file), current)) throw new Error('client.plan-stale');
      if (plan && (await planFor(c, client, current, settings)).planId !== plan.planId) throw new Error('client.plan-stale');
      await rename(temporary, file);
    } finally { await unlink(temporary).catch(() => {}); }
    return { schema: 'murmur.client/1', client: clientId, configPath: file, changed: true, backup, ...confirmed,
      restartRequired: true, instruction: 'Reload the selected client to activate the Murmur MCP entry.' };
  } finally { await rmdir(lock); }
}
