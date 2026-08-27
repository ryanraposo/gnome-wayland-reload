# GNOME 50, Looking Glass, Hermes, and CUA Research

Validated on Ubuntu 26.04, GNOME Shell 50.1, Wayland, Hermes 0.20.0,
and cua-driver 0.19.3 on 2026-08-12.

## GNOME 50 lifecycle facts

- GNOME's extension debugging guide says JavaScript cannot be unloaded from
  the interpreter. Wayland needs logout/login for a fresh host process, while
  GNOME 49+ supports `dbus-run-session gnome-shell --devkit --wayland`.
- The installed GNOME 50.1 `extensionSystem.js` imports
  `extension.js` by file URI and records that it has already been imported.
  Its normal reload path unloads lifecycle state but does not create a new
  module identity.
- A query-bearing top-level file URI creates a distinct dynamic-import
  identity in this GJS build. Static relative imports inside it retain their
  normal specifiers and therefore remain cached.
- GNOME 50.1's private disable routine temporarily disables extensions ordered
  after the target, removes the target from `_extensionOrder`, then re-enables
  the later extensions. Any host hot-swap must preserve bookkeeping and admit
  that lifecycle side effects cannot be undone.

Inspect the exact local sources with:

```bash
scripts/inspect-shell-source.sh extension-system
scripts/inspect-shell-source.sh /org/gnome/shell/ui/lookingGlass.js
scripts/inspect-shell-source.sh /org/gnome/shell/ui/shellDBus.js
```

## Looking Glass facts

- Looking Glass is GNOME Shell's in-process evaluator, so it can access
  `Main.extensionManager`. A separate `gjs-console` process cannot.
- GNOME 50.1 opens Looking Glass on the Evaluator page and explicitly grabs
  keyboard focus for its entry. Switching to Extensions before evaluation is
  unnecessary and makes automation more fragile.
- The evaluator rewrites one input line into an async function. The generated
  payload is therefore a single semicolon-delimited line ending in
  `JSON.stringify(proof)`.
- `org.gnome.Shell.Eval` exists, but returns `(false, '')` while
  `global.context.unsafe_mode` is false. The workflow never toggles unsafe
  mode to bypass that boundary.

## CUA and GNOME Wayland facts

- cua-driver's current stable surface is its CLI/tool schema:
  `health_report`, `start_session`, `hotkey`, `type_text`,
  `press_key`, and `end_session`. Do not bind this project to undocumented
  raw socket framing or retired `capture/key/type` method names.
- On the validated host, cua-driver app-window accessibility and XWayland
  capture pass, but native Wayland compositor input is not enabled. Global
  desktop actions report an unverifiable route and do not open GNOME's Run
  dialog. The adapter detects this and uses `ydotool` for compositor input.
- A portal screenshot taken between `Alt+F2` and typing steals Run-dialog
  focus on this host. Treat `Alt+F2 → lg → Enter` as one focus-sensitive
  semantic span, then observe.
- The hot-swap driver never uses `wl-copy`, `wl-paste`, or another clipboard
  API. Integrity is proven from the private prepared payload and SHA-256;
  execution is proven by the exact journal token and structured receipt.

## Hermes 0.20 skill facts

- Hermes frontmatter supports version, author, license, platform gating,
  `metadata.hermes.tags`, category, related skills, and required toolsets.
- Current authoring guidance requires a concise, punctuated description and
  favors the section order: When to Use, Prerequisites, How to Run, Quick
  Reference, Procedure, Pitfalls, Verification.
- Runtime-native installation is still appropriate: canonical portable
  frontmatter for Agent Skills, composed Hermes frontmatter for Hermes, and
  the same tested scripts/references in both copies.

## Primary sources

- GNOME JavaScript debugging:
  https://gjs.guide/extensions/development/debugging.html
- GNOME Shell 50 upgrade notes:
  https://gjs.guide/extensions/upgrading/gnome-shell-50.html
- GNOME Shell source:
  https://gitlab.gnome.org/GNOME/gnome-shell
- Hermes Agent repository:
  https://github.com/NousResearch/hermes-agent
