#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: looking-glass-hotswap.sh UUID

Print a guarded GNOME Shell 50 Looking Glass snippet that cache-busts and
hot-swaps one extension's top-level extension.js. This uses private APIs and is
only for short-lived host diagnostics; prefer scripts/dev-shell.sh otherwise.
EOF
}

case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
    '')
        usage >&2
        exit 2
        ;;
esac

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi

uuid="$1"
case "$uuid" in
    *[!A-Za-z0-9._@+-]*)
        echo "error: UUID contains unsupported characters" >&2
        exit 2
        ;;
esac

cat >&2 <<'EOF'
warning: private GNOME Shell diagnostic; the old module remains cached
warning: use only for a top-level extension.js change with reliable cleanup
next: open Looking Glass (Alt+F2, lg) and paste the JavaScript below
EOF

cat <<EOF
const uuid = '$uuid';
const manager = Main.extensionManager;
const extension = manager.lookup(uuid);
const {ExtensionState} = await import(
    'resource:///org/gnome/shell/misc/extensionUtils.js'
);
const file = extension.dir.get_child('extension.js');
const module = await import(\`\${file.get_uri()}?reload=\${Date.now()}\`);
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
EOF
