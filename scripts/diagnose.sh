#!/usr/bin/env bash
set -u

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

if command -v dpkg-query >/dev/null 2>&1 &&
   dpkg-query -W -f='${Status}' mutter-dev-bin 2>/dev/null | grep -q 'install ok installed'; then
    report mutter-dev-bin installed
else
    report mutter-dev-bin 'not installed (needed for devkit on Ubuntu)'
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

if [ "$status" -eq 0 ]; then
    report summary 'GNOME Wayland extension tools are available'
else
    report summary 'environment mismatch or required tools missing'
fi

exit "$status"
