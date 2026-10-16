---
title: One explicit installation profile
status: implemented
updated: 2026-10-16
tags: [setup, profiles, compatibility]
---

# One explicit installation profile

The CLI, daemon and MCP server share one read-only profile resolver in `@murmurv2/core`. A working directory is never a profile selector. Missing or conflicting selection fails before a runtime opens a database; it does not create a new `.data` store with an empty contact list.

## Select once

For a new installation, explicitly choose its folder and register it during initialization:

```sh
murmur init --agent-id MY-AGENT --broker-url nats://server.example.com:4222 --data-dir /absolute/profile --select
murmur installation show --json
murmur status --json
murmur service install
murmur clients configure --client codex-cli
```

`join --data-dir /absolute/profile --select` registers a newly joined Identity in the same way. Existing `init` and `join` with an explicit `--data-dir` and without `--select` retain their previous behavior: they initialize only that profile and do not write an account-wide selection.

Register an already existing profile without moving files or changing its keys:

```sh
murmur installation select --data-dir /absolute/existing/profile --json
```

The descriptor contains `schema: "murmur.installation/1"`, the selected absolute `dataDir`, `agentId`, and a SHA-256 fingerprint of the agent ID and both E2E public keys. It contains no private key, broker credential or message. Setup writes it privately and atomically under a writer lock. The existing profile is validated first. Symlinks/hardlinks for the descriptor, foreign ownership, unsafe permissions and unexpected descriptor structures are refused.

## Resolution order

| Priority | Source | Behavior |
| --- | --- | --- |
| 1 | CLI `--data-dir ABSOLUTE` | Explicit multi-profile override for this command; does not change the descriptor |
| 2 | `DATA_DIR` or `MURMUR_DATA_DIR` | Absolute explicit profile; if both exist, they must agree |
| 3 | One installation descriptor | Verify its identity fingerprint against the existing selected profile |
| Missing | No explicit profile and no descriptor | Fail with `installation.descriptor-missing` and initialization/selection instructions |

An empty or relative profile value is an error, not permission to fall back. Paths use the platform's lexical separator normalization; filesystem aliases are **not** resolved. A selected symlink path retains the same path-derived service name as before. Trailing separators remain refused so they cannot silently select another service.

`installation show` reports the registered descriptor even if an ambient `DATA_DIR` overrides ordinary commands. `installation select` always requires an explicit `--data-dir`; it never chooses an arbitrary running daemon.

## Discoverable descriptor

| Platform | Default file |
| --- | --- |
| Linux | `$XDG_CONFIG_HOME/murmur/installation.json`, otherwise `~/.config/murmur/installation.json` |
| macOS | `~/Library/Application Support/Murmur/installation.json` |
| Windows | `%LOCALAPPDATA%\Murmur\installation.json`, otherwise `%USERPROFILE%\AppData\Local\Murmur\installation.json` |

`MURMUR_INSTALLATION_FILE` selects an explicit absolute descriptor for all consumers. CLI `--installation-file ABSOLUTE` selects it for that command, including `init --select`, `join --select`, `installation show` and `installation select`. No descriptor directory is scanned and arrays of candidate profiles are rejected as `installation.ambiguous`.

The descriptor is account-private: mode 0600 on POSIX, protected creator-and-SYSTEM ACL on Windows. An interactive account never guesses the installation of another account. Services do not depend on discovering a descriptor through their service account's home directory: setup writes the selected absolute profile and derived store paths directly into systemd/launchd definitions and Windows service launch state. Generated MCP entries are pinned the same way.

## Existing consumers remain pinned

> [!IMPORTANT]
> Changing the registered default does not move, stop or reconfigure existing services, client entries or running processes. The result says `existingConsumersChanged: false`. Those consumers retain the explicit profile for which they were configured. To move one, explicitly configure/install it for the newly selected profile and verify its reply.

Replacing a different registered selection requires `installation select --data-dir ABSOLUTE --replace`. Profile/identity conflicts are checked before `init --select` creates a second Identity. If a later filesystem failure prevents saving the descriptor after initialization, the newly initialized private profile remains recoverable; select that existing folder again rather than generating new keys.

The daemon and MCP process pin their resolved choice in their own environment for child hooks. Changing the descriptor while they run cannot redirect their subprocesses to a different profile. A conflicting `MURMUR_STORE_PATH` or `MURMUR_CHANNEL_ROSTER_PATH` is refused instead of silently opening a foreign store. New service and client configuration writes both data-directory names and matching derived store paths, so unrelated ambient overrides cannot redirect them. An explicit channel-roster path already stored in daemon configuration retains its separate existing semantics.

## Legacy migration and compatibility

Earlier raw daemon and MCP commands could use `.data` relative to the current directory. That fallback is removed. No store is scanned, renamed, merged or created as a migration. From any directory, point at the known old absolute profile:

```sh
murmur installation select --data-dir /absolute/old-checkout/.data
```

Then launch the CLI, daemon or MCP server from any working directory. Alternatively keep supplying the explicit absolute `DATA_DIR`, which continues to override the default. Existing desktop integrations and service/client definitions that already supply an absolute profile keep using it. Old relative environment values now fail with an actionable absolute-path error.

The shared resolver also covers the packaged standalone shell sender and the legacy advisory channel MCP process. Specialized repository maintenance scripts that require their own explicit arguments are not converted into automatic discovery; use their documented explicit paths. Python send-boundary services continue to require their explicitly configured `DATA_DIR`.

If the registered folder is removed, its agent ID changes, or either public key changes, runtime startup fails. Select the intended existing profile explicitly after inspecting the change; do not treat a new Identity in the same directory as the old one. Broken or ambiguous descriptors require manual inspection; `--replace` is not a general overwrite permission for arbitrary files.

## Verification

`tests/setup-installation.test.mjs` exercises descriptor paths for all three operating systems, private selection, explicit multi-profile overrides, migration without changed bytes, unchanged alias-derived service names, missing/stale/ambiguous/conflicting state, source-key changes, access/link refusal, and refusal before a conflicting initialization.

The runtime acceptance starts real CLI and MCP processes from two unrelated directories, reads the same synthetic inbox marker and checks that no relative store appears. A separate isolated NATS daemon test confirms the selected Identity and database from another directory. Missing descriptor and conflicting store launches fail before creating a store. Existing Linux/Darwin/Windows service tests check the explicit pinned profile. Linux execution and generated Windows paths alone do not establish native Windows ACL behavior; the required native CI runs the same setup corpus.
