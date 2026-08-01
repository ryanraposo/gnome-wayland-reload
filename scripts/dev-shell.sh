#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: dev-shell.sh [GNOME_SHELL_ARGUMENT...]

Launch a fresh GNOME 49+ development Shell in a nested Wayland window.
The nested session shares the user's home directory and is not a sandbox.
EOF
}

case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
esac

for command_name in dbus-run-session gnome-shell; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "error: required command not found: $command_name" >&2
        exit 1
    }
done

if ! gnome-shell --help 2>&1 | grep -q -- '--devkit'; then
    echo "error: this GNOME Shell does not advertise --devkit (GNOME 49+ required)" >&2
    exit 1
fi

if command -v dpkg-query >/dev/null 2>&1 &&
   ! dpkg-query -W -f='${Status}' mutter-dev-bin 2>/dev/null | grep -q 'install ok installed'; then
    echo "error: Ubuntu's nested Shell development runner is not installed" >&2
    echo "mutter-dev-bin enables fresh GNOME Shell test sessions in a window," >&2
    echo "so edited extension code can load without restarting your real desktop." >&2
    echo "install it with: pkexec apt-get install -y mutter-dev-bin" >&2
    exit 1
fi

echo "Starting a disposable nested GNOME Shell; close its window to stop it." >&2
exec dbus-run-session env \
    G_MESSAGES_DEBUG="${G_MESSAGES_DEBUG:-all}" \
    SHELL_DEBUG="${SHELL_DEBUG:-all}" \
    gnome-shell --devkit --wayland "$@"
