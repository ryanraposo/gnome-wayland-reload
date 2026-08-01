<div align="center">
<img src="assets/orb.svg" width="112" alt="A black-and-white reload orb">

# gnome-wayland-reload

Fresh extension code. Disposable nested Shells. No ceremonial logout.

[Install](#install) · [Decision matrix](#decision-matrix) ·
[Development loop](#the-development-loop) · [Uninstall](#uninstall)
</div>

---

On GNOME 50 Wayland, GNOME Shell is the compositor. The live host process
cannot be restarted without ending the graphical session, and already-imported
extension JavaScript cannot be unloaded from that process.

This Agent Skill turns that hard boundary into a practical workflow:

- soft-cycle one extension when lifecycle cleanup is enough;
- run a fresh nested `gnome-shell --devkit` for edited Shell-side code;
- reopen the separate preferences process for `prefs.js` changes;
- compile schemas and restart only the processes that consume them;
- inspect the right logs before escalating; and
- reject host-killing restart folklore on Wayland.

The repository targets **Ubuntu 26.04, GNOME Shell 50, and Wayland**, while the
development runner also supports GNOME 49's `--devkit` workflow.

## Install

Run as your normal desktop user—**not with `sudo`**:

```bash
curl -fsSL https://ryanraposo.github.io/gnome-wayland-reload/install.sh | bash
```

The installer places complete, independent copies in both skill homes:

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
| `--help` | Show installer usage |

From a checkout:

```bash
git clone https://github.com/ryanraposo/gnome-wayland-reload.git
cd gnome-wayland-reload
./install.sh
```

Start a new agent session after installation so its skill index is rebuilt.
Hermes can also rescan in-session with `/reload-skills`.

## Decision matrix

| You changed or need | Reload that works |
|---|---|
| Stuck UI, lifecycle cleanup, settings reaction | Disable → enable |
| `stylesheet.css` | Disable → enable first |
| `prefs.js` | Close → reopen preferences |
| `extension.js` or imported Shell-side JavaScript | Fresh nested Shell |
| `metadata.json` | Fresh nested Shell |
| Schema XML | Compile schemas, then refresh its consumer |
| Host-only behavior that cannot reproduce nested | Logout → login |

Disable/enable is a lifecycle recycle. It does **not** load edited JavaScript
into the existing Shell process.

## Soft-cycle one extension

```bash
~/.agents/skills/gnome-wayland-reload/scripts/recycle-extension.sh \
  your-extension@example.com
```

The helper verifies the UUID exists and refuses to silently enable an extension
that was disabled. Use `--enable-disabled` only when that state change is
intentional.

## The development loop

Install the Ubuntu development runner once:

```bash
sudo apt install mutter-dev-bin
```

Then launch a fresh, disposable Shell in a window:

```bash
~/.agents/skills/gnome-wayland-reload/scripts/dev-shell.sh
```

Inside that nested desktop, open a terminal and enable the extension. After
editing `extension.js`, an imported module, or `metadata.json`, close the nested
Shell and start it again. Your host desktop and its open applications stay put.

The nested session shares your home directory and settings. It is a clean Shell
process, not a security sandbox.

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
and open Extensions. It shows state and errors, but it cannot unload cached
modules.

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
| `SKILL.md` | Canonical cross-agent workflow |
| `install.sh` | Local and curl-pipe dual-runtime installer |
| `uninstall.sh` | Marker-safe removal and optional restoration |
| `scripts/recycle-extension.sh` | Verified lifecycle recycle for one UUID |
| `scripts/dev-shell.sh` | GNOME 49+ nested development Shell launcher |
| `scripts/diagnose.sh` | Session and prerequisite report |
| `examples/shell-functions.sh` | Optional interactive shortcuts |
| `tests/run.sh` | Installer and helper regression tests |
| `agents/openai.yaml` | Skill-list UI metadata |

## Authoritative references

- [GNOME JavaScript: Debugging](https://gjs.guide/extensions/development/debugging.html)
- [GNOME JavaScript: Preferences](https://gjs.guide/extensions/development/preferences.html)
- [GNOME JavaScript: GNOME Shell 49 porting notes](https://gjs.guide/extensions/upgrading/gnome-shell-49.html)

MIT © Ryan Raposo
