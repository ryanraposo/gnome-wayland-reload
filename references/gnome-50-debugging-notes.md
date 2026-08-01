# GNOME 50 Host Hot-Swap and Debugging Notes

These notes collect practical findings from repairing and live-testing a GNOME
Shell 50 extension on an active Wayland desktop. They supplement the safe
default in `SKILL.md`: use a disposable nested Shell for edited Shell-side
JavaScript, or log out and back in when host-only behavior must be tested in a
genuinely fresh process.

## What an Install or Soft-Cycle Proves

Installing an updated extension proves that new files reached the extension
directory. Disable/enable proves that `disable()` and `enable()` ran. Neither
proves that a changed ES module was re-imported: GJS caches modules for the
lifetime of the Shell process.

Check the layers separately:

1. Validate the source and assets before installation (`node --check`, image
   decoding, project tests, and `sha256sum` where useful).
2. Compare the source and installed artifacts.
3. Record a timestamp, exercise the extension, then inspect fresh journal
   entries for its UUID.
4. Confirm `gnome-extensions info UUID` reports `Enabled: Yes` and
   `State: ACTIVE`.
5. Prove the new behavior is running with a visible change, a temporary unique
   log marker, or another observation that only the new code can produce.

For motion defects, capture multiple frames over longer than the extension's
polling interval. A single screenshot cannot distinguish a smooth animation
from one that periodically snaps back to its origin.

## Experimental Looking Glass Hot-Swap

GNOME Shell 50's extension manager normally imports `extension.js` by its file
URI once. A unique URI query makes GJS treat the top-level file as a different
module. Looking Glass can use that fact to replace the extension's live
`stateObj` without restarting the host Shell.

This is an unsupported diagnostic technique, not a normal deployment path:

- it calls private methods whose names and behavior may change;
- the old and new modules remain resident until the Shell process exits;
- a query on `extension.js` does not cache-bust its normal relative imports;
- it does not refresh metadata, schemas, native libraries, or process globals;
- a constructor or `enable()` failure can leave the extension inactive or in
  an error state; and
- disabling one extension may temporarily cycle extensions ordered after it.

Use it only for a small, understood top-level change when preserving the host
session is important. Prefer a nested Shell for repeatable testing.

Generate the guarded snippet with:

```bash
scripts/looking-glass-hotswap.sh UUID
```

Open Looking Glass with `Alt`+`F2`, enter `lg`, select the JavaScript evaluator,
and paste the generated code. Its essential sequence is:

```javascript
const uuid = 'UUID';
const manager = Main.extensionManager;
const extension = manager.lookup(uuid);
const {ExtensionState} = await import(
    'resource:///org/gnome/shell/misc/extensionUtils.js'
);
const file = extension.dir.get_child('extension.js');
const module = await import(`${file.get_uri()}?reload=${Date.now()}`);
const nextState = new module.default({
    ...extension.metadata,
    dir: extension.dir,
    path: extension.path,
});
const previousState = extension.stateObj;
await manager._callExtensionDisable(uuid);
extension.stateObj = nextState;
await manager._callExtensionEnable(uuid);
if (extension.state !== ExtensionState.ACTIVE) {
    try {
        nextState.disable();
    } catch (cleanupError) {
        console.error('Replacement cleanup failed', cleanupError);
    }
    extension.stateObj = previousState;
    manager._changeExtensionState(extension, ExtensionState.INACTIVE);
    await manager._callExtensionEnable(uuid);
    throw new Error('Hot-swap failed; attempted to restore previous state');
}
extension.state;
```

Import and construction happen before the working instance is disabled, so a
syntax or constructor error leaves it active. The later rollback is still
best-effort. If the new instance partially created actors before failing, its
own `enable()` error path must clean them up. After the experiment, verify
state and fresh logs from a host terminal:

```bash
gnome-extensions info UUID
journalctl --since '2 minutes ago' -o cat /usr/bin/gnome-shell |
  grep -i -- 'UUID'
```

Do not repeatedly hot-swap for routine development; every unique URI adds
another module to the long-lived compositor process.

## Inspect the Code This GNOME Build Runs

Ubuntu packages GNOME Shell's JavaScript resources inside its versioned Shell
library. Find that library rather than relying on an online example from a
different release:

```bash
scripts/inspect-shell-source.sh environment
scripts/inspect-shell-source.sh extension-system
scripts/inspect-shell-source.sh --list
```

The helper locates the library with the equivalent of:

```bash
shell_resource_lib="$({ ldd "$(command -v gnome-shell)" || true; } |
  awk '/libshell-[0-9]+\.so/ {print $3; exit}')"
gresource list "$shell_resource_lib" | grep '/org/gnome/shell/ui/'
gresource extract "$shell_resource_lib" \
  /org/gnome/shell/ui/environment.js | less
```

For extension lifecycle and caching behavior, inspect
`/org/gnome/shell/ui/extensionSystem.js` the same way. The GNOME 50 source
explicitly notes that imported extensions are cached and a different version
cannot normally be loaded into the same Shell process.

## Runtime Bugs That Resemble a Bad Reload

### `actor.ease()` uses camelCase control options

GNOME Shell's `actor.ease()` wrapper extracts `repeatCount` and `autoReverse`
before translating animated property names. These are different from the
snake_case GObject properties used when directly constructing a
`Clutter.PropertyTransition`:

```javascript
actor.ease({
    translation_y: -8,
    duration: 1450,
    mode: Clutter.AnimationMode.EASE_IN_OUT_SINE,
    repeatCount: -1,
    autoReverse: true,
});
```

Using `repeat_count` and `auto_reverse` in `actor.ease()` can look like a reload
problem: the actor travels once, stays at the target, and then snaps when other
code resets or reapplies it.

### Polling must not restart unchanged-state animations

If presence is refreshed every few seconds, separate status rendering from
animation transitions:

```javascript
const stateChanged = this._state !== state;
this._state = state;
this._renderState(state);
if (stateChanged)
    this._animateState(state);
```

Otherwise the poll cadence becomes a visible jump cadence even when the
animation itself is correct.

### Preserve non-square artwork explicitly

Forcing a tall PNG through a square `St.Icon.icon_size` can stretch it. Load it
with one dimension unconstrained and center the result in a fixed hit target:

```javascript
const container = new St.Bin({width: size, height: size});
const scaleFactor = St.ThemeContext.get_for_stage(global.stage).scale_factor;
const texture = St.TextureCache.get_default().load_file_async(
    file,
    -1,
    size,
    scaleFactor,
    container.get_resource_scale()
);
texture.x_align = Clutter.ActorAlign.CENTER;
texture.y_align = Clutter.ActorAlign.CENTER;
container.set_child(texture);
```

Use a purpose-made square icon for panel-sized portraits when available, and
decode packaged PNGs in tests so a corrupt asset does not masquerade as a Shell
API failure.

### Make partial initialization recoverable

Set every owned actor, gesture, signal ID, and timeout ID to a neutral value
before building UI. Wrap `enable()` construction in `try`/`catch`, call an
idempotent `disable()` on failure, then rethrow. This matters during live
diagnosis because an exception halfway through `enable()` otherwise leaves
duplicate or input-blocking actors behind on the host desktop.

### Re-check GNOME 50 interaction APIs

Older Clutter samples may no longer match the installed introspection API. In
the repaired extension, `Clutter.PanGesture` with `pan-update` replaced an old
drag action, and `Clutter.ClickGesture` supplied explicit click recognition for
a custom panel button. An obsolete `addChrome()` option was also removed after
the Shell logs identified it. Treat these as prompts to inspect the local API,
not universal substitutions for every extension.
