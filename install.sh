#!/usr/bin/env bash
set -euo pipefail

NAME="gnome-wayland-reload"
REMOTE_BASE="${GNOME_WAYLAND_RELOAD_BASE_URL:-https://ryanraposo.github.io/gnome-wayland-reload}"
AGENTS_HOME="${AGENTS_HOME:-$HOME/.agents}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
STATE_HOME="${GNOME_WAYLAND_RELOAD_STATE_HOME:-$HOME/.local/state/$NAME}"
MODE=both
SKIP_DEVKIT=false

info()    { printf '\033[34m[INFO]\033[0m %s\n' "$*"; }
warn()    { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
success() { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
error()   { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

as_root() {
    if command -v pkexec >/dev/null 2>&1; then
        pkexec "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        error "A graphical PolicyKit helper (pkexec) or sudo is required for: $*"
    fi
}

devkit_installed() {
    command -v dpkg-query >/dev/null 2>&1 &&
        dpkg-query -W -f='${Status}' mutter-dev-bin 2>/dev/null |
        grep -q 'install ok installed'
}

devkit_version() {
    dpkg-query -W -f='${Version}' mutter-dev-bin 2>/dev/null || printf 'unknown'
}

usage() {
    cat <<'EOF'
Usage: install.sh [--agents-only|--hermes-only] [--skip-devkit]

Install the nested-Shell development runner and gnome-wayland-reload skills.

  --agents-only  Install only under ~/.agents/skills/
  --hermes-only  Install only under ~/.hermes/skills/
  --skip-devkit  Do not install Ubuntu's mutter-dev-bin package
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
        --skip-devkit)
            SKIP_DEVKIT=true
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
    error "Run this installer as the logged-in desktop user, not with sudo"
fi

printf '\n'
cat <<'MASCOT'
< ▄▄ @ ▄▄ >   @
   ▄▀ 0x0 ▀▄   █
    █  ───  █──█
    █  ███  █  █
     ▀▀   ▀▀   █
MASCOT
printf '\n'

info "Starting GNOME Wayland Reload setup..."
info "[1/3] Checking installer environment..."
success "Running as desktop user $(id -un)"

info "[2/3] Preparing fresh nested GNOME Shell sessions..."
if $SKIP_DEVKIT; then
    warn "Skipped mutter-dev-bin; nested Shell development may be unavailable"
elif devkit_installed; then
    success "mutter-dev-bin $(devkit_version) is already installed"
else
    command -v apt-get >/dev/null 2>&1 || \
        error "mutter-dev-bin is missing and apt-get is unavailable; rerun with --skip-devkit to install only the skills"
    info "mutter-dev-bin enables fresh GNOME Shell test sessions in a window."
    info "Edited extension code can load without logging out or restarting your real desktop."
    info "Installing mutter-dev-bin through a narrow graphical privilege prompt..."
    as_root apt-get install -y mutter-dev-bin || \
        error "Could not install mutter-dev-bin; ensure Ubuntu's universe repository is enabled"
    devkit_installed || error "Package installation completed but mutter-dev-bin could not be verified"
    success "Nested Shell development runner installed ($(devkit_version))"
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
    VERSION
    LICENSE
    agents/openai.yaml
    assets/mascot.txt
    runtimes/hermes-frontmatter.yaml
    references/gnome-50-debugging-notes.md
    references/skill-ux-contract.md
    scripts/recycle-extension.sh
    scripts/dev-shell.sh
    scripts/diagnose.sh
    scripts/looking-glass-hotswap.sh
    scripts/inspect-shell-source.sh
    scripts/check-update.sh
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

info "[3/3] Installing runtime-native skill bundles..."

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
    local parent temp_target old_target backup_target display_label

    case "$label" in
        agents) display_label="Agent Skill" ;;
        hermes) display_label="Hermes skill" ;;
    esac

    parent="$(dirname "$target")"
    mkdir -p "$parent"
    temp_target="$parent/.$NAME.tmp.$$.$label"
    temp_targets+=("$temp_target")
    mkdir "$temp_target"
    cp -a "$stage/." "$temp_target/"
    if [ "$label" = hermes ]; then
        awk 'BEGIN { body = 0 } /^---$/ { if (++markers == 2) { body = 1; next } } body' \
            "$stage/SKILL.md" > "$temp_target/.skill-body"
        cat "$stage/runtimes/hermes-frontmatter.yaml" "$temp_target/.skill-body" \
            > "$temp_target/SKILL.md"
        rm -f "$temp_target/.skill-body"
        rm -rf "$temp_target/agents" "$temp_target/runtimes"
    else
        rm -rf "$temp_target/runtimes"
    fi
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
            warn "Backed up $target → $backup_target"
        fi
    else
        mv "$temp_target" "$target"
    fi

    success "$display_label installed → ${target/$HOME/\~}"
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

printf '\n'
printf '     \033[1mAll done.\033[0m\n\n'
if $SKIP_DEVKIT; then
    printf '  \033[33mDev runner:\033[0m   skipped (--skip-devkit)\n'
else
    printf '  \033[33mDev runner:\033[0m   mutter-dev-bin %s\n' "$(devkit_version)"
fi
case "$MODE" in
    both|agents)
        launch_path="$AGENTS_HOME/skills/$NAME/scripts/dev-shell.sh"
        ;;
    hermes)
        launch_path="$HERMES_HOME/skills/$NAME/scripts/dev-shell.sh"
        ;;
esac
printf '  \033[33mLaunch:\033[0m       %s\n' "$launch_path"
printf '  \033[33mDiagnose:\033[0m     %s\n' "$(dirname "$launch_path")/diagnose.sh"
case "$MODE" in
    agents)
        printf '  \033[33mNext:\033[0m         Start a fresh agent session so it discovers the skill\n'
        ;;
    hermes)
        printf '  \033[33mNext:\033[0m         Run /reload-skills in Hermes, or start a fresh session\n'
        ;;
    both)
        printf '  \033[33mNext:\033[0m         Start a fresh agent session; Hermes can run /reload-skills now\n'
        ;;
esac
printf '\n'
cat <<'MASCOT'
@   < ▄▄ @ ▄▄ >
█    ▄▀ ^x^ ▀▄
█───█  ───  █
█   █  ███  █
█    ▀▀   ▀▀
MASCOT
printf '\n'
