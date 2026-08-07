#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOTSWAP="$SCRIPT_DIR/looking-glass-hotswap.sh"

usage() {
    cat <<'USAGE'
Usage:
  looking-glass-inject.sh [--no-wait] [--token TOKEN] UUID

Automate injecting the hot-swap payload into the live GNOME Shell via
Looking Glass. Chains prepare → show → drive Looking Glass GUI → executed → verify.

Options:
  --no-wait   Skip journal waiting; report verification status immediately.
  --token     Supply a deterministic token (for testing or audit trails).
  --help      Show this usage text.

Exit codes:
  0  Injected and verified ok=true
  1  Injection succeeded but proof/verification failed
  2  Usage, dependency, or integrity error
  3  Verification inconclusive; re-check may resolve
USAGE
}

fail() { printf 'error: %s\n' "$*" >&2; exit 2; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

prepare_token="${HOTSWAP_TOKEN:-}"
wait_mode=true

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-wait)
            wait_mode=false
            shift
            ;;
        --token)
            [ "$#" -ge 2 ] || fail "--token requires a value"
            prepare_token="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            fail "unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
UUID="$1"
require_command python3

# ── Step 1: Prepare receipt & extract payloads ───────────────────────
echo "[inject] preparing hot-swap payload for extension $UUID ..." >&2
STATE_ROOT="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/gnome-wayland-reload/hotswap"
PREPARED_JSON="$(GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$STATE_ROOT" \
    "$HOTSWAP" prepare ${prepare_token:+--token "$prepare_token"} "$UUID")"

RECEIPT="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["receipt_file"])' "$PREPARED_JSON")"
TOKEN="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["token"])' "$PREPARED_JSON")"
MARKER="[gnome-wayland-reload:${TOKEN}]"
PAYLOAD="$(GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$STATE_ROOT" \
    "$HOTSWAP" show "$RECEIPT")" || { echo "[inject] SHOW FAILED — possible tamper or invalid receipt" >&2; exit 2; }

echo "[inject] receipt=$RECEIPT token=$TOKEN marker=$MARKER" >&2

# Write payload to a temp file (avoids shell quoting issues with large JS)
PAYLOAD_FILE="$(mktemp /tmp/lgi-payload-XXXXXX.js)"
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE"
trap 'rm -f "$PAYLOAD_FILE"' EXIT

echo "[inject] opening Looking Glass …" >&2

# ── Step 2: Drive Looking Glass via cua-driver ──────────────────────
INJECT_STATUS=1  # default: assume failure until proven otherwise
cleanup_and_fail() {
    echo "[inject] cleaning up aborted workflow…" >&2
    "$HOTSWAP" abort "$RECEIPT" >/dev/null 2>&1 || true
    INJECT_STATUS=2
}

DRIVER_SCRIPT="$SCRIPT_DIR/lg-autohotswap.py"

if [ -x "$DRIVER_SCRIPT" ]; then
    DRIVER_OUT="$(python3 "$DRIVER_SCRIPT" "$RECEIPT" "$MARKER" "$PAYLOAD_FILE" 2>&1)" || {
        DRIVER_RC=$?
        echo "[inject] ✗ cua-driver injection failed (rc=$DRIVER_RC):" >&2
        echo "$DRIVER_OUT" >&2
        
        if [ $DRIVER_RC -ge 4 ]; then
            cleanup_and_fail
        else
            echo "[inject] falling back to manual guidance …" >&2
        fi
    }
    
    echo "$DRIVER_OUT" >&2
    
    DR_INJECTED="$(echo "$DRIVER_OUT" | tail -n1)"
    case "$DR_INJECTED" in
        injected=true) ;;
        *)
            echo "[inject] ✗ Injection reported failure:" >&2
            echo "$DRIVER_OUT" >&2
            cleanup_and_fail
            ;;
    esac

elif command -v cua >/dev/null 2>&1; then
    echo "[inject] ⚠ No lg-autohotswap.py found, attempting direct cua CLI …" >&2
    # Direct cua-cli fallback (minimal reliability)
    cua key alt+F2
    sleep 0.5
    cua type "lg"
    sleep 0.3
    cua key return
    sleep 1.0
    echo "[inject] opened Looking Glass; payload ready at $PAYLOAD_FILE" >&2
    # Cannot complete without element coordinates; fall through to manual guidance
else
    echo "[inject] ⚠ cua-driver not available on this host." >&2
fi

# ── Step 3: Record execution ─────────────────────────────────────────
echo "[inject] recording execution …" >&2
"$HOTSWAP" executed "$RECEIPT" > /dev/null 2>&1 || {
    echo "[inject] ⚠ WARNING: could not record execution — proceed with caution" >&2
}

if [ "$wait_mode" = true ]; then
    echo "[inject] polling Shell journal for proof marker $MARKER …" >&2
    MAX_WAIT=45
    WAITED=0
    
    PREPARED_AT="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d['prepared_at'])
" "$RECEIPT")"
    
    while [ "$WAITED" -lt "$MAX_WAIT" ]; do
        PROOF_LINE="$(journalctl --since "$PREPARED_AT" -b -o cat /usr/bin/gnome-shell 2>/dev/null \
            | grep -- "$MARKER" | tail -n1)" || true
        
        if [ -n "$PROOF_LINE" ]; then
            echo "[inject] proof candidate found in journal" >&2
            VERIFY_RC=0
            "$HOTSWAP" verify "$RECEIPT" > /dev/null 2>&1 || VERIFY_RC=$?
            
            case "$VERIFY_RC" in
                0)
                    echo "[inject] ✓ VERIFIED — extension hot-swap completed successfully" >&2
                    INJECT_STATUS=0
                    RECEIPT_DATA="$(cat "$RECEIPT")"
                    echo "$RECEIPT_DATA" | python3 -m json.tool 2>/dev/null || true
                    rm -f "$PAYLOAD_FILE"
                    exit 0
                    ;;
                1)
                    echo "[inject] ✗ FAILED — the exact invocation ran but replacement failed" >&2
                    echo "[inject] Receipt:" >&2
                    cat "$RECEIPT" >&2
                    rm -f "$PAYLOAD_FILE"
                    exit 1
                    ;;
                3)
                    # Inconclusive — keep waiting
                    sleep 2
                    WAITED=$((WAITED + 2))
                    continue
                    ;;
            esac
        fi
        
        sleep 1
        WAITED=$((WAITED + 1))
    done
    
    echo "[inject] ⚠ Timeout ($MAX_WAIT seconds); running final verification …" >&2
fi

# ── Step 4: Final verification attempt ───────────────────────────────
FINAL_RC=0
"$HOTSWAP" verify "$RECEIPT" > /dev/null 2>&1 || FINAL_RC=$?

case "$FINAL_RC" in
    0)
        echo "[inject] ✓ VERIFIED — extension hot-swap completed" >&2
        INJECT_STATUS=0
        ;;
    1)
        echo "[inject] ✗ FAILED — replacement or rollback issue detected" >&2
        INJECT_STATUS=1
        ;;
    3)
        echo "[inject] ⚠ INCONCLUSIVE — proof not yet confirmed in journal" >&2
        echo "[inject] Receipt state:" >&2
        cat "$RECEIPT" >&2
        echo "" >&2
        echo "[inject] Suggested next actions:" >&2
        echo "[inject]   1. Look for [$MARKER] in journal: journalctl -b -o cat /usr/bin/gnome-shell | grep -- '$MARKER'" >&2
        echo "[inject]   2. Check extension state: gnome-extensions info \"$UUID\"" >&2
        echo "[inject]   3. Re-run verify: scripts/looking-glass-inject.sh \"$UUID\"" >&2
        INJECT_STATUS=3
        ;;
esac

rm -f "$PAYLOAD_FILE"
exit $INJECT_STATUS
