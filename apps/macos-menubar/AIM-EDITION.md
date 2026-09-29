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
