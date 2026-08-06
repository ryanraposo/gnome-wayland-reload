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

For motion defects, combine structural and temporal proof. Inspect a timer,
transition, frame counter, or field that exists only in the new implementation,
then capture the target crop at three or more deliberately non-harmonic
offsets. Sampling at or near the loop period aliases motion: an eight-frame
animation at 125 ms per frame can look identical in captures one second apart.
If frames match, change the cadence before concluding that the actor is static.

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
  an error state;
- disabling one extension may temporarily cycle extensions ordered after it;
  and
- lifecycle methods in those extensions may produce side effects that restoring
  manager bookkeeping cannot undo.

Use it only for a small, understood top-level change when preserving the host
session is important. Prefer a nested Shell for repeatable testing.

### Receipt-backed agent execution

The generated JavaScript is intentionally treated as machinery, not prose. An
agent prepares one immutable one-line payload and a durable receipt:

```bash
PREPARED_JSON="$(scripts/looking-glass-hotswap.sh prepare "$UUID")"
RECEIPT="$(python3 -c \
  'import json,sys; print(json.loads(sys.argv[1])["receipt_file"])' \
  "$PREPARED_JSON")"
PAYLOAD="$(scripts/looking-glass-hotswap.sh show "$RECEIPT")"
```

The receipt records the UUID, unique token, exact journal marker, preparation
time, payload path, and SHA-256. Both files are created with mode `0600`.
`show` verifies the payload hash and receipt state before emitting the exact
one-line evaluator text.

Use `computer_use` to open Looking Glass, locate the current evaluator entry,
type the complete `$PAYLOAD`, capture the entry, and verify its beginning,
receipt token, and final `JSON.stringify(proof)` before pressing Return. Execute
once. A visually truncated, `undefined`, or ambiguous evaluator result is not a
reason to execute again.

Immediately after pressing Return, record the one-shot submission:

```bash
scripts/looking-glass-hotswap.sh executed "$RECEIPT"
```

This validates the prepared payload one last time, closes the abort window, and
advances the receipt from `PREPARED` to `EXECUTED`. Record execution even when
the visible evaluator result is unclear.

Then verify through the same receipt:

```bash
scripts/looking-glass-hotswap.sh verify "$RECEIPT"
```

The verifier accepts only `EXECUTED` or previously `INCONCLUSIVE` receipts. It
searches current-boot journal entries after the recorded preparation time and
requires the exact token marker. It parses the structured transaction proof,
checks UUID and token equality, requires `phase=complete`, the replacement
state object, restored extension-order bookkeeping, and separately requires
`gnome-extensions info` to report `ACTIVE`.

The result is persisted as one of:

- `VERIFIED` — exact transaction proof plus active state; continue to behavior
  verification;
- `FAILED` — the exact invocation ran and reported failure; inspect its phase
  and rollback object without executing another payload; or
- `INCONCLUSIVE` — exact proof is absent or malformed. Inspect the diagnostic
  and journal, then rerun `verify` against the same receipt. Never rerun the
  payload.

If the prepared payload was never executed, close the receipt with:

```bash
scripts/looking-glass-hotswap.sh abort "$RECEIPT"
```

`abort` is valid only while the receipt is `PREPARED`. After Return has been
pressed, use `executed` and preserve the receipt regardless of visible output.

### Transaction boundaries

The generated payload feature-detects the private manager methods and refuses
before mutation unless the extension already has all of these properties:

- it exists in the current manager;
- its state is `ACTIVE`;
- it has a live `stateObj`; and
- its UUID appears in the manager's extension order.

Import and construction occur before the working instance is disabled, so a
syntax, import, or constructor error leaves the current state object untouched.
After mutation begins, the payload records the exact phase.

If replacement enablement fails after a clean transition to `INACTIVE`, it
attempts and proves replacement cleanup, restores the old state object,
re-enables it, and proves old-object identity, `ACTIVE` state, and restored
extension-order bookkeeping. Replacement cleanup failure prevents rollback
from being called complete. Failure to restore manager order also fails the
transaction and enters rollback.

If the current instance itself fails while disabling, the payload does not
force an unsafe enable over an uncertain partial cleanup. It restores order
bookkeeping, reports rollback failure, and explicitly requires manual recovery.

GNOME's internal disable/enable sequence normally moves the target UUID to the
end of `_extensionOrder`. The payload records that intermediate order and then
restores the original bookkeeping position. This preserves future manager
ordering, but does not pretend that already-executed lifecycle side effects in
other extensions disappeared.

For human inspection without a receipt, generate one line directly:

```bash
scripts/looking-glass-hotswap.sh --one-line UUID
```

The receipt-backed `prepare → show → executed → verify` workflow is canonical
for agents. The generated helper is the source of truth for the current private
transaction; do not copy an old embedded JavaScript snippet from documentation.

The proof only establishes replacement of the top-level state object. If
`extension.js` statically imports an edited relative module, the unchanged
specifier still resolves to the module already cached by GJS. A successful
receipt therefore does not prove imported code changed. Use a fresh nested
Shell, or a project-specific import-aware reload that gives every edited module
a unique URI.

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
