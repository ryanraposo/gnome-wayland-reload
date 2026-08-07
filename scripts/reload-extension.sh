#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INJECTOR="${GNOME_WAYLAND_RELOAD_INJECTOR:-$SCRIPT_DIR/looking-glass-inject.sh}"

usage() {
    cat <<'USAGE'
Usage:
  reload-extension.sh [--no-wait] [--token TOKEN] [SOURCE_OR_REPO]

Deploy an already-active user extension from its source tree, then hot-swap its
live top-level extension.js through Looking Glass. SOURCE_OR_REPO defaults to .

If SOURCE_OR_REPO is a repository root, exactly one metadata.json is discovered
within six directory levels. Passing the extension directory directly is also
supported.

This command intentionally treats "already installed and ACTIVE" as the normal
live-reload case. It does not disable/enable the extension and does not log out.

Options:
  --no-wait      Pass through to looking-glass-inject.sh.
  --token TOKEN  Pass a deterministic transaction token through to the injector.
  --help         Show this usage text.
USAGE
}

fail() { printf 'error: %s\n' "$*" >&2; exit 2; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

inject_args=()
source_arg="."
source_seen=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-wait)
            inject_args+=("--no-wait")
            shift
            ;;
        --token)
            [ "$#" -ge 2 ] || fail "--token requires a value"
            inject_args+=("--token" "$2")
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            fail "unknown option: $1"
            ;;
        *)
            $source_seen && fail "expected one SOURCE_OR_REPO argument"
            source_arg="$1"
            source_seen=true
            shift
            ;;
    esac
done

require_command python3
require_command gnome-extensions
require_command cmp
require_command sha256sum

[ -d "$source_arg" ] || fail "source directory does not exist: $source_arg"
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
        0)
            fail "no extension metadata.json found under $source_root"
            ;;
        1)
            source_dir="$(dirname "${metadata_files[0]}")"
            ;;
        *)
            printf 'error: multiple extension metadata.json files found; pass the extension directory directly:\n' >&2
            printf '  %s\n' "${metadata_files[@]}" >&2
            exit 2
            ;;
    esac
fi

[ -f "$source_dir/extension.js" ] || fail "top-level extension.js not found beside $source_dir/metadata.json"

UUID="$(python3 - "$source_dir/metadata.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    metadata = json.load(handle)

uuid = metadata.get("uuid")
if not isinstance(uuid, str) or not uuid.strip():
    raise SystemExit("metadata.json has no non-empty string uuid")
print(uuid)
PY
)" || fail "could not read extension uuid from $source_dir/metadata.json"

INFO="$(LC_ALL=C gnome-extensions info "$UUID" 2>/dev/null)" || \
    fail "extension $UUID is not installed in the current GNOME session"

STATE="$(sed -n 's/^[[:space:]]*State:[[:space:]]*//p' <<<"$INFO" | head -n1)"
[ "$STATE" = "ACTIVE" ] || \
    fail "extension $UUID must already be ACTIVE for live host reload (current state: ${STATE:-unknown})"

installed_dir="$(sed -n 's/^[[:space:]]*Path:[[:space:]]*//p' <<<"$INFO" | head -n1)"
[ -n "$installed_dir" ] || installed_dir="$HOME/.local/share/gnome-shell/extensions/$UUID"
[ -d "$installed_dir" ] || fail "installed extension directory is missing: $installed_dir"
[ -w "$installed_dir" ] || fail "installed extension directory is not writable: $installed_dir"

source_real="$(readlink -f "$source_dir")"
installed_real="$(readlink -f "$installed_dir")"

printf '[reload] source=%s\n' "$source_dir" >&2
printf '[reload] uuid=%s state=%s\n' "$UUID" "$STATE" >&2
printf '[reload] installed=%s\n' "$installed_dir" >&2

if [ "$source_real" != "$installed_real" ]; then
    printf '[reload] deploying source tree into installed extension directory ...\n' >&2
    cp -a "$source_dir/." "$installed_dir/"
else
    printf '[reload] source is already the installed extension directory; deployment is a no-op\n' >&2
fi

cmp -s "$source_dir/extension.js" "$installed_dir/extension.js" || \
    fail "installed extension.js does not match source after deployment"

hash="$(sha256sum "$installed_dir/extension.js" | awk '{print $1}')"
printf '[reload] deployed extension.js sha256=%s\n' "$hash" >&2
printf '[reload] hot-swapping live ACTIVE extension through Looking Glass ...\n' >&2

[ -f "$INJECTOR" ] || fail "Looking Glass injector not found: $INJECTOR"
exec bash "$INJECTOR" "${inject_args[@]}" "$UUID"
