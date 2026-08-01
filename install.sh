#!/usr/bin/env bash
set -euo pipefail

NAME="gnome-wayland-reload"
REMOTE_BASE="${GNOME_WAYLAND_RELOAD_BASE_URL:-https://ryanraposo.github.io/gnome-wayland-reload}"
AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
STATE_HOME="${GNOME_WAYLAND_RELOAD_STATE_HOME:-$HOME/.local/state/$NAME}"
MODE=both

usage() {
    cat <<'EOF'
Usage: install.sh [--agents-only|--hermes-only]

Install gnome-wayland-reload into both portable Agent Skills and Hermes.

  --agents-only  Install only under ~/.agents/skills/
  --hermes-only  Install only under ~/.hermes/skills/
  --help          Show this help
EOF
}

for arg in "$@"; do
    case "$arg" in
        --agents-only)
            [ "$MODE" = both ] || { echo "error: choose one install scope" >&2; exit 2; }
            MODE=agents
            ;;
        --hermes-only)
            [ "$MODE" = both ] || { echo "error: choose one install scope" >&2; exit 2; }
            MODE=hermes
            ;;
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

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "error: run this installer as the desktop user, not with sudo" >&2
    exit 1
fi

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SOURCE_DIR=""
if [ -n "$SCRIPT_SOURCE" ] && [ -f "$SCRIPT_SOURCE" ]; then
    candidate="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    if [ -f "$candidate/SKILL.md" ] && [ -f "$candidate/scripts/dev-shell.sh" ]; then
        SOURCE_DIR="$candidate"
    fi
fi

FILES=(
    SKILL.md
    LICENSE
    agents/openai.yaml
    assets/mascot.txt
    references/gnome-50-debugging-notes.md
    scripts/recycle-extension.sh
    scripts/dev-shell.sh
    scripts/diagnose.sh
    scripts/looking-glass-hotswap.sh
    scripts/inspect-shell-source.sh
)

stage="$(mktemp -d)"
temp_targets=()
cleanup() {
    rm -rf -- "$stage"
    local item
    for item in "${temp_targets[@]:-}"; do
        case "$item" in
            */."$NAME".tmp.*) rm -rf -- "$item" ;;
        esac
    done
}
trap cleanup EXIT

for relative in "${FILES[@]}"; do
    destination="$stage/$relative"
    mkdir -p "$(dirname "$destination")"
    if [ -n "$SOURCE_DIR" ]; then
        cp "$SOURCE_DIR/$relative" "$destination"
    else
        command -v curl >/dev/null 2>&1 || {
            echo "error: curl is required for a remote installation" >&2
            exit 1
        }
        curl -fsSL "$REMOTE_BASE/$relative" -o "$destination"
    fi
done

grep -q '^name: gnome-wayland-reload$' "$stage/SKILL.md" || {
    echo "error: downloaded skill failed identity validation" >&2
    exit 1
}
chmod +x "$stage/scripts/"*.sh

mkdir -p "$STATE_HOME/backups"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
backup_batch="$STATE_HOME/backups/$stamp"
latest_manifest="$STATE_HOME/backups/latest.tsv"
: > "$latest_manifest"

install_target() {
    local label="$1"
    local target="$2"
    local parent temp_target old_target backup_target

    parent="$(dirname "$target")"
    mkdir -p "$parent"
    temp_target="$parent/.$NAME.tmp.$$.$label"
    temp_targets+=("$temp_target")
    mkdir "$temp_target"
    cp -a "$stage/." "$temp_target/"
    printf 'managed-by=%s\nsource=https://github.com/ryanraposo/%s\n' \
        "$NAME" "$NAME" > "$temp_target/.$NAME-managed"

    if [ -e "$target" ] || [ -L "$target" ]; then
        if [ -f "$target/.$NAME-managed" ]; then
            old_target="$parent/.$NAME.old.$$.$label"
            mv "$target" "$old_target"
            if mv "$temp_target" "$target"; then
                rm -rf -- "$old_target"
            else
                mv "$old_target" "$target"
                return 1
            fi
        else
            backup_target="$backup_batch/$label"
            mkdir -p "$backup_batch"
            mv "$target" "$backup_target"
            printf '%s\t%s\n' "$target" "$backup_target" >> "$latest_manifest"
            if ! mv "$temp_target" "$target"; then
                mv "$backup_target" "$target"
                return 1
            fi
            echo "backup: $target -> $backup_target"
        fi
    else
        mv "$temp_target" "$target"
    fi

    echo "installed: $target"
}

case "$MODE" in
    both|agents)
        install_target agents "$AGENTS_HOME/skills/$NAME"
        ;;
esac
case "$MODE" in
    both|hermes)
        install_target hermes "$HERMES_HOME/skills/$NAME"
        ;;
esac

echo
cat <<'MASCOT'
@   < ▄▄ @ ▄▄ >
█    ▄▀ ^x^ ▀▄
█───█  ───  █
█   █  ███  █
█    ▀▀   ▀▀
MASCOT
echo
echo "GNOME Wayland Reload installed."
echo "Start a fresh agent session so it discovers the skill."
echo "In an active Hermes session, /reload-skills can rescan it immediately."
echo "For the nested GNOME 50 development loop, install mutter-dev-bin if needed."
