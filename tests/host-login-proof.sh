#!/usr/bin/env bash
set -euo pipefail

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
SCRIPT="${1:-$(cd "$(dirname "$0")/.." && pwd)/scripts/host-login-proof.sh}"
run_script() { bash "$SCRIPT" "$@"; }
HOME_DIR="$ROOT/home"
SOURCE="$ROOT/source"
INSTALLED="$HOME_DIR/.local/share/gnome-shell/extensions/test@example.com"
STATE="$ROOT/state"
BIN="$ROOT/bin"
MOCK_STATE="$ROOT/mock-state"
mkdir -p "$HOME_DIR" "$SOURCE" "$INSTALLED" "$BIN" "$MOCK_STATE"

cat > "$SOURCE/metadata.json" <<'JSON'
{"uuid":"test@example.com","name":"Test","shell-version":["50"]}
JSON
cat > "$SOURCE/extension.js" <<'JS'
export default class TestExtension {
    enable() {}
    disable() {}
}
JS
printf 'old installed bytes\n' > "$INSTALLED/extension.js"
printf 'test@example.com\n' > "$MOCK_STATE/enabled"
printf 'ACTIVE\n' > "$MOCK_STATE/state"

cat > "$BIN/gnome-extensions" <<'SH'
#!/usr/bin/env bash
case "$1" in
    info)
        printf 'UUID: %s\nPath: %s\nState: %s\n' "$2" "$MOCK_INSTALLED" "$(cat "$MOCK_STATE/state")"
        ;;
    list)
        if [ "${2:-}" = --enabled ]; then cat "$MOCK_STATE/enabled"; fi
        ;;
    enable)
        printf 'ACTIVE\n' > "$MOCK_STATE/state"
        grep -Fxq "$2" "$MOCK_STATE/enabled" || printf '%s\n' "$2" >> "$MOCK_STATE/enabled"
        ;;
    disable)
        printf 'INACTIVE\n' > "$MOCK_STATE/state"
        grep -Fxv "$2" "$MOCK_STATE/enabled" > "$MOCK_STATE/enabled.tmp" || true
        mv "$MOCK_STATE/enabled.tmp" "$MOCK_STATE/enabled"
        ;;
esac
SH
cat > "$BIN/journalctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_JOURNAL:-}"
SH
chmod +x "$BIN/"*

export HOME="$HOME_DIR"
export PATH="$BIN:/usr/bin:/bin"
export MOCK_INSTALLED="$INSTALLED"
export MOCK_STATE
export GNOME_WAYLAND_RELOAD_LOGIN_PROOF_HOME="$STATE"
export GNOME_WAYLAND_RELOAD_SHELL_IDENTITY_OVERRIDE="shell-before"

prepare_out="$(run_script prepare "$SOURCE")"
receipt="$(cat "$STATE/latest")"
marker="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["marker"])' "$receipt")"

grep -q '^prepared: test@example.com$' <<< "$prepare_out"
grep -Fq "$marker" "$INSTALLED/extension.js"
! grep -Fq "$marker" "$SOURCE/extension.js"
test -f "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["backup_dir"])' "$receipt")/installed/extension.js"
test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$receipt")" = PREPARED_LOGOUT

before_rc=0
run_script verify "$receipt" >/dev/null 2>&1 || before_rc=$?
test "$before_rc" -eq 2

export GNOME_WAYLAND_RELOAD_SHELL_IDENTITY_OVERRIDE="shell-after"
export MOCK_JOURNAL="noise\n$marker\n"
run_script verify "$receipt" > "$ROOT/verify.out"
grep -q '^VERIFIED:' "$ROOT/verify.out"
test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$receipt")" = VERIFIED
cmp -s "$SOURCE/extension.js" "$INSTALLED/extension.js"

# A second preparation snapshots the current install, then restore returns it.
printf 'current-before-second-test\n' > "$INSTALLED/current.txt"
export GNOME_WAYLAND_RELOAD_SHELL_IDENTITY_OVERRIDE="shell-third"
run_script prepare "$SOURCE" >/dev/null
receipt2="$(cat "$STATE/latest")"
rm -f "$INSTALLED/current.txt"
run_script restore "$receipt2" >/dev/null
test -f "$INSTALLED/current.txt"
test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$receipt2")" = RESTORED

# A symlinked development install is snapshotted, replaced for proof, then restored.
rm -rf "$INSTALLED"
ln -s "$SOURCE" "$INSTALLED"
export GNOME_WAYLAND_RELOAD_SHELL_IDENTITY_OVERRIDE="shell-four"
run_script prepare "$SOURCE" >/dev/null
receipt3="$(cat "$STATE/latest")"
marker3="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["marker"])' "$receipt3")"
test ! -L "$INSTALLED"
export GNOME_WAYLAND_RELOAD_SHELL_IDENTITY_OVERRIDE="shell-five"
export MOCK_JOURNAL="$marker3"
run_script verify "$receipt3" >/dev/null
test -L "$INSTALLED"
test "$(readlink "$INSTALLED")" = "$SOURCE"

printf 'ok - host login proof prepares, verifies, cleans, and restores\n'
