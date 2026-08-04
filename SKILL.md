---
name: gnome-wayland-reload
description: Reload GNOME Shell extensions safely on Wayland.
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
| `extension.js` or a Shell-side imported `.js` module | Fresh nested Shell; otherwise host logout/login |
| Small top-level `extension.js` diagnostic that must preserve host state | Guarded Looking Glass hot-swap (advanced/private) |
| `metadata.json` | Fresh nested Shell; otherwise host logout/login |
| GSettings schema XML | Compile schemas, then restart the process that consumes them |
| Native library, typelib, or Shell process state | Fresh nested Shell; otherwise host logout/login |

Do not claim that disable/enable loads edited Shell-side JavaScript. GJS cannot
unload an already-imported module from the running Shell process.

A cache-busted dynamic import from Looking Glass can hot-swap a simple
`extension.js` for diagnosis on the host. This relies on private GNOME Shell
internals, leaves the old module resident, and does not refresh ordinary
relative imports. Keep the nested Shell as the supported development loop; use
the hot-swap only when preserving current host-session state is materially
useful. See `references/gnome-50-debugging-notes.md` for the guarded recipe and
recovery limits.

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
enables fresh GNOME Shell test sessions in a window, so edited extension code
can load without logging out or restarting the real desktop. If a deliberately
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
After editing Shell-side JavaScript, close the nested Shell window and launch
it again. This creates a genuinely fresh GJS process without touching the host
desktop.

Treat the nested Shell as disposable, not sandboxed. It has little isolation,
shares the user's home directory and settings, and can still modify user data.

## Hot-Swap One Top-Level Module (Advanced)

When a host-only state is expensive to recreate and the change is confined to
the top-level `extension.js`, generate a guarded Looking Glass snippet:

```bash
scripts/looking-glass-hotswap.sh UUID
```

Open Looking Glass with `Alt`+`F2`, then `lg`, and paste the generated code into
its JavaScript evaluator. The snippet disables the extension, dynamically
imports `extension.js` with a unique query, constructs a new state object, and
enables it. It retains the previous state object for a best-effort rollback.

Do not use this for imported modules, metadata, schemas, native code, repeated
development cycles, or an extension whose cleanup is not known to be
idempotent. Immediately verify `ACTIVE` state, fresh logs, and behavior. Use a
fresh nested Shell if anything is uncertain.

## Reload Preferences and Schemas

Preferences run in a separate `gjs` process. Close the preferences window and
reopen it to load `prefs.js` changes:

```bash
gnome-extensions prefs UUID
```

Follow preference logs with:

```bash
journalctl -f -o cat /usr/bin/gjs
```

When editing a schema without reinstalling through `gnome-extensions`, compile
it from the extension root:

```bash
glib-compile-schemas schemas/
```

Then reopen preferences and restart the nested Shell if the Shell process also
consumes the schema.

## Observe Before Escalating

Follow host Shell logs:

```bash
journalctl -f -o cat /usr/bin/gnome-shell
```

Filter for the UUID while preserving streaming output:

```bash
journalctl -f -o cat /usr/bin/gnome-shell |
  grep --line-buffered -i -- 'UUID'
```

Open Looking Glass with `Alt`+`F2`, then `lg`. Use its Extensions page to
inspect loaded state, errors, source location, and metadata. Looking Glass does
not defeat module caching by itself. A normal disable/enable from Looking
Glass still uses the cached module.

Do not treat matching source and installed-file hashes as proof that those
bytes are running. Verify three layers: the installed artifact, the extension's
`ACTIVE` state and fresh journal entries, and an observable behavior or unique
diagnostic marker from the new code. For animation bugs, capture several frames
across more than one polling interval so a periodic reset is visible.

## Separate Reload Failures from Runtime Bugs

Before escalating to a fresh process, check whether the new module is active
but behaving incorrectly. GNOME 50 pitfalls observed in practice include:

- `actor.ease()` consumes `repeatCount` and `autoReverse`; snake_case belongs
  to lower-level `Clutter.PropertyTransition` construction and is silently
  wrong in the `ease()` options object.
- A status poll that reapplies the same state can restart an otherwise-correct
  animation. Animate only when the semantic state changes.
- A square `St.Icon.icon_size` can stretch non-square raster artwork. Load the
  texture with one unconstrained dimension and center it in a fixed container.
- Partial `enable()` failure can strand actors. Initialize owned fields first,
  make `disable()` idempotent, and call it from an `enable()` failure path.
- APIs and option bags are versioned. GNOME 50 uses gesture APIs such as
  `Clutter.PanGesture` and `Clutter.ClickGesture`; inspect the installed Shell
  sources and logs instead of assuming an older example still applies.

The reference note contains concrete snippets and local-source inspection
commands for these cases.

Use the bundled inspector to read the exact JavaScript shipped by the current
GNOME Shell build:

```bash
scripts/inspect-shell-source.sh environment
scripts/inspect-shell-source.sh extension-system
```

## Reject Unsafe Host-Restart Advice

Do not run these against the active Wayland session:

```bash
killall gnome-shell
gnome-shell --replace
systemctl --user restart gnome-shell
kill -HUP "$(pidof gnome-shell)"
```

Do not recommend `Alt`+`F2` → `r` or `restart` on Wayland. These are X11-era
restart paths and do not provide an in-session GNOME 50 Wayland reload.

If a fresh host process is truly required and a nested Shell cannot reproduce
the issue, explain that logout/login is the remaining correct boundary. Never
log the user out without explicit permission.

## Completion Receipt

Finish only when the changed artifact and selected refresh boundary match, the
host compositor remains intact, and the new behavior is proved through installed
bytes, fresh runtime evidence, and an observable result. Report the action,
evidence, any rollback or recovery, remaining uncertainty, and one meaningful
next action.
