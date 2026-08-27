#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mock_bin="$TMP/bin"
repo="$TMP/horner"
host_config="$TMP/host-config"
runtime="$TMP/runtime"
mkdir -p "$mock_bin" "$repo/desktop" "$host_config/horner" "$host_config/dconf" "$runtime"
printf '%s\n' '{"uuid":"horner@ryanraposo.github.io","shell-version":["50"]}' > "$repo/desktop/metadata.json"
printf '%s\n' 'export default class Extension {}' > "$repo/desktop/extension.js"
printf '%s\n' '{"mode":"test"}' > "$host_config/horner/desktop.json"
printf '%s\n' 'host-dconf-sentinel' > "$host_config/dconf/user"

cat > "$mock_bin/gnome-shell" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
    --help) printf '%s\n' 'Usage: gnome-shell --devkit --wayland --debug-control'; exit 0 ;;
    --version) printf '%s\n' 'GNOME Shell 50.1'; exit 0 ;;
esac
{
    printf 'args=%s\n' "$*"
    printf 'extension=%s\n' "$(readlink "$XDG_DATA_HOME/gnome-shell/extensions/horner@ryanraposo.github.io")"
    printf 'config=%s\n' "$(readlink "$XDG_CONFIG_HOME/horner")"
    if [ -d "$XDG_CONFIG_HOME/dconf" ] && [ ! -L "$XDG_CONFIG_HOME/dconf" ]; then
        printf 'dconf=isolated\n'
    fi
} > "$DEVKIT_SHELL_LOG"
sleep 0.2
SH

cat > "$mock_bin/gnome-extensions" <<'SH'
#!/usr/bin/env bash
case "$1" in
    info)
        printf '%s\n' 'horner@ryanraposo.github.io' '  State: ACTIVE'
        ;;
    enable)
        printf '%s\n' "$*" >> "$DEVKIT_EXTENSION_LOG"
        ;;
esac
SH

cat > "$mock_bin/dbus-run-session" <<'SH'
#!/usr/bin/env bash
printf 'daemon_config=%s\n' "$XDG_CONFIG_HOME" > "$DEVKIT_DBUS_LOG"
[ "$XDG_CONFIG_HOME" != "$HOST_CONFIG_HOME" ]
exec "$@"
SH

cat > "$mock_bin/dpkg-query" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'install ok installed'
SH
chmod +x "$mock_bin/"*

run_debug() {
    local label="$1"
    shift
    PATH="$mock_bin:/usr/bin:/bin" \
    XDG_CONFIG_HOME="$host_config" XDG_RUNTIME_DIR="$runtime" \
    HOST_CONFIG_HOME="$host_config" DEVKIT_DBUS_LOG="$TMP/dbus-$label.log" \
    DEVKIT_SHELL_LOG="$TMP/shell-$label.log" DEVKIT_EXTENSION_LOG="$TMP/extensions-$label.log" \
        "$ROOT/scripts/debug-extension.sh" "$@" >"$TMP/out-$label" 2>"$TMP/err-$label"
}

assert_debug() {
    local label="$1"
    grep -qx "extension=$repo/desktop" "$TMP/shell-$label.log"
    grep -qx "config=$host_config/horner" "$TMP/shell-$label.log"
    grep -qx 'dconf=isolated' "$TMP/shell-$label.log"
    grep -q "daemon_config=$runtime/gnome-wayland-reload/devkit\." "$TMP/dbus-$label.log"
    grep -q 'args=--devkit --wayland --debug-control' "$TMP/shell-$label.log"
    grep -qx 'enable horner@ryanraposo.github.io' "$TMP/extensions-$label.log"
    grep -q 'uuid=horner@ryanraposo.github.io shell=50' "$TMP/err-$label"
    grep -q 'state=ACTIVE' "$TMP/err-$label"
}

run_debug path "$repo"
assert_debug path
(
    cd "$repo"
    run_debug cwd
)
assert_debug cwd

grep -qx 'host-dconf-sentinel' "$host_config/dconf/user"
test -z "$(find "$runtime/gnome-wayland-reload" -mindepth 1 -maxdepth 1 -print -quit)"

printf 'ok - repo root discovers nested extension directory\n'
printf 'ok - omitted source defaults to the current repo\n'
printf 'ok - checkout is staged only in the nested XDG data home\n'
printf 'ok - ordinary Horner config is shared while dconf is isolated\n'
printf 'ok - extension is enabled and verified ACTIVE on nested session bus\n'
printf 'ok - temporary devkit staging is removed after exit\n'
