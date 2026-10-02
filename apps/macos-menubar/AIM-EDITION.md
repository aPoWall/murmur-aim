# Murmur AIM · N1 · build 1

Personal macOS edition of alexfrmn/murmur. Upstream engine 2.12.0; MIT attribution
and transport remain intact. The fork adds the AIM Native White shell, with MEM
PRISM as the visual reference. The stock Mac app was not installed previously.

## Current design: N1

White canvas, Plex Mono 400/500/600 bundled with OFL, 8 pt controls, 16 pt spacing,
neutral navigation with a small red indicator. Header, tabs, pin, footer and
surface use the shared AIM components vendored byte-for-byte; hashes live in
`aim-shared-receipt.json`. The existing AIM family mark identifies this personal
edition; there is no new suite-wide glyph. Menu bar: 18 pt template mark; header:
family voxel; Dock/Finder: the same family mark on a white tile.

Primary profile is N1 operator. Desktop-only fixed 740 pt width, resizable height;
mobile is not applicable. The underlying pairing, language, preferences, service,
client connection, doctor and update flows stay upstream. Settings remains a
header action. The shared surface handles Escape, Command-W, close, outside click
and menu-bar toggle; pin keeps the window open. Existing Ctrl-Option-Command-M
shortcut is retained and avoids MEM PRISM's Option-Command-M.

The app has its own bundle/preferences identity, `org.aimindset.murmur`. It does
not copy keys, create a new identity on launch, register at login, change MCP
settings or take ownership of VM105 agent-sasha. An existing local profile can be
chosen through upstream's verified recovery flow. Remote VM105 conversations
continue through the existing monitor; this app does not provide an SSH backend.

## Build

Download `murmur-runtime-2.12.0.zip` from the upstream release, verify its SHA256
against the upstream `SHA256SUMS.txt`, extract it, then run:

```
bash apps/macos-menubar/packaging/build-aim.sh /absolute/path/to/runtime
```

Requires Swift 6 and external Node 22.13+. Builds the current host architecture,
checks the shared fixtures, verifies the runtime file manifest, and ad-hoc signs
`apps/macos-menubar/dist/Murmur AIM.app`. It is a local build, not notarized.

Install with `ditto` into an unoccupied `~/Applications/Murmur AIM.app`. Preserve
an existing app before upgrading; never overwrite an occupied installation blindly.
Launch normally to open the window, or `open -g ... --args --background` to start
with just the menu bar. The latter keeps the owner's meeting focus unchanged.

Offscreen preview, without profile/network activity:

```
MurmurMenuBar --aim-render /absolute/path/preview.png
```

`--demo` optionally exercises the upstream labelled demo state. Preview never
shows a window or registers the shortcut. Shared first-appearance motion follows
Reduce Motion. Real pairing, reboot/login and automatic assistant wake are not
claimed by these fixture/offscreen checks.

Upstream release updates open the upstream page. They do not rebuild the AIM
edition; rebuild this fork to retain the customization.


## AIM 2 – server companion, 2026-09-29

The default Overview reads an owner-only projection over the existing `ws-povalyaev` SSH alias, once per minute while running. It uses `~/mesh-comms/companion.py` from team-ai-infrastructure. No daemon, timer, local identity, broker key or responder is created. Profile onboarding remains in Local.

The server retains delivery and native WakeMonitor ownership. A live systemd service is displayed independently from the dated budget receipt. Unknown/stale data remains visibly stale. People show observed message dates, not online presence. Alex decisions and incoming review candidates are separate counts.

Opt-in macOS notifications contain counts only, use a quiet first baseline and persisted SHA-256 event fingerprints. The app keeps people/questions in memory. It opens the private dashboard, topic deep links and the dedicated Vasiliev–JARVIS Codex session; it does not copy session context or choose a responder from the foreground app.

Prerequisites: existing SSH alias and host trust, Tailscale, server projection. A failed SSH read times out after 20 seconds and cannot start a second overlapping read. UI refresh uses no model calls. Disconnect stops only this app's read loop.

Runtime remains upstream 2.12.0; AIM shell edition 2. The local app and source are an AIM fork, not a second server deployment.

## AIM 3 · 2026-10-02

People is a dedicated server roster with initials, verified nicknames and exact agent IDs.
The English interface is the default; Russian remains selectable. Original message and
question text keeps its source language. Danik (zima blue / agent-danik) is distinct from
Alexander Vasiliev (JARVIS / agent-jarvis and SOTNIK / aim-codex).

Write message sends only after the user presses Send message, through the existing
SSH identity to the owner-only `mesh-comms/send.py` helper. A stable UUID is retained
for the attempt. Uncertain results expose Check delivery without silently resending.
The helper validates current peer configuration, excludes retired/private profiles,
adds human attribution and uses the upstream idempotent encrypted sender. Queued,
acked and answered are different states. No message body enters an HTTP endpoint.
No real outbound messages are sent by the test suite.

The existing server timer collects every two minutes. The app reads every minute
while open, with a quiet first notification baseline. Model responders remain subject
to the budget guard. Keep one Telegram bot poller: the existing owner-only bridge accepts
`/to agent-id message` in the Murmur group. A configured peer is not proof that the
recipient imported the pairing reply or can wake an agent.

This build is an operator companion configured for Alex's SSH alias. The public catalog
contains product documentation and synthetic previews only; it does not distribute
credentials, connection invitations, private messages or a universal installer.
