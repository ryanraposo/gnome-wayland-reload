#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/reload-extension.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Packaging proof: the installed skill must contain the complete live-reload chain.
grep -F 'scripts/reload-extension.sh' "$ROOT/install.sh" >/dev/null
grep -F 'scripts/looking-glass-inject.sh' "$ROOT/install.sh" >/dev/null
grep -F 'scripts/lg-autohotswap.py' "$ROOT/install.sh" >/dev/null
grep -F 'chmod +x "$stage/scripts/"*.sh "$stage/scripts/"*.py' "$ROOT/install.sh" >/dev/null

REPO="$TMP/horner-like-repo"
SOURCE="$REPO/manifestations/desktop/extension/test@example.com"
INSTALLED="$TMP/installed/test@example.com"
FAKEBIN="$TMP/bin"
INJECTOR="$TMP/fake-injector.sh"
CALLS="$TMP/injector.calls"
STATE_FILE="$TMP/state"

mkdir -p "$SOURCE" "$INSTALLED" "$FAKEBIN"
printf 'ACTIVE\n' > "$STATE_FILE"
cat > "$SOURCE/metadata.json" <<'JSON'
{"uuid":"test@example.com","name":"Test Extension","shell-version":["50"]}
JSON
printf 'export default class FreshExtension {}\n' > "$SOURCE/extension.js"
printf 'fresh asset\n' > "$SOURCE/asset.txt"
printf 'export default class StaleExtension {}\n' > "$INSTALLED/extension.js"

cat > "$FAKEBIN/gnome-extensions" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = info ] || { echo "unexpected gnome-extensions operation: \$*" >&2; exit 91; }
[ "\${2:-}" = 'test@example.com' ] || exit 92
printf 'Name: Test Extension\nState: %s\nPath: %s\n' "\$(cat '$STATE_FILE')" '$INSTALLED'
EOF
chmod +x "$FAKEBIN/gnome-extensions"

cat > "$INJECTOR" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> '$CALLS'
cmp -s '$SOURCE/extension.js' '$INSTALLED/extension.js'
test -f '$INSTALLED/asset.txt'
EOF
chmod +x "$INJECTOR"

PATH="$FAKEBIN:$PATH" \
GNOME_WAYLAND_RELOAD_INJECTOR="$INJECTOR" \
    bash "$SCRIPT" --no-wait --token horner-proof "$REPO"

cmp -s "$SOURCE/extension.js" "$INSTALLED/extension.js"
cmp -s "$SOURCE/asset.txt" "$INSTALLED/asset.txt"
grep -Fx -- '--no-wait --token horner-proof test@example.com' "$CALLS" >/dev/null

echo 'DISABLED' > "$STATE_FILE"
: > "$CALLS"
set +e
PATH="$FAKEBIN:$PATH" \
GNOME_WAYLAND_RELOAD_INJECTOR="$INJECTOR" \
    bash "$SCRIPT" "$REPO" >"$TMP/disabled.out" 2>"$TMP/disabled.err"
rc=$?
set -e

[ "$rc" -eq 2 ]
grep -F 'must already be ACTIVE' "$TMP/disabled.err" >/dev/null
[ ! -s "$CALLS" ]

mkdir -p "$REPO/another-extension"
cat > "$REPO/another-extension/metadata.json" <<'JSON'
{"uuid":"other@example.com"}
JSON
printf 'export default class OtherExtension {}\n' > "$REPO/another-extension/extension.js"

echo 'ACTIVE' > "$STATE_FILE"
set +e
PATH="$FAKEBIN:$PATH" \
GNOME_WAYLAND_RELOAD_INJECTOR="$INJECTOR" \
    bash "$SCRIPT" "$REPO" >"$TMP/multiple.out" 2>"$TMP/multiple.err"
rc=$?
set -e

[ "$rc" -eq 2 ]
grep -F 'multiple extension metadata.json files found' "$TMP/multiple.err" >/dev/null

echo 'ok - deploy and live reload accepts an already ACTIVE installed extension'
