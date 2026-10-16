import path from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { accessSync, constants, realpathSync } from "node:fs";
import type { ServiceContext } from "./types.js";
import { resolveInstallation } from '@murmurv2/core';

/** Homebrew resolves process.execPath into a versioned Cellar. Persist a stable
 * executable only when it is executable and resolves to this very same Node. */
export function stableNodeExecutable(executable: string, platform: NodeJS.Platform = process.platform,
  inspect = (candidate: string) => { accessSync(candidate, constants.X_OK); return realpathSync(candidate); }): string {
  if (platform !== "darwin") return executable;
  const brew = /^(\/opt\/homebrew|\/usr\/local)\/Cellar\/(node(?:@\d+)?)\/[^/]+\/bin\/node$/.exec(executable);
  if (!brew) return executable;
  const [, prefix, formula] = brew;
  const candidates = formula === "node" ? [`${prefix}/bin/node`, `${prefix}/opt/node/bin/node`]
    : [`${prefix}/opt/${formula}/bin/node`];
  for (const candidate of candidates) {
    try { if (inspect(candidate) === executable) return candidate; } catch { /* missing or different installation */ }
  }
  return executable;
}

export function resolveContext(options: { dataDir?: string; repoRoot?: string; nodePath?: string; serviceName?: string;
  platform?: NodeJS.Platform; home?: string; env?: NodeJS.ProcessEnv; installationFile?: string; clientProjectDir?: string } = {}): ServiceContext {
  const env = options.env ?? process.env;
  const platform = options.platform ?? process.platform;
  const home = options.home ?? homedir();
  const paths = platform === "win32" ? path.win32 : path.posix;
  const { dataDir } = resolveInstallation({ ...options, platform, home, env });
  const repoRoot = paths.normalize(options.repoRoot ?? fileURLToPath(new URL("../../../../", import.meta.url))).replace(/[\\/]$/, "");
  const nodePath = paths.normalize(options.nodePath ?? stableNodeExecutable(process.execPath, platform));
  if (!paths.isAbsolute(repoRoot) || !paths.isAbsolute(nodePath)) throw new Error("config.runtime-path-must-be-absolute");
  const serviceName = options.serviceName ?? `murmur-${createHash("sha256").update(dataDir).digest("hex").slice(0, 12)}`;
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$/.test(serviceName)) throw new Error("config.invalid-service-name");
  const clientProjectDir = options.clientProjectDir;
  if (clientProjectDir !== undefined && (!paths.isAbsolute(clientProjectDir) || paths.normalize(clientProjectDir) !== clientProjectDir
    || /[\x00-\x1f\x7f]/.test(clientProjectDir))) throw new Error("client.project-path-invalid");
  return { dataDir, repoRoot, nodePath, serviceName, configPath: paths.join(dataDir, "agent-config.json"),
    storePath: paths.join(dataDir, "murmur.db"), logDir: paths.join(dataDir, "logs"),
    ...(clientProjectDir !== undefined ? { clientProjectDir } : {}) };
}
