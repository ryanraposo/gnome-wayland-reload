#!/usr/bin/env bash
set -euo pipefail

NAME="gnome-wayland-reload"
AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
STATE_HOME="${GNOME_WAYLAND_RELOAD_STATE_HOME:-$HOME/.local/state/$NAME}"
MODE=both
RESTORE=false

usage() {
    cat <<'EOF'
Usage: uninstall.sh [--agents-only|--hermes-only] [--restore]

Remove managed gnome-wayland-reload skill copies. Removed copies are archived
under ~/.local/state/gnome-wayland-reload/removed/ rather than deleted.

  --agents-only  Remove only the ~/.agents copy
  --hermes-only  Remove only the ~/.hermes copy
  --restore       Restore unmanaged directories backed up by the latest install
  --help          Show this help
EOF
}

for arg in "$@"; do
    case "$arg" in
        --agents-only)
            [ "$MODE" = both ] || { echo "error: choose one removal scope" >&2; exit 2; }
            MODE=agents
            ;;
        --hermes-only)
            [ "$MODE" = both ] || { echo "error: choose one removal scope" >&2; exit 2; }
            MODE=hermes
            ;;
        --restore) RESTORE=true ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

stamp="$(date +%Y%m%d-%H%M%S)-$$"
removed_root="$STATE_HOME/removed/$stamp"
manifest="$STATE_HOME/backups/latest.tsv"

backup_for_target() {
    local target="$1"
    [ -f "$manifest" ] || return 1
    awk -F '\t' -v wanted="$target" '$1 == wanted { found = $2 } END { if (found) print found; else exit 1 }' "$manifest"
}

remove_target() {
    local label="$1"
    local target="$2"
    local archived backup

    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        echo "not installed: $target"
        return 0
    fi
    if [ ! -f "$target/.$NAME-managed" ]; then
        echo "refused: unmanaged directory left untouched: $target" >&2
        return 1
    fi

    mkdir -p "$removed_root"
    archived="$removed_root/$label"
    mv "$target" "$archived"
    echo "uninstalled: $target"
    echo "archived: $archived"

    if $RESTORE && backup="$(backup_for_target "$target")" &&
       { [ -e "$backup" ] || [ -L "$backup" ]; }; then
        mkdir -p "$(dirname "$target")"
        mv "$backup" "$target"
        echo "restored: $target"
    fi
}

result=0
case "$MODE" in
    both|agents)
        remove_target agents "$AGENTS_HOME/skills/$NAME" || result=1
        ;;
esac
case "$MODE" in
    both|hermes)
        remove_target hermes "$HERMES_HOME/skills/$NAME" || result=1
        ;;
esac

exit "$result"
