#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: recycle-extension.sh [--enable-disabled] UUID

Disable and re-enable one currently enabled GNOME Shell extension.
This reruns lifecycle methods; it does not reload edited JavaScript.
EOF
}

enable_disabled=false
case "${1:-}" in
    --enable-disabled)
        enable_disabled=true
        shift
        ;;
    --help|-h)
        usage
        exit 0
        ;;
esac

uuid="${1:-}"
[ -n "$uuid" ] || { usage >&2; exit 2; }
[ "$#" -eq 1 ] || { usage >&2; exit 2; }

command -v gnome-extensions >/dev/null 2>&1 || {
    echo "error: gnome-extensions is not installed" >&2
    exit 1
}

if ! gnome-extensions info "$uuid" >/dev/null 2>&1; then
    echo "error: extension UUID not found: $uuid" >&2
    echo "enabled UUIDs:" >&2
    gnome-extensions list --enabled >&2 || true
    exit 1
fi

if ! gnome-extensions list --enabled | grep -Fqx -- "$uuid"; then
    if ! $enable_disabled; then
        echo "error: extension is disabled; refusing to change its state: $uuid" >&2
        echo "rerun with --enable-disabled only if enabling it is intentional" >&2
        exit 3
    fi
    gnome-extensions enable "$uuid"
    echo "enabled=$uuid"
    gnome-extensions info "$uuid"
    exit 0
fi

echo "disable=$uuid"
gnome-extensions disable "$uuid"
sleep "${GNOME_EXTENSION_RECYCLE_DELAY:-0.25}"
echo "enable=$uuid"
gnome-extensions enable "$uuid"
gnome-extensions info "$uuid"
echo "note=lifecycle recycled; loaded JavaScript was not replaced"
