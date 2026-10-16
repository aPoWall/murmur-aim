---
title: Setup backup retention
status: implemented
updated: 2026-10-16
tags: [setup, recovery, security]
---

# Setup backup retention

Setup saves private recovery copies before changing an Identity or an existing client configuration. They contain long-lived private keys, Server credentials or client settings. They are not ordinary logs. No upgrade, daemon timer, initialization or configuration command removes existing copies.

## Policy

Cleanup is explicit and scoped to one source file. It keeps **every copy from the last 30 days**, **at least the five newest copies**, and every copy the person names with `--keep-file`. The cutoff is midnight UTC, so the recovery window is never shorter than 30 days. A source with fewer than five copies keeps all of them. The current source file is never a deletion target.

| Kind | Scope | Recognized names |
| --- | --- | --- |
| `agent` | Selected `--data-dir` | `agent-config.backup-<UUID-v4>.json` |
| `client` | One explicit `--config-file` JSON or TOML file | `<config-file>.murmur-backup-<UUID-v4>` |

Claude's MCP configuration and its separate settings file are two sources: preview and clean each separately. Service definition backups, manually named recovery files, other profiles, databases and unrelated files are outside this command. Files are never found through a recursive scan or a user-supplied glob.

This is a recovery window, not a lifetime cap: recent copies may exceed five, and no space is reclaimed until a person runs cleanup. Review the preview before each cleanup. Use `--keep-file` for any older restore point still needed; it is an option for that preview/cleanup pair, not persistent metadata.

## Preview, then clean

```sh
murmur backups preview --kind agent --data-dir /absolute/profile --json
murmur backups cleanup --kind agent --data-dir /absolute/profile --plan-id COPIED_PLAN_ID --json

murmur backups preview --kind client --config-file /absolute/client/config.toml --json
murmur backups cleanup --kind client --config-file /absolute/client/config.toml --plan-id COPIED_PLAN_ID --json
```

The preview lists exact canonical paths, sizes, modification times and `keep`/`remove` decisions with reasons. It never emits backup contents. To retain an additional recovery point, repeat preview with `--keep-file /exact/path/from/preview`, then pass that same option to cleanup. The option can be repeated.

> [!IMPORTANT]
> Keep the original configuration private when restoring it. Before cleanup, verify that the current Identity/client configuration works. Copies outside the retention window are permanently unlinked; this command does not securely erase storage blocks or delete off-device copies.

`planId` binds the selected source, current bytes, backup names and bytes, file identities, ownership, permissions, timestamps and keep decisions. It expires at the next UTC midnight. A changed source, new backup, replacement file, changed contents (even with restored modification time) or changed selection requires a new preview. Supplying a different digest cannot authorize a different deletion set.

## Refusals and recovery

Preview is read-only and never creates a profile or repairs permissions. Cleanup takes the same source lock as setup writers. Symlinks, hardlinks, malformed documents, foreign owners, unexpectedly public backups, and writable-by-others POSIX source directories are refused. POSIX backups must have no group/other permissions; Windows backups must retain the protected creator-and-SYSTEM ACL that setup writes. Permissions on existing files are never changed by this command.

The current source must exist and parse successfully. If it is missing or broken, restore/repair it first; cleanup does not guess which copy is the only useful recovery point. A matching unsafe or malformed backup also stops the operation for investigation. An existing writer lock is preserved, not force-removed.

If a filesystem error occurs after one deletion, already removed files cannot be rolled back. Inspect a new preview before retrying; the prior digest no longer matches. Unrelated files and retained recovery points are never intentionally removed. The command protects against stale plans and cooperative concurrent writers; it is not a sandbox against another process with the same account privileges replacing directory entries between system calls.

## Migration and acceptance

The filename formats and private permissions are unchanged. Existing copies remain in place until an explicit preview and matching cleanup. There is no background migration or new persistent retention state.

`tests/setup-backups.test.mjs` covers agent, JSON and TOML scopes; the minimum recovery count and age window; explicitly retained points; stale source/content/mtime/day snapshots; unchanged unrelated files and current configurations; private retained copies; locks; malformed/private-access refusal; and link refusal. Native Windows CI exercises the ACL checks; Linux-only execution is not evidence of Windows ACL acceptance.
