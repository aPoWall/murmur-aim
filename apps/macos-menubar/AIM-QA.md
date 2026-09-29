# AIM edition acceptance · 29 September 2026

- Current design N1, arm64, upstream app source from main after v2.12.0.
- Release Swift build completed on the target Mac.
- 494 upstream native contract/fixture checks passed, including profile identity,
  pairing, raw-credential refusal, status truth and CLI mutation boundaries.
- 7 native bundled-helper checks passed in disposable homes; real argv and PID
  preservation, environment isolation and incomplete runtime refusal checked.
- Official 2.12.0 runtime archive SHA256:
  `ed8c0005ecb3740d1cb0d1711ebc14e69b904180ea4ee2524172fe38182a5927`.
  All 1128 payload files verified against its manifest. Engine commit:
  `e7f389c97146dd305a19099eeb1ea00eda56c423`.
- Shared AIM source hashes and bundled Plex assets checked. No private profile or
  inbox was copied into the source or app. Transport code is upstream.
- Offscreen welcome, settings and help rendered at 740 × 700. Welcome/settings
  visually inspected; shared-header mark overlap corrected. Header order,
  footer and typography match the N1 reference. No live window was shown for QA.
- App is ad-hoc signed. Signature and bundled CLI checked before installation.

Control wiring: header settings selects Settings; shared tabs select Home/Help;
pin sets AIMSurface.pinned; header close, Escape, Command-W and menu click route
to AIMSurface.close; footer opens the public apps catalog. Existing preferences
menu preserves language, login toggle and pairing entry. These paths are inspected
in source and rendered offscreen. A full live mouse/keyboard control walk, TCC,
login/reboot, pairing and real automatic agent wake are not verified in this pass.
The installation starts with --background, not a forced window, during the call.

Intentional first-edition exceptions: existing fixed global shortcut is retained;
menu-bar mode chooser and hotkey recorder remain future work. The same family
mark is used for this personal fork; no suite-wide mark or design-system source
was edited. No public site or release was published.
