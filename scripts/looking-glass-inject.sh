#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOTSWAP="${GNOME_WAYLAND_RELOAD_HOTSWAP:-$SCRIPT_DIR/looking-glass-hotswap.sh}"
DRIVER="${GNOME_WAYLAND_RELOAD_DRIVER:-$SCRIPT_DIR/lg-autohotswap.py}"
STATE_ROOT="${GNOME_WAYLAND_RELOAD_HOTSWAP_HOME:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/gnome-wayland-reload/hotswap}"

usage() {
    cat <<'USAGE'
Usage:
  looking-glass-inject.sh [--no-wait] [--timeout SECONDS] [--token TOKEN] UUID
  looking-glass-inject.sh --verify-receipt RECEIPT

Prepare one immutable payload, submit it exactly once through GNOME Looking
Glass, record the execution boundary, and verify the journal-backed receipt.

Options:
  --no-wait                 Verify once without polling.
  --timeout SECONDS         Journal polling budget (default: 45).
  --token TOKEN             Deterministic token for tests or audit trails.
  --verify-receipt RECEIPT  Re-check an existing EXECUTED/INCONCLUSIVE receipt.
  --help                    Show this usage text.

Exit codes:
  0  Verified.
  1  Exact invocation ran and reported failure.
  2  Usage, dependency, or integrity failure before submission.
  3  Submission may have run, but proof is still inconclusive.
USAGE
}

fail() { printf 'error: %s\n' "$*" >&2; exit 2; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

prepare_token="${HOTSWAP_TOKEN:-}"
wait_mode=true
timeout_seconds=45
verify_receipt=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-wait) wait_mode=false; shift ;;
        --timeout)
            [ "$#" -ge 2 ] || fail "--timeout requires a value"
            timeout_seconds="$2"
            case "$timeout_seconds" in
                ''|*[!0-9]*) fail "--timeout must be a non-negative integer" ;;
            esac
            shift 2
            ;;
        --token)
            [ "$#" -ge 2 ] || fail "--token requires a value"
            prepare_token="$2"
            shift 2
            ;;
        --verify-receipt)
            [ "$#" -ge 2 ] || fail "--verify-receipt requires a path"
            verify_receipt="$2"
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        --*) fail "unknown option: $1" ;;
        *) break ;;
    esac
done

require_command python3
[ -x "$HOTSWAP" ] || fail "hot-swap helper not executable: $HOTSWAP"

if [ -n "$verify_receipt" ]; then
    [ "$#" -eq 0 ] || fail "--verify-receipt does not accept a UUID"
    exec "$HOTSWAP" verify "$verify_receipt"
fi

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
UUID="$1"
[ -x "$DRIVER" ] || fail "Looking Glass driver not executable: $DRIVER"

mkdir -p "$STATE_ROOT"
chmod 700 "$STATE_ROOT"
work_dir="$(mktemp -d "$STATE_ROOT/inject.XXXXXX")"
chmod 700 "$work_dir"
payload_file="$work_dir/payload.js"
submission_state="$work_dir/submission.state"
trap 'rm -rf -- "$work_dir"' EXIT

prepare_args=(prepare)
[ -z "$prepare_token" ] || prepare_args+=(--token "$prepare_token")
prepare_args+=("$UUID")

printf '[inject] preparing immutable payload for %s ...\n' "$UUID" >&2
prepared_json="$(GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$STATE_ROOT" \
    "$HOTSWAP" "${prepare_args[@]}")"
receipt="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["receipt_file"])' "$prepared_json")"
token="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["token"])' "$prepared_json")"
marker="[gnome-wayland-reload:${token}]"
GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$STATE_ROOT" \
    "$HOTSWAP" show "$receipt" > "$payload_file"
chmod 600 "$payload_file"

printf '[inject] receipt=%s token=%s\n' "$receipt" "$token" >&2
driver_rc=0
driver_out="$("$DRIVER" --submission-state "$submission_state" \
    "$receipt" "$marker" "$payload_file" 2>&1)" || driver_rc=$?
printf '%s\n' "$driver_out" >&2

submission=""
[ ! -f "$submission_state" ] || submission="$(tr -d '[:space:]' < "$submission_state")"
case "$submission" in
    SUBMITTING|SUBMITTED)
        printf '[inject] submission boundary crossed (%s); preserving one-shot receipt\n' \
            "$submission" >&2
        "$HOTSWAP" executed "$receipt" >/dev/null
        ;;
    *)
        "$HOTSWAP" abort "$receipt" >/dev/null 2>&1 || true
        if [ "$driver_rc" -ne 0 ]; then
            printf '[inject] payload was not submitted; receipt aborted safely\n' >&2
            exit 2
        fi
        fail "driver returned success without a durable submission witness"
        ;;
esac

if [ "$driver_rc" -ne 0 ]; then
    printf '[inject] driver failed after submission; verify this receipt and never repeat the payload\n' >&2
fi

verify_once() {
    local rc=0
    "$HOTSWAP" verify "$receipt" >/dev/null || rc=$?
    return "$rc"
}

verify_rc=3
if $wait_mode; then
    waited=0
    while [ "$waited" -lt "$timeout_seconds" ]; do
        verify_rc=0
        verify_once || verify_rc=$?
        case "$verify_rc" in
            0|1) break ;;
            3) sleep 1; waited=$((waited + 1)) ;;
            *) exit "$verify_rc" ;;
        esac
    done
else
    verify_rc=0
    verify_once || verify_rc=$?
fi

case "$verify_rc" in
    0)
        printf '[inject] VERIFIED — exact token proof and ACTIVE state confirmed\n' >&2
        python3 -m json.tool "$receipt"
        ;;
    1)
        printf '[inject] FAILED — inspect rollback; do not repeat the payload\n' >&2
        python3 -m json.tool "$receipt" >&2 || true
        ;;
    3)
        printf '[inject] INCONCLUSIVE — re-check this same receipt; do not execute again:\n' >&2
        printf '  %s --verify-receipt %q\n' "$0" "$receipt" >&2
        python3 -m json.tool "$receipt" >&2 || true
        ;;
esac
exit "$verify_rc"
