#!/usr/bin/env bash
set -euo pipefail

[ "$#" -ge 3 ] || { echo "error: internal devkit session arguments are incomplete" >&2; exit 2; }
UUID="$1"
SOURCE_DIR="$2"
shift 2
[ "$1" = -- ] || { echo "error: internal devkit argument separator is missing" >&2; exit 2; }
shift

gnome-shell --devkit --wayland --debug-control "$@" &
shell_pid=$!

stop_shell() {
    if kill -0 "$shell_pid" 2>/dev/null; then
        kill "$shell_pid" 2>/dev/null || true
    fi
}
trap stop_shell HUP INT TERM

discovered=false
for _attempt in $(seq 1 200); do
    if gnome-extensions info "$UUID" >/dev/null 2>&1; then
        discovered=true
        break
    fi
    if ! kill -0 "$shell_pid" 2>/dev/null; then
        wait "$shell_pid"
        exit $?
    fi
    sleep 0.1
done

if ! $discovered; then
    printf '[devkit] error: %s was not discovered from %s\n' "$UUID" "$SOURCE_DIR" >&2
    stop_shell
    wait "$shell_pid" 2>/dev/null || true
    exit 1
fi

printf '[devkit] enabling %s in the nested Shell ...\n' "$UUID" >&2
if ! gnome-extensions enable "$UUID"; then
    printf '[devkit] enable command failed; the nested Shell remains available for logs and Looking Glass\n' >&2
fi

state="unknown"
for _attempt in $(seq 1 50); do
    state="$(gnome-extensions info "$UUID" 2>/dev/null | sed -n 's/^[[:space:]]*State:[[:space:]]*//p' | head -n1)"
    case "$state" in
        ACTIVE|ERROR|INACTIVE) break ;;
    esac
    sleep 0.1
done
printf '[devkit] extension=%s state=%s source=%s\n' "$UUID" "${state:-unknown}" "$SOURCE_DIR" >&2
printf '[devkit] Shell diagnostics continue below; use Alt+F2 then lg inside the nested window\n' >&2

set +e
wait "$shell_pid"
rc=$?
set -e
trap - HUP INT TERM
exit "$rc"
