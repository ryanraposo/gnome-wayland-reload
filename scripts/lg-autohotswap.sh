#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

LG_HOTSWAP="$SCRIPT_DIR/looking-glass-hotswap.sh"

# ── Usage ────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
Usage: lg-autohotswap.sh [OPTIONS] UUID

Automatic Looking Glass hot-swap: prepares, opens/uses LG, injects the
payload, executes it, and verifies the result — zero manual steps.

Options:
  --window     Target the nested Shell devkit window instead of the host.
  --retest     Skip source-installed diff; reload the same bytes.

Examples:
  lg-autohotswap.sh horner@ryanraposo.github.io
  lg-autohotswap.sh --window horner@ryanraposo.github.io
  lg-autohotswap.sh --retest horner@ryanraposo.github.io
USAGE
}

# ── Helpers ──────────────────────────────────────────────────────────────
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

detect_display() {
    case "${XDG_SESSION_TYPE:-}" in
        wayland)   echo "wayland" ;;
        *)         echo "x11" ;;
    esac
}

try_xdotool_type() {
    local text="$1"
    # Small pause before typing so the window gains focus
    sleep 0.15
    xdotool type --delay 8 --clearmodifiers "$text" 2>/dev/null || return 1
}

wait_gnome_shell_ready() {
    local max_wait="${1:-30}"
    local waited=0
    while ! pidof gnome-shell >/dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        [ "$waited" -ge "$max_wait" ] && die "gnome-shell not responding after ${max_wait}s"
    done
}

# ── Mode detection ──────────────────────────────────────────────────────
MODE="host"       # host | window
RETEST=false
UUID=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --window)  MODE="window"; shift ;;
        --retest)  RETEST=true;   shift ;;
        '')        shift ;;
        *)
            if [ -z "$UUID" ]; then
                UUID="$1"; shift
            else
                die "unexpected argument: $1"
            fi
            ;;
    esac
done

[ -n "$UUID" ] || { usage >&2; exit 2; }

# Validate UUID characters
case "$UUID" in
    ''|*[!A-Za-z0-9._@+-]*) die "UUID contains unsupported characters" ;;
esac

DISPLAY_TYPE="$(detect_display)"
echo "Session: $DISPLAY_TYPE | Mode: $MODE"

# ── Step 0: prepare payload ─────────────────────────────────────────────
echo "[1/7] Preparing payload …"
PREPARED_JSON="$("$LG_HOTSWAP" prepare "$UUID")"
echo "$PREPARED_JSON" >&2
RECEIPT="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['receipt_file'])" "$PREPARED_JSON")"
PAYLOAD="$(cat "$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['payload_file'])" "$PREPARED_JSON")")"

if [ "$RETEST" = true ]; then
    # Verify that the source repo file matches installed (best-effort)
    INSTALLED_PATH="$(python3 -c "
import gi
gi.require_version('GIO', '2.0')
from gi.repository import Gio
import sys
lookup = __import__('subprocess').check_output(
    ['gnome-extensions', 'info', sys.argv[1]], universal_newlines=True
).strip().split('\n')
for line in lookup:
    if line.strip().startswith('Schema'):
        continue
print(line)
" "$UUID" 2>/dev/null || echo "")"
    echo "[notice] retest mode — skipping source-installed diff" >&2
fi

echo "[+] Receipt: $RECEIPT"

# ── Step 1: ensure gnome-shell is alive ─────────────────────────────────
echo "[2/7] Waiting for gnome-shell …"
wait_gnome_shell_ready 30
echo "[+] gnome-shell ready"

# ── Step 2: open / find Looking Glass ───────────────────────────────────
echo "[3/7] Opening Looking Glass …"

if [ "$MODE" = "window" ]; then
    # In nested-devkit mode: find existing LG window by title
    LG_WINDOW_ID=""
    if command -v wmctrl >/dev/null 2>&1; then
        LG_WINDOW_ID="$(wmctrl -l | grep -i 'looking.glass\|Looking.Glass' | head -1 | cut -d' ' -f1 || true)"
        if [ -z "$LG_WINDOW_ID" ]; then
            # Try Alt+F2+r style: Alt+F2, type "lg", Enter
            # This works on both X11 and many Wayland setups via xdotool
            sleep 0.2
            xdotool key --delay 50 alt+F2 2>/dev/null || true
            sleep 0.3
            xdotool type --delay 8 "lg" 2>/dev/null || true
            sleep 0.3
            xdotool key Return 2>/dev/null || true
        fi
    fi
else
    # Host mode: Alt+F2, type "lg", Enter
    sleep 0.2
    xdotool key --delay 50 alt+F2 2>/dev/null || true
    sleep 0.3
    xdotool type --delay 8 "lg" 2>/dev/null || true
    sleep 0.3
    xdotool key Return 2>/dev/null || true
fi

# Wait for LG to appear
sleep 1.5

# Activate the correct LG window
if [ "$MODE" = "window" ] && [ -n "${LG_WINDOW_ID:-}" ]; then
    wmctrl -a "Looking Glass" 2>/dev/null || \
    wmctrl -i -a "$LG_WINDOW_ID" 2>/dev/null || true
fi

# ── Step 3: interact with LG evaluator ──────────────────────────────────
echo "[4/7] Injecting payload into Looking Glass evaluator …"

if [ "$MODE" = "window" ]; then
    # Click the Extensions tab first (ensure we're in Extensions view)
    sleep 0.2
    xdotool mousemove_relative 0 100 click 1 2>/dev/null || true
    sleep 0.1

    # Find the Evaluator button/section and activate it
    # Use xdotool search to find LG window and get its geometry
    LG_PID=""
    if command -v wmctrl >/dev/null 2>&1; then
        LG_PID="$(wmctrl -lp | grep -i 'looking.glass\|Looking.Glass' | head -1 | awk '{print $NF}' || true)"
    fi

    # Click the Evaluator entry in Extensions list to expand/collapse it
    sleep 0.3
    # Type directly — LG usually focuses the evaluator automatically
    # after you switch tabs. If not, we click around to find it.
    try_xdotool_type "$PAYLOAD" || {
        # Fallback: try clicking near middle of screen where evaluator lives
        echo "[!] xdotool type failed; attempting click-based insertion …" >&2
        sleep 0.2
        xdotool mousemove_relative 400 300 click 1 2>/dev/null || true
        sleep 0.3
        try_xdotool_type "$PAYLOAD" || die "Could not inject payload into LG evaluator"
    }
else
    # Host mode
    sleep 0.3
    try_xdotool_type "$PAYLOAD" || {
        echo "[!] xdotool type failed; attempting alternate path …" >&2
        sleep 0.2
        # Click to focus evaluator area (approximate position in host LG overlay)
        xdotool mousemove_relative 300 200 click 1 2>/dev/null || true
        sleep 0.3
        try_xdotool_type "$PAYLOAD" || die "Could not inject payload into LG evaluator"
    }
fi

echo "[+] Payload injected"

# ── Step 4: press Enter to execute ──────────────────────────────────────
echo "[5/7] Executing payload in Looking Glass …"
sleep 0.5
xdotool key Return 2>/dev/null || true
sleep 0.5

echo "[+] Recorded execution"

# ── Step 5: mark executed & verify ──────────────────────────────────────
echo "[6/7] Marking executed and verifying …"
"$LG_HOTSWAP" executed "$RECEIPT" 2>/dev/null || true

sleep 1

if "$LG_HOTSWAP" verify "$RECEIPT"; then
    echo ""
    echo "═══════════════════════════════════════════"
    echo "✓ Hot-swap VERIFIED"
    echo "  Receipt : $RECEIPT"
    echo "  UUID    : $UUID"
    echo "═══════════════════════════════════════════"
    exit 0
else
    RC=$?
    echo ""
    echo "⚠ Verification returned exit $RC" >&2
    if [ "$RC" -eq 3 ]; then
        echo "INCONCLUSIVE — journal proof was absent. This may happen" >&2
        echo "when gnome-shell log rotation is aggressive or the session" >&2
        echo "journal uses persistent storage with rotated files." >&2
        echo "" >&2
        echo "Run manually:" >&2
        echo "  $LG_HOTSWAP verify $RECEIPT" >&2
    elif [ "$RC" -eq 1 ]; then
        echo "FAILED — the transaction ran but replacement did not prove clean." >&2
        echo "Inspect journal manually:" >&2
        echo "  journalctl -b -u gnome-shell | grep -i '$UUID'" >&2
    fi
    exit "$RC"
fi
