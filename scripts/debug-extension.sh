#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION_RUNNER="$SCRIPT_DIR/devkit-session.sh"

usage() {
    cat <<'EOF'
Usage: debug-extension.sh SOURCE_OR_REPO [-- GNOME_SHELL_ARGUMENT...]

Discover one GNOME Shell extension below SOURCE_OR_REPO, expose that checkout
to an isolated nested GNOME devkit session, enable it there, and stream Shell
diagnostics until the devkit window closes.

The host Shell, host extension installation, and host enabled-extension setting
are not changed. Ordinary files under the user's config home remain visible;
the nested session gets its own temporary dconf database.
EOF
}

fail() { printf 'error: %s\n' "$*" >&2; exit 2; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    '') usage >&2; exit 2 ;;
esac

source_arg="$1"
shift
shell_args=()
if [ "$#" -gt 0 ]; then
    [ "$1" = -- ] || fail "GNOME Shell arguments must follow --"
    shift
    shell_args=("$@")
fi

for command_name in dbus-run-session gnome-shell gnome-extensions python3; do
    require_command "$command_name"
done
[ -x "$SESSION_RUNNER" ] || fail "devkit session runner not found: $SESSION_RUNNER"
[ -d "$source_arg" ] || fail "source directory does not exist: $source_arg"

if ! gnome-shell --help 2>&1 | grep -q -- '--devkit'; then
    fail "this GNOME Shell does not advertise --devkit (GNOME 49+ required)"
fi

if command -v dpkg-query >/dev/null 2>&1 &&
   ! dpkg-query -W -f='${Status}' mutter-dev-bin 2>/dev/null | grep -q 'install ok installed'; then
    printf 'error: Ubuntu\x27s nested Shell development runner is not installed\n' >&2
    printf 'install it with: pkexec apt-get install -y mutter-dev-bin\n' >&2
    exit 2
fi

source_root="$(cd "$source_arg" && pwd)"
if [ -f "$source_root/metadata.json" ]; then
    source_dir="$source_root"
else
    mapfile -t metadata_files < <(
        find "$source_root" -mindepth 1 -maxdepth 6 -type f -name metadata.json \
            -not -path '*/.git/*' \
            -not -path '*/node_modules/*' \
            -not -path '*/.venv/*' \
            -not -path '*/venv/*' \
            -print
    )
    case "${#metadata_files[@]}" in
        0) fail "no extension metadata.json found under $source_root" ;;
        1) source_dir="$(dirname "${metadata_files[0]}")" ;;
        *)
            printf 'error: multiple extension metadata.json files found; pass one extension directory:\n' >&2
            printf '  %s\n' "${metadata_files[@]}" >&2
            exit 2
            ;;
    esac
fi

[ -f "$source_dir/extension.js" ] || fail "extension.js not found beside $source_dir/metadata.json"

metadata_result="$(python3 - "$source_dir/metadata.json" "$(gnome-shell --version)" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    metadata = json.load(handle)

uuid = metadata.get("uuid")
if not isinstance(uuid, str) or not re.fullmatch(r"[A-Za-z0-9._@+-]+", uuid):
    raise SystemExit("metadata.json has an invalid uuid")

match = re.search(r"(\d+)(?:\.\d+)?", sys.argv[2])
if not match:
    raise SystemExit("could not determine the installed GNOME Shell major version")
major = match.group(1)
supported = metadata.get("shell-version", [])
if not isinstance(supported, list) or major not in [str(value).split(".", 1)[0] for value in supported]:
    raise SystemExit(f"extension does not declare GNOME Shell {major} support")

print(uuid)
print(major)
PY
)" || fail "extension metadata is incompatible with this Shell"
UUID="$(sed -n '1p' <<<"$metadata_result")"
SHELL_MAJOR="$(sed -n '2p' <<<"$metadata_result")"

runtime_parent="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/gnome-wayland-reload"
mkdir -p "$runtime_parent"
chmod 700 "$runtime_parent"
work_dir="$(mktemp -d "$runtime_parent/devkit.XXXXXX")"
chmod 700 "$work_dir"
trap 'rm -rf -- "$work_dir"' EXIT HUP INT TERM

data_home="$work_dir/data"
config_home="$work_dir/config"
extension_parent="$data_home/gnome-shell/extensions"
mkdir -p "$extension_parent" "$config_home/dconf"
ln -s "$source_dir" "$extension_parent/$UUID"

# Keep ordinary application config visible (Horner uses ~/.config/horner), but
# exclude dconf so the nested Shell cannot change host GNOME settings.
host_config="${XDG_CONFIG_HOME:-$HOME/.config}"
if [ -d "$host_config" ]; then
    while IFS= read -r -d '' entry; do
        name="$(basename "$entry")"
        [ "$name" = dconf ] && continue
        [ -e "$config_home/$name" ] || ln -s "$entry" "$config_home/$name"
    done < <(find "$host_config" -mindepth 1 -maxdepth 1 -print0)
fi

printf '[devkit] repo=%s\n' "$source_root" >&2
printf '[devkit] source=%s\n' "$source_dir" >&2
printf '[devkit] uuid=%s shell=%s\n' "$UUID" "$SHELL_MAJOR" >&2
printf '[devkit] host Shell and host extension settings are untouched\n' >&2
printf '[devkit] close the nested window to end this debug session\n' >&2

set +e
XDG_DATA_HOME="$data_home" \
XDG_CONFIG_HOME="$config_home" \
G_MESSAGES_DEBUG="${G_MESSAGES_DEBUG:-all}" \
SHELL_DEBUG="${SHELL_DEBUG:-all}" \
    dbus-run-session "$SESSION_RUNNER" "$UUID" "$source_dir" -- "${shell_args[@]}"
rc=$?
set -e
exit "$rc"
