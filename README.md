<div align="center">
<pre>
&lt; ▄▄ @ ▄▄ &gt;   @
   ▄▀ 0x0 ▀▄   █
    █  ───  █──█
    █  ███  █  █
     ▀▀   ▀▀   █
</pre>

# gnome-wayland-reload

Fresh extension code. Live host reload. No ceremonial logout.

[Install](#install) · [Decision matrix](#decision-matrix) ·
[Development loop](#the-development-loop) · [Host reload](#live-host-reload) ·
[Uninstall](#uninstall)
</div>

---

On GNOME 50 Wayland, GNOME Shell is the compositor. The live host process
cannot be restarted without ending the graphical session, and already-imported
extension JavaScript cannot be unloaded from that process.

This Agent Skill turns that hard boundary into a practical workflow:

- deploy and hot-swap an already-`ACTIVE` extension's top-level `extension.js`
  through Looking Glass without disable/enable or logout;
- soft-cycle one extension when lifecycle cleanup is enough;
- run a fresh nested `gnome-shell --devkit` when imported Shell modules changed;
- reopen the separate preferences process for `prefs.js` changes;
- compile schemas and restart only the processes that consume them;
- inspect the right logs before escalating; and
- reject host-killing restart folklore on Wayland.

It owns the complete loop: classify the changed artifact, inspect the real
session and UUID, choose the smallest boundary that can load it, execute one
reversible step, then prove the installed bytes are running. Questions appear
only at real target, risk, or host-logout boundaries.

The repository targets **Ubuntu 26.04, GNOME Shell 50, and Wayland**, while the
development runner also supports GNOME 49's `--devkit` workflow.

## Install

Run as your normal desktop user—**not with `sudo`**:

```bash
curl -fsSL https://ryanraposo.github.io/gnome-wayland-reload/install.sh | bash
```

The installer prepares `mutter-dev-bin`, then places complete, independent,
runtime-native copies in both skill homes. The installed bundle includes the
source-to-host reload wrapper, Looking Glass injector and driver, nested-Shell
runner, diagnostics, and receipt machinery.

The Agent Skills copy uses OpenAI's minimal skill metadata and UI file; the
Hermes copy uses Hermes version, platform, tag, and related-skill metadata:

```text
~/.agents/skills/gnome-wayland-reload
~/.hermes/skills/gnome-wayland-reload
```

It is safe to rerun. Existing unmanaged directories are moved into a timestamped
backup under `~/.local/state/gnome-wayland-reload/backups/` before installation.

| Option | Effect |
|---|---|
| `--agents-only` | Install only under `~/.agents/skills/` |
| `--hermes-only` | Install only under `~/.hermes/skills/` |
| `--skip-devkit` | Install skills without the Ubuntu nested-Shell package |
| `--help` | Show installer usage |

From a checkout:

```bash
git clone https://github.com/ryanraposo/gnome-wayland-reload.git
cd gnome-wayland-reload
./install.sh
```

Start a new agent session after installation so its skill index is rebuilt.
Hermes can also rescan in-session with `/reload-skills`.

Each installed skill checks the published `VERSION` at most once per day when
first used. The check is offline-safe and never updates files by itself. Run
`scripts/check-update.sh --force` for an immediate check.

## Decision matrix

| You changed or need | Reload that works |
|---|---|
| Stuck UI, lifecycle cleanup, settings reaction | Disable → enable |
| `stylesheet.css` | Disable → enable first |
| `prefs.js` | Close → reopen preferences |
| Already-`ACTIVE` extension; top-level `extension.js` | Deploy → Looking Glass live reload |
| Imported Shell-side JavaScript | Fresh nested Shell |
| `metadata.json` | Fresh nested Shell |
| Schema XML | Compile schemas, then refresh its consumer |
| Host-only behavior requiring a fresh Shell process | Logout → login |

Disable/enable is a lifecycle recycle. It does **not** load edited JavaScript
into the existing Shell process.

## Live host reload

For the common development case—an extension is already installed and active,
and the runtime change is in its top-level `extension.js`—point the helper at
the extension source directory or at a repository containing exactly one GNOME
extension:

```bash
~/.agents/skills/gnome-wayland-reload/scripts/reload-extension.sh \
  /path/to/extension-or-repo
```

The command:

1. discovers `metadata.json` and the UUID;
2. confirms the installed target is already `ACTIVE`;
3. copies the source tree into the installed extension directory;
4. proves installed `extension.js` matches source; and
5. opens Looking Glass, injects a cache-busted replacement transaction, and
   verifies its receipt and journal proof.

Being already installed and enabled is the happy path. The wrapper does not run
`gnome-extensions disable`, does not run `gnome-extensions enable`, and does not
log out. Every top-level iteration gets a fresh transaction receipt.

Relative imports remain cached by the running GJS process. If one of those
changed, use the nested-Shell path below.

## Soft-cycle one extension

```bash
~/.agents/skills/gnome-wayland-reload/scripts/recycle-extension.sh \
  your-extension@example.com
```

The helper verifies the UUID exists and refuses to silently enable an extension
that was disabled. Use `--enable-disabled` only when that state change is
intentional.

## The development loop

For top-level `extension.js` work on an already-active extension:

```bash
# edit
~/.agents/skills/gnome-wayland-reload/scripts/reload-extension.sh /path/to/repo
# observe the new behavior; repeat
```

That is the canonical no-logout live loop: **deploy bytes first, hot-swap
second**.

When an imported module, `metadata.json`, schema consumer, native library, or
Shell process global changed, launch a fresh disposable Shell instead:

```bash
~/.agents/skills/gnome-wayland-reload/scripts/dev-shell.sh
```

Inside that nested desktop, enable the extension. After another imported-module
change, close the nested Shell and start it again. Your host desktop and its
open applications stay put.

The nested session shares your home directory and settings. It is a clean Shell
process, not a security sandbox.

## Looking Glass transaction internals

The source-to-host wrapper delegates to:

```bash
~/.agents/skills/gnome-wayland-reload/scripts/looking-glass-inject.sh \
  your-extension@example.com
```

That helper owns `prepare → show → GUI injection → executed → verify` and uses
`scripts/lg-autohotswap.py` when the CUA driver is available. The underlying
receipt generator is `scripts/looking-glass-hotswap.sh`.

The mechanism relies on private Shell APIs, retains old imported module objects,
and does not refresh relative imports, metadata, schemas, native code, or other
process-global state. Those are real boundaries; an already-active extension is
not one of them.

## Preferences, schemas, and logs

```bash
gnome-extensions prefs your-extension@example.com
journalctl -f -o cat /usr/bin/gjs
glib-compile-schemas schemas/
journalctl -f -o cat /usr/bin/gnome-shell
```

Run the bundled environment report when the loop is unavailable:

```bash
~/.agents/skills/gnome-wayland-reload/scripts/diagnose.sh
```

Looking Glass remains useful for live inspection: press `Alt`+`F2`, enter `lg`,
and open Extensions. A normal disable/enable from Looking Glass still uses the
cached module; the reload helper instead performs a cache-busted dynamic import
and replaces the live extension state object.

See [`references/gnome-50-debugging-notes.md`](references/gnome-50-debugging-notes.md)
for the guarded transaction, recovery limits, verification ladder, and runtime
bugs that commonly look like stale code.

The workflow contract for assumptions, phase transitions, mutation classes,
failure budgets, and completion proof lives in
[`references/skill-ux-contract.md`](references/skill-ux-contract.md).

## Commands to avoid on the host

```bash
killall gnome-shell
gnome-shell --replace
systemctl --user restart gnome-shell
kill -HUP "$(pidof gnome-shell)"
```

Also ignore `Alt`+`F2` → `r` / `restart` advice for Wayland. Those paths do not
provide an in-session GNOME 50 reload and may end the graphical session.

## Shell-function examples

Source [`examples/shell-functions.sh`](examples/shell-functions.sh) to add
`gext-recycle`, `gext-devkit`, and `gext-logs` to an interactive Bash session.

## Validate

```bash
bash ./tests/skill-ux.sh
./tests/run.sh
bash ./tests/hotswap-agent.sh
node ./tests/hotswap-payload.mjs
bash ./tests/reload-extension.sh
```

The constitutional gate enforces the compact description, rich trigger coverage
outside frontmatter, repository/runtime authority, installed decision reference,
and version identity. The regression suites verify installers, restoration,
runtime-native payloads, Looking Glass transaction integrity, and the complete
already-`ACTIVE` deploy-and-reload path.

## Uninstall

```bash
curl -fsSL https://ryanraposo.github.io/gnome-wayland-reload/uninstall.sh | bash
```

Use `--agents-only` or `--hermes-only` to narrow removal. The uninstaller only
removes directories bearing this project's managed marker. Add `--restore` to
restore any unmanaged directories backed up by the latest installation.

## Repository map

| Path | Purpose |
|---|---|
| `AGENTS.md` | Install, use, and maintenance guide for repository-aware agents |
| `SKILL.md` | Canonical cross-agent workflow |
| `install.sh` | Local and curl-pipe dual-runtime installer |
| `uninstall.sh` | Marker-safe removal and optional restoration |
| `scripts/reload-extension.sh` | Deploy source and reload an already-`ACTIVE` host extension |
| `scripts/recycle-extension.sh` | Verified lifecycle recycle for one UUID |
| `scripts/dev-shell.sh` | GNOME 49+ nested development Shell launcher |
| `scripts/diagnose.sh` | Session and prerequisite report |
| `scripts/looking-glass-hotswap.sh` | Receipt-backed top-level hot-swap transaction generator |
| `scripts/looking-glass-inject.sh` | Automate Looking Glass injection end-to-end |
| `scripts/lg-autohotswap.py` | CUA-driver client that drives Looking Glass GUI |
| `scripts/inspect-shell-source.sh` | Extract JavaScript from the installed GNOME Shell build |
| `scripts/check-update.sh` | Cached, non-mutating release update check |
| `examples/shell-functions.sh` | Optional interactive shortcuts |
| `references/gnome-50-debugging-notes.md` | Host hot-swap caveats and GNOME 50 debugging findings |
| `references/skill-ux-contract.md` | Reload phases, mutation boundaries, recovery, and proof |
| `assets/mascot.txt` | Reloop, the nested-Shell mechanic and his reload staff |
| `tests/skill-ux.sh` | Constitutional and metadata regression checks |
| `tests/run.sh` | Installer and helper regression tests |
| `tests/reload-extension.sh` | Already-`ACTIVE` source deployment and handoff proof |
| `agents/openai.yaml` | Skill-list UI metadata |

## Authoritative references

- [GNOME JavaScript: Debugging](https://gjs.guide/extensions/development/debugging.html)
- [GNOME JavaScript: Preferences](https://gjs.guide/extensions/development/preferences.html)
- [GNOME JavaScript: GNOME Shell 49 porting notes](https://gjs.guide/extensions/upgrading/gnome-shell-49.html)

MIT © Ryan Raposo
