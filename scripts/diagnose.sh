#!/usr/bin/env bash
set -u

usage() {
    cat <<'USAGE'
Usage:
  diagnose.sh [UUID]

Report whether the current session can safely use the GNOME Wayland extension
workflow. With a UUID, also report that extension's manager state, installed
path, and recent Shell journal lines that mention it.
USAGE
}

case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
esac

[ "$#" -le 1 ] || { usage >&2; exit 2; }
uuid="${1:-}"
status=0

report() {
    printf '%-22s %s\n' "$1" "$2"
}

session_type="${XDG_SESSION_TYPE:-unknown}"
desktop="${XDG_CURRENT_DESKTOP:-unknown}"
shell_version="$(gnome-shell --version 2>/dev/null || printf 'not found')"

report session "$session_type"
report desktop "$desktop"
report gnome-shell "$shell_version"
report gnome-extensions "$(command -v gnome-extensions 2>/dev/null || printf 'not found')"
report dbus-run-session "$(command -v dbus-run-session 2>/dev/null || printf 'not found')"
report glib-compile-schemas "$(command -v glib-compile-schemas 2>/dev/null || printf 'not found')"
report cua-driver "$(command -v cua-driver 2>/dev/null || printf 'not found (host hot-swap automation unavailable)')"
report ydotool "$(command -v ydotool 2>/dev/null || printf 'not found (GNOME Wayland fallback unavailable)')"
report clipboard 'never used by this workflow'

if command -v dpkg-query >/dev/null 2>&1 &&
   dpkg-query -W -f='${Status}' mutter-dev-bin 2>/dev/null | grep -q 'install ok installed'; then
    report mutter-dev-bin installed
else
    report mutter-dev-bin 'not installed (needed for devkit on Ubuntu)'
    status=1
fi

case "$session_type" in
    wayland) ;;
    *) status=1 ;;
esac
case "$desktop" in
    *GNOME*|*gnome*) ;;
    *) status=1 ;;
esac
command -v gnome-shell >/dev/null 2>&1 || status=1
command -v gnome-extensions >/dev/null 2>&1 || status=1

if [ -n "$uuid" ]; then
    printf '\n'
    report extension "$uuid"

    if command -v gnome-extensions >/dev/null 2>&1; then
        info="$(LC_ALL=C gnome-extensions info "$uuid" 2>&1 || true)"
        state="$(sed -n 's/^[[:space:]]*State:[[:space:]]*//p' <<<"$info" | head -n1)"
        path="$(sed -n 's/^[[:space:]]*Path:[[:space:]]*//p' <<<"$info" | head -n1)"
        error_line="$(sed -n 's/^[[:space:]]*Error:[[:space:]]*//p' <<<"$info" | head -n1)"

        if [ -n "$state" ]; then
            report extension-state "$state"
            report extension-path "${path:-unknown}"
            [ -n "$error_line" ] && report extension-error "$error_line"
            [ "$state" = "ERROR" ] && status=1
        else
            report extension-state 'not found'
            status=1
        fi
    fi

    if command -v journalctl >/dev/null 2>&1; then
        journal="$(
            journalctl -b -o cat --no-pager /usr/bin/gnome-shell 2>/dev/null \
                | grep -F -i -- "$uuid" | tail -n 12
        )" || true
        if [ -n "$journal" ]; then
            printf '\nrecent Shell journal for %s:\n%s\n' "$uuid" "$journal"
        else
            printf '\nrecent Shell journal for %s: no matching lines\n' "$uuid"
        fi
    fi
fi

printf '\n'
if [ "$status" -eq 0 ]; then
    report summary 'GNOME Wayland extension tools are available'
else
    report summary 'environment mismatch, extension error, or required tools missing'
fi

exit "$status"
