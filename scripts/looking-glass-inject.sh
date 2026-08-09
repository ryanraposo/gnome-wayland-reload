#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOTSWAP="${GNOME_WAYLAND_RELOAD_HOTSWAP:-$SCRIPT_DIR/looking-glass-hotswap.sh}"
DRIVER_SCRIPT="${GNOME_WAYLAND_RELOAD_DRIVER:-$SCRIPT_DIR/lg-autohotswap.py}"

usage() {
    cat <<'USAGE'
Usage:
  looking-glass-inject.sh [--no-wait] [--token TOKEN] UUID

Automate the receipt-backed hot-swap payload through GNOME Looking Glass.

The injector records EXECUTED only after the GUI driver explicitly reports
injected=true. A failed or ambiguous driver run is never silently promoted to
EXECUTED and must never be retried by blindly submitting the payload again.

Options:
  --no-wait   Skip journal polling; report verification status immediately.
  --token     Supply a deterministic token (for testing or audit trails).
  --help      Show this usage text.

Exit codes:
  0  Injected and verified ok=true
  1  Injection succeeded but proof/verification failed
  2  Usage, dependency, or pre-injection integrity error
  3  Injection or verification outcome is inconclusive; inspect/re-check, do not re-inject
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
[ -x "$HOTSWAP" ] || fail "hot-swap helper not found or not executable: $HOTSWAP"

prepare_args=(prepare)
if [ -n "$prepare_token" ]; then
    prepare_args+=(--token "$prepare_token")
fi
prepare_args+=("$UUID")

echo "[inject] preparing hot-swap payload for extension $UUID ..." >&2
STATE_ROOT="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/gnome-wayland-reload/hotswap"
PREPARED_JSON="$(
    GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$STATE_ROOT" \
        "$HOTSWAP" "${prepare_args[@]}"
)"

RECEIPT="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["receipt_file"])' "$PREPARED_JSON")"
TOKEN="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["token"])' "$PREPARED_JSON")"
MARKER="[gnome-wayland-reload:${TOKEN}]"
PAYLOAD="$(
    GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$STATE_ROOT" \
        "$HOTSWAP" show "$RECEIPT"
)" || {
    echo "[inject] SHOW FAILED — possible tamper or invalid receipt" >&2
    exit 2
}

echo "[inject] receipt=$RECEIPT token=$TOKEN marker=$MARKER" >&2

PAYLOAD_FILE="$(mktemp /tmp/lgi-payload-XXXXXX.js)"
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE"
cleanup() {
    rm -f "$PAYLOAD_FILE"
}
trap cleanup EXIT

abort_prepared() {
    GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$STATE_ROOT" \
        "$HOTSWAP" abort "$RECEIPT" >/dev/null 2>&1 || true
}

if [ ! -x "$DRIVER_SCRIPT" ]; then
    echo "[inject] driver unavailable before any GUI submission: $DRIVER_SCRIPT" >&2
    abort_prepared
    exit 2
fi

echo "[inject] opening Looking Glass and submitting the prepared payload once ..." >&2

set +e
DRIVER_OUT="$(python3 "$DRIVER_SCRIPT" "$RECEIPT" "$MARKER" "$PAYLOAD_FILE" 2>&1)"
DRIVER_RC=$?
set -e

printf '%s\n' "$DRIVER_OUT" >&2
DR_INJECTED="$(printf '%s\n' "$DRIVER_OUT" | grep -E '^injected=(true|false)([[:space:]]|$)' | tail -n1 || true)"

if [ "$DRIVER_RC" -ne 0 ] || [ "$DR_INJECTED" != "injected=true" ]; then
    echo "[inject] INCONCLUSIVE — the GUI driver did not prove a one-shot submission." >&2
    echo "[inject] Do not submit the payload again merely because the driver failed." >&2
    echo "[inject] Inspect the exact marker before deciding whether execution happened:" >&2
    printf '[inject]   journalctl -b -o cat /usr/bin/gnome-shell | grep -- %q\n' "$MARKER" >&2
    echo "[inject] receipt=$RECEIPT remains PREPARED because execution was not proven." >&2
    exit 3
fi

echo "[inject] recording the proven one-shot submission ..." >&2
if ! GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$STATE_ROOT" \
    "$HOTSWAP" executed "$RECEIPT" >/dev/null; then
    echo "[inject] INCONCLUSIVE — payload submission was proven but the receipt could not advance." >&2
    echo "[inject] Never re-inject this payload. Preserve the receipt and inspect the exact marker." >&2
    echo "[inject] receipt=$RECEIPT marker=$MARKER" >&2
    exit 3
fi

PREPARED_AT="$(python3 - "$RECEIPT" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["prepared_at"])
PY
)"

if [ "$wait_mode" = true ]; then
    echo "[inject] polling Shell journal for proof marker $MARKER ..." >&2
    MAX_WAIT="${GNOME_WAYLAND_RELOAD_MAX_WAIT:-45}"
    WAITED=0

    while [ "$WAITED" -lt "$MAX_WAIT" ]; do
        PROOF_LINE="$(
            journalctl --since "$PREPARED_AT" -b -o cat /usr/bin/gnome-shell 2>/dev/null \
                | grep -- "$MARKER" | tail -n1
        )" || true

        if [ -n "$PROOF_LINE" ]; then
            VERIFY_RC=0
            GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$STATE_ROOT" \
                "$HOTSWAP" verify "$RECEIPT" >/dev/null 2>&1 || VERIFY_RC=$?

            case "$VERIFY_RC" in
                0)
                    echo "[inject] VERIFIED — extension hot-swap completed successfully" >&2
                    python3 -m json.tool "$RECEIPT" 2>/dev/null || cat "$RECEIPT"
                    exit 0
                    ;;
                1)
                    echo "[inject] FAILED — the exact invocation ran but replacement failed" >&2
                    cat "$RECEIPT" >&2
                    exit 1
                    ;;
                3)
                    sleep 2
                    WAITED=$((WAITED + 2))
                    continue
                    ;;
                *)
                    echo "[inject] verification helper returned unexpected status $VERIFY_RC" >&2
                    exit 2
                    ;;
            esac
        fi

        sleep 1
        WAITED=$((WAITED + 1))
    done

    echo "[inject] timeout after ${MAX_WAIT}s; running final verification against the same receipt ..." >&2
fi

FINAL_RC=0
GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$STATE_ROOT" \
    "$HOTSWAP" verify "$RECEIPT" >/dev/null 2>&1 || FINAL_RC=$?

case "$FINAL_RC" in
    0)
        echo "[inject] VERIFIED — extension hot-swap completed" >&2
        python3 -m json.tool "$RECEIPT" 2>/dev/null || cat "$RECEIPT"
        exit 0
        ;;
    1)
        echo "[inject] FAILED — replacement or rollback issue detected" >&2
        cat "$RECEIPT" >&2
        exit 1
        ;;
    3)
        echo "[inject] INCONCLUSIVE — exact proof is not yet confirmed." >&2
        echo "[inject] Re-check this same receipt; do not create or inject a new transaction:" >&2
        printf '[inject]   %q verify %q\n' "$HOTSWAP" "$RECEIPT" >&2
        printf '[inject]   journalctl -b -o cat /usr/bin/gnome-shell | grep -- %q\n' "$MARKER" >&2
        cat "$RECEIPT" >&2
        exit 3
        ;;
    *)
        echo "[inject] verification helper returned unexpected status $FINAL_RC" >&2
        exit 2
        ;;
esac
