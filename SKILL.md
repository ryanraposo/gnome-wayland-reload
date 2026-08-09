---
name: gnome-wayland-reload
description: Reload and debug GNOME Shell extensions on Wayland
---

# Reload GNOME Extensions on Wayland

At the start of the first reload or diagnosis in a session, run
`scripts/check-update.sh --quiet`. Continue normally if the network is offline.
If it reports an update, tell the user and give the printed reinstall command;
never update the installed skill silently.

Treat the host GNOME Shell as the Wayland compositor. It cannot be restarted
in-place while preserving the graphical session. Prefer the smallest refresh
that can actually load the changed artifact.

Use this skill when edited extension code is not taking effect, disable/enable did not load new code, a cache-busted host hot-swap is under consideration, or the user asks whether gnome-shell --replace, logout/login, or another restart is required. Do not use it for ordinary GNOME app automation.

## Workflow Contract

Take control when invoked. Classify the changed artifact, inspect the session
and extension UUID, choose the smallest refresh boundary that can load it,
execute one reversible step, then prove the new bytes are running.

Move through:

1. **Classify** — identify the artifact, desired outcome, host or nested target,
   and whether the problem is stale code or a runtime bug.
2. **Inspect** — establish session type, Shell version, UUID, installed source,
   extension state, and relevant logs.
3. **Choose** — select one boundary: live setting, lifecycle cycle, preferences
   process, schema consumer, guarded host hot-swap, fresh nested Shell, or host
   logout/login.
4. **Execute** — use the bundled helper or exact narrow command for that
   boundary.
5. **Verify** — prove installed bytes, fresh runtime evidence, and observable
   behavior.
6. **Recover or complete** — restore the prior state or change boundaries after
   failure; otherwise report the result and evidence.

Infer reversible, local, least-disruptive defaults. Ask only when the UUID,
scope, destructive recovery, or authorization for a real host logout is
materially unclear. Ask one question per decision and never more than three.
Recommend and execute one path instead of presenting equivalent choices.

For longer work, surface the active phase when starting, changing strategy, or
requiring user action. Before installing a package, using private host internals,
or ending the graphical session, state the exact effect and obtain the required
authorization. Never equate a successful command with a loaded module.

Read `references/skill-ux-contract.md` when choosing a mutation boundary,
recovering from a partial reload, or deciding whether host logout is justified.

## Decide First

| Change or goal | Correct refresh |
|---|---|
| Recover stuck UI or retest `enable()` / `disable()` | Soft-cycle the extension |
| GSettings value | Usually live; soft-cycle only if the extension does not react |
| `stylesheet.css` | Soft-cycle first |
| `prefs.js` or preference-only imports | Close and reopen preferences |
| Already-`ACTIVE` host extension; top-level `extension.js` changed | Deploy + Looking Glass live reload with `scripts/reload-extension.sh` |
| Shell-side imported `.js` module changed | Fresh nested Shell; otherwise host logout/login |
| `metadata.json` | Fresh nested Shell; otherwise host logout/login |
| GSettings schema XML | Compile schemas, then restart the process that consumes them |
| Native library, typelib, or Shell process state | Fresh nested Shell; otherwise host logout/login |

Do not claim that disable/enable loads edited Shell-side JavaScript. GJS cannot
unload an already-imported module from the running Shell process.

A cache-busted dynamic import from Looking Glass can load a fresh top-level
`extension.js` into the live host and replace the active extension instance.
This relies on private GNOME Shell internals, leaves old modules resident, and
does not refresh ordinary relative imports. For an already-installed,
already-`ACTIVE` development extension with a top-level `extension.js` change,
this is the canonical no-logout live-development path. Use a fresh nested Shell
when relative imports, metadata, schemas, native code, or process globals changed.
See `references/gnome-50-debugging-notes.md` for the guarded transaction and
recovery limits.

Treat "reload without logout/login," "reload the visible host extension," or
an explicit request to use Looking Glass as a request for this live host path
when the edited runtime change is confined to top-level `extension.js` and
cleanup is reliable. Do not silently substitute a soft cycle: it only reruns
lifecycle methods and cannot load fresh Shell-side JavaScript.

The live path is an ordered pair: deploy bytes first, hot-swap second. Prefer
the bundled wrapper when source is available:

```bash
scripts/reload-extension.sh /path/to/extension-or-repo
```

It discovers a single extension beneath a repository when needed, reads its
UUID from `metadata.json`, requires the installed target to be `ACTIVE`, copies
the source tree into the installed extension directory, proves the top-level
`extension.js` bytes match, then delegates to the receipt-backed Looking Glass
injector. Already installed and already enabled is the expected case, not a
blocker. The command does not lifecycle-cycle the extension and does not log out.

## Development Workflow

For iterative host development of top-level `extension.js`, use the live loop:

1. Edit the extension source.
2. Run `scripts/reload-extension.sh /path/to/extension-or-repo`.
3. Let the helper deploy the source tree and execute the Looking Glass
   transaction against the already-`ACTIVE` instance.
4. Verify the receipt plus one runtime marker or observable behavior unique to
   the new code.
5. Repeat with a fresh transaction for the next top-level change.

Do not add a disable/enable step before this loop. The active installed instance
is the state the Looking Glass transaction replaces.

When a relative import, `metadata.json`, schema consumer, native library, or
Shell process global changed, use a fresh nested Shell instead:

1. Edit the source files.
2. Close the nested Shell window.
3. Relaunch it with `scripts/dev-shell.sh`.
4. Inspect Looking Glass and the journal inside that fresh session.

Verify changes across three layers: installed file hash matches source, journal
shows fresh runtime evidence, and observable behavior confirms the update.
Captures one animation loop period apart can look identical even when working —
check at non-harmonic offsets.

## Establish the Target

Confirm the session, Shell version, and extension UUID before acting:

```bash
printf 'session=%s desktop=%s\n' "$XDG_SESSION_TYPE" "$XDG_CURRENT_DESKTOP"
gnome-shell --version
gnome-extensions list --enabled
gnome-extensions info UUID
```

Use `scripts/diagnose.sh` for a compact environment report. Keep host and
nested terminals distinct: a command run in a normal host terminal addresses
the host session bus, while a terminal launched inside the nested desktop
addresses the nested session.

## Soft-Cycle One Extension

Use the bundled helper:

```bash
scripts/recycle-extension.sh UUID
```

Or run the lifecycle sequence directly:

```bash
gnome-extensions disable UUID
sleep 0.25
gnome-extensions enable UUID
gnome-extensions info UUID
```

Only cycle an extension that is already enabled unless the user explicitly
asks to enable it. Use this path for lifecycle cleanup, stuck actors, duplicated
UI, and settings changes—not for edited Shell-side JavaScript.

To lifecycle-cycle every user extension, only when the broad scope is wanted:

```bash
gsettings set org.gnome.shell disable-user-extensions true
sleep 0.5
gsettings set org.gnome.shell disable-user-extensions false
```

This is still not a fresh JavaScript process.

## Run a Fresh Nested Shell

The project installer prepares Ubuntu's development runner as part of setup:

```bash
curl -fsSL https://ryanraposo.github.io/gnome-wayland-reload/install.sh | bash
```

It installs `mutter-dev-bin` through a narrow graphical privilege prompt. This
enables fresh GNOME Shell test sessions in a window, so imported Shell-side code
can load without logging out or restarting your real desktop. If a deliberately
skill-only installation used `--skip-devkit`, install the runner later with
`pkexec apt-get install -y mutter-dev-bin`.

Launch a disposable GNOME 49+ / 50 development Shell:

```bash
scripts/dev-shell.sh
```

The underlying command is:

```bash
dbus-run-session env G_MESSAGES_DEBUG=all SHELL_DEBUG=all \
  gnome-shell --devkit --wayland
```

Enable or inspect the extension from a terminal inside the nested desktop.
After editing imported Shell-side JavaScript, close the nested Shell window and
launch it again. This creates a genuinely fresh GJS process without touching the
host desktop.

Treat the nested Shell as disposable, not sandboxed. It has little isolation,
shares the user's home directory and settings, and can still modify user data.

## Deploy and Reload the Live Host

The complete source-to-runtime command is:

```bash
scripts/reload-extension.sh [--no-wait] [--token TOKEN] /path/to/extension-or-repo
```

Use it when the target is already installed and `ACTIVE`, the runtime change is
confined to top-level `extension.js`, and the extension's cleanup is reliable.
