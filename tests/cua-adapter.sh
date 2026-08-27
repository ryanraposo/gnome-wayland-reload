#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0
pass() { printf 'ok - %s\n' "$1"; ((passed++)) || true; }
fail() { printf 'not ok - %s\n' "$1" >&2; ((failed++)) || true; }
assert() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

mock_bin="$TMP/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/cua-driver" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CUA_LOG"
case "$1" in
    status) exit 0 ;;
    health_report)
        if [ "${MOCK_WAYLAND_READY:-false}" = true ]; then
            printf '%s\n' '{"overall":"ok","checks":[{"name":"wayland_backend","status":"pass"}]}'
        else
            printf '%s\n' '{"overall":"ok","checks":[{"name":"wayland_backend","status":"skip"}]}'
        fi
        ;;
    *) printf '%s\n' '{}' ;;
esac
SH

cat > "$mock_bin/ydotool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$YDOTOOL_LOG"
SH
cat > "$mock_bin/journalctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '[gnome-wayland-reload-preflight:adapter-token]'
SH
chmod +x "$mock_bin/"*

payload_file="$TMP/payload.js"
receipt="$TMP/receipt.json"
marker='[gnome-wayland-reload:adapter-token]'
printf '%s' "const uuid = 'test@example.com'; const marker = '$marker'; const proof = marker; JSON.stringify(proof)" > "$payload_file"
python3 - "$payload_file" "$receipt" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

payload = Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text(json.dumps({
    "status": "PREPARED",
    "token": "adapter-token",
    "marker": "[gnome-wayland-reload:adapter-token]",
    "prepared_at": "2026-08-12T00:00:00+00:00",
    "payload_sha256": hashlib.sha256(payload.encode()).hexdigest(),
}))
PY

state="$TMP/submission.state"
CUA_LOG="$TMP/cua.log" YDOTOOL_LOG="$TMP/ydotool.log" \
GNOME_WAYLAND_RELOAD_CUA_DRIVER="$mock_bin/cua-driver" \
GNOME_WAYLAND_RELOAD_YDOTOOL="$mock_bin/ydotool" \
PATH="$mock_bin:/usr/bin:/bin" \
XDG_SESSION_TYPE=wayland \
    python3 "$ROOT/scripts/lg-autohotswap.py" --submission-state "$state" \
    "$receipt" "$marker" "$payload_file" > "$TMP/driver.out"
assert "Wayland adapter durably records one submission" \
    grep -qx 'SUBMITTED' "$state"
assert "Wayland adapter chooses ydotool when native compositor input is absent" \
    grep -q 'backend=ydotool' "$TMP/driver.out"
assert "focus-safe open span precedes payload and final Enter" sh -c \
    'grep -q "^key 56:1 60:1 60:0 56:0$" "$1" &&
     grep -q "^type --key-delay 1 lg$" "$1" &&
     grep -q "^type --key-delay 1 console.log.*gnome-wayland-reload-preflight:adapter-token" "$1" &&
     grep -q "^type --key-delay 1 const uuid" "$1" &&
     test "$(grep -c "^key 28:1 28:0$" "$1")" -eq 3' \
    sh "$TMP/ydotool.log"
assert "adapter never invokes clipboard tools" sh -c \
    '! grep -Eq "wl-copy|wl-paste|clipboard_(read|write)" "$1"' sh "$ROOT/scripts/lg-autohotswap.py"

before_lines="$(wc -l < "$TMP/ydotool.log")"
printf 'tamper' >> "$payload_file"
tamper_rc=0
CUA_LOG="$TMP/cua.log" YDOTOOL_LOG="$TMP/ydotool.log" \
GNOME_WAYLAND_RELOAD_CUA_DRIVER="$mock_bin/cua-driver" \
GNOME_WAYLAND_RELOAD_YDOTOOL="$mock_bin/ydotool" \
PATH="$mock_bin:/usr/bin:/bin" \
XDG_SESSION_TYPE=wayland \
    python3 "$ROOT/scripts/lg-autohotswap.py" --submission-state "$TMP/tamper.state" \
    "$receipt" "$marker" "$payload_file" >/dev/null 2>&1 || tamper_rc=$?
assert "tampered payload fails before any desktop input" sh -c \
    'test "$1" -ne 0 && test "$2" -eq "$(wc -l < "$3")"' \
    sh "$tamper_rc" "$before_lines" "$TMP/ydotool.log"

printf '%s' "const uuid = 'test@example.com'; const marker = '$marker'; const proof = marker; JSON.stringify(proof)" > "$payload_file"
python3 - "$payload_file" "$receipt" <<'PY'
import hashlib, json, sys
from pathlib import Path
p = Path(sys.argv[1]).read_text()
Path(sys.argv[2]).write_text(json.dumps({
    "status": "PREPARED",
    "token": "adapter-token",
    "marker": "[gnome-wayland-reload:adapter-token]",
    "prepared_at": "2026-08-12T00:00:00+00:00",
    "payload_sha256": hashlib.sha256(p.encode()).hexdigest(),
}))
PY
CUA_LOG="$TMP/cua-native.log" YDOTOOL_LOG="$TMP/unused.log" \
MOCK_WAYLAND_READY=true GNOME_WAYLAND_RELOAD_INPUT=cua \
GNOME_WAYLAND_RELOAD_CUA_DRIVER="$mock_bin/cua-driver" \
GNOME_WAYLAND_RELOAD_YDOTOOL="$mock_bin/ydotool" \
PATH="$mock_bin:/usr/bin:/bin" \
XDG_SESSION_TYPE=wayland \
    python3 "$ROOT/scripts/lg-autohotswap.py" --submission-state "$TMP/native.state" \
    "$receipt" "$marker" "$payload_file" >/dev/null
assert "native-ready adapter uses current cua-driver CLI tools" sh -c \
    'grep -q "^start_session " "$1" &&
     grep -q "^hotkey " "$1" &&
     grep -q "^type_text " "$1" &&
     grep -q "^press_key " "$1" &&
     grep -q "^end_session " "$1"' sh "$TMP/cua-native.log"

cat > "$mock_bin/hotswap" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$HOTSWAP_LOG"
case "$1" in
    prepare)
        printf '{"receipt_file":"%s","token":"wrapper-token"}\n' "$MOCK_RECEIPT"
        ;;
    show)
        printf '%s' "const uuid = 'test@example.com'; const marker = '[gnome-wayland-reload:wrapper-token]'; const proof = marker; JSON.stringify(proof)"
        ;;
    abort|executed) ;;
    verify) exit 3 ;;
esac
SH
cat > "$mock_bin/driver" <<'SH'
#!/usr/bin/env bash
if [ "${MOCK_SUBMITTED:-false}" = true ]; then
    while [ "$1" != "--submission-state" ]; do shift; done
    printf 'SUBMITTING\n' > "$2"
fi
exit 5
SH
chmod +x "$mock_bin/hotswap" "$mock_bin/driver"
printf '{"status":"PREPARED"}\n' > "$TMP/wrapper-receipt.json"

wrapper_rc=0
HOTSWAP_LOG="$TMP/hotswap-pre.log" MOCK_RECEIPT="$TMP/wrapper-receipt.json" \
GNOME_WAYLAND_RELOAD_HOTSWAP="$mock_bin/hotswap" \
GNOME_WAYLAND_RELOAD_DRIVER="$mock_bin/driver" \
GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$TMP/wrapper-state-pre" \
    "$ROOT/scripts/looking-glass-inject.sh" --no-wait test@example.com \
    >/dev/null 2>&1 || wrapper_rc=$?
assert "pre-submit driver failure aborts the receipt" sh -c \
    'test "$1" -eq 2 && grep -qx abort "$2" && ! grep -qx executed "$2"' \
    sh "$wrapper_rc" "$TMP/hotswap-pre.log"

wrapper_rc=0
HOTSWAP_LOG="$TMP/hotswap-post.log" MOCK_RECEIPT="$TMP/wrapper-receipt.json" \
MOCK_SUBMITTED=true GNOME_WAYLAND_RELOAD_HOTSWAP="$mock_bin/hotswap" \
GNOME_WAYLAND_RELOAD_DRIVER="$mock_bin/driver" \
GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$TMP/wrapper-state-post" \
    "$ROOT/scripts/looking-glass-inject.sh" --no-wait test@example.com \
    >/dev/null 2>&1 || wrapper_rc=$?
assert "post-boundary driver failure records execution and never aborts" sh -c \
    'test "$1" -eq 3 && grep -qx executed "$2" && ! grep -qx abort "$2"' \
    sh "$wrapper_rc" "$TMP/hotswap-post.log"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
