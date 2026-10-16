import { readdir, readFile, lstat } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import type { ServiceContext } from './types.js';
const run = promisify(execFile);

/** A lock alone is not a live reader. Verify its PID and the drain's selected DB.
 * Unknown process inspection stays unknown; this never deletes stale locks. */
export async function readWakeReaders(c: ServiceContext, home = homedir()) {
  const measuredAt = new Date().toISOString();
  const unknown = (reason: string) => ({ active: null as number | null, measuredAt, unknownReason: reason });
  if (!['linux', 'darwin'].includes(process.platform)) return unknown('wake.readers-platform-unavailable');
  const store = path.resolve(c.storePath);
  const key = createHash('sha256').update(store).digest('hex').slice(0, 8);
  let files: string[];
  try { files = (await readdir(home)).filter(name => new RegExp(`^\\.murmur-wake-lock-${key}(?:-[A-Za-z0-9_-]{1,8})?$`).test(name)); }
  catch { return unknown('wake.readers-directory-unavailable'); }
  let active = 0;
  for (const name of files) {
    const file = path.join(home, name);
    try {
      const info = await lstat(file);
      if (!info.isFile() || info.size > 64) return unknown('wake.reader-lock-unverified');
      const raw = await readFile(file, 'utf8'), pid = Number(raw.trim());
      if (!Number.isSafeInteger(pid) || pid <= 0) return unknown('wake.reader-lock-unverified');
      try { process.kill(pid, 0); } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ESRCH') continue;
        return unknown('wake.reader-process-unavailable');
      }
      let matches = false;
      if (process.platform === 'linux') {
        const args = (await readFile(`/proc/${pid}/cmdline`, 'utf8')).split('\0');
        matches = args.some(arg => arg.endsWith('/wake-drain-claude.mjs'))
          && args[args.indexOf('--db') + 1] === store;
      } else {
        const { stdout } = await run('/bin/ps', ['-p', String(pid), '-o', 'command='], { timeout: 2000, maxBuffer: 32768 });
        matches = stdout.includes('/wake-drain-claude.mjs ') && stdout.includes(`--db ${store} `);
      }
      if (await readFile(file, 'utf8') !== raw) return unknown('wake.reader-lock-changed');
      if (!matches) return unknown('wake.reader-process-unverified');
      active++;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') return unknown('wake.reader-inspection-failed');
      // The reader can finish between listing its lock and inspecting the process.
    }
  }
  return { active, measuredAt, unknownReason: null };
}
