#!/usr/bin/env bash
set -euo pipefail

NAME="gnome-wayland-reload"
STATE_ROOT="${GNOME_WAYLAND_RELOAD_LOGIN_PROOF_HOME:-$HOME/.local/state/$NAME/host-login-proof}"

usage() {
    cat <<'USAGE'
Usage:
  host-login-proof.sh prepare EXTENSION_SOURCE_DIR
  host-login-proof.sh verify [RECEIPT.json]
  host-login-proof.sh restore [RECEIPT.json]
  host-login-proof.sh status [RECEIPT.json]

Prepare and prove a fresh-login GNOME Shell extension load.

prepare   Snapshot whatever is currently installed, stage the supplied extension
          with a unique top-level load marker, and deploy it atomically.
verify    Require a new GNOME Shell process, ACTIVE extension state, the exact
          journal marker, and installed staged bytes. Then restore marker-free
          extension.js bytes from the source tree.
restore   Restore the complete pre-test installation snapshot and enabled state.
status    Print the durable receipt.
USAGE
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

validate_uuid() {
    case "$1" in
        ''|*[!A-Za-z0-9._@+-]*) fail "UUID contains unsupported characters" ;;
    esac
}

absolute_path() {
    python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
}

json_field() {
    local receipt="$1"
    local field="$2"
    python3 - "$receipt" "$field" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    value = json.load(handle)
for part in sys.argv[2].split('.'):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(f'missing receipt field: {sys.argv[2]}')
    value = value[part]
if isinstance(value, bool):
    print('true' if value else 'false')
elif value is None:
    print('')
else:
    print(value)
PY
}

latest_receipt() {
    local pointer="$STATE_ROOT/latest"
    [ -f "$pointer" ] || fail "no host-login proof receipt exists"
    local receipt
    receipt="$(cat "$pointer")"
    [ -f "$receipt" ] || fail "latest receipt is missing: $receipt"
    printf '%s\n' "$receipt"
}

resolve_receipt() {
    if [ "$#" -gt 0 ] && [ -n "${1:-}" ]; then
        absolute_path "$1"
    else
        latest_receipt
    fi
}

shell_identity() {
    if [ -n "${GNOME_WAYLAND_RELOAD_SHELL_IDENTITY_OVERRIDE:-}" ]; then
        printf '%s\n' "$GNOME_WAYLAND_RELOAD_SHELL_IDENTITY_OVERRIDE"
        return
    fi

    local pid=""
    if command -v gdbus >/dev/null 2>&1; then
        pid="$(
            gdbus call --session \
                --dest org.freedesktop.DBus \
                --object-path /org/freedesktop/DBus \
                --method org.freedesktop.DBus.GetConnectionUnixProcessID \
                org.gnome.Shell 2>/dev/null |
                sed -n 's/.*uint32 \([0-9][0-9]*\).*/\1/p'
        )"
    fi
    if [ -z "$pid" ]; then
        pid="$(pgrep -u "$(id -u)" -x gnome-shell | head -n 1 || true)"
    fi
    [ -n "$pid" ] || fail "could not identify the current GNOME Shell process"
    [ -r "/proc/$pid/stat" ] || fail "GNOME Shell process disappeared: $pid"

    local started
    started="$(awk '{print $22}' "/proc/$pid/stat")"
    printf '%s:%s\n' "$pid" "$started"
}

extension_info() {
    LC_ALL=C gnome-extensions info "$1" 2>&1 || true
}

extension_state_from_info() {
    sed -n 's/^[[:space:]]*State:[[:space:]]*//p' <<< "$1" | head -n 1
}

extension_path_from_info() {
    sed -n 's/^[[:space:]]*Path:[[:space:]]*//p' <<< "$1" | head -n 1
}

enabled_now() {
    gnome-extensions list --enabled 2>/dev/null | grep -Fxq -- "$1"
}

atomic_replace_tree() {
    local source="$1"
    local target="$2"
    local parent temp old

    parent="$(dirname "$target")"
    mkdir -p "$parent"
    temp="$parent/.${NAME}.new.$$"
    old="$parent/.${NAME}.old.$$"
    rm -rf -- "$temp" "$old"
    mkdir "$temp"
    cp -a "$source/." "$temp/"

    if [ -e "$target" ] || [ -L "$target" ]; then
        mv -- "$target" "$old"
        if mv -- "$temp" "$target"; then
            rm -rf -- "$old"
        else
            mv -- "$old" "$target"
            rm -rf -- "$temp"
            return 1
        fi
    else
        mv -- "$temp" "$target"
    fi
}

atomic_restore_snapshot() {
    local snapshot="$1"
    local target="$2"
    local parent temp old

    parent="$(dirname "$target")"
    mkdir -p "$parent"
    temp="$parent/.${NAME}.restore.$$"
    old="$parent/.${NAME}.restore-old.$$"
    rm -rf -- "$temp" "$old"
    cp -a -- "$snapshot" "$temp"

    if [ -e "$target" ] || [ -L "$target" ]; then
        mv -- "$target" "$old"
        if mv -- "$temp" "$target"; then
            rm -rf -- "$old"
        else
            mv -- "$old" "$target"
            rm -rf -- "$temp"
            return 1
        fi
    else
        mv -- "$temp" "$target"
    fi
}

prepare() {
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    require_command python3
    require_command sha256sum
    require_command gnome-extensions

    local source_dir metadata uuid info installed_dir home_real
    local token marker prepared_at session_dir stage_dir backup_dir receipt clean_extension
    local source_sha staged_sha installed_sha shell_before state_before
    local enabled_before=false installed_existed=false installed_was_symlink=false script_path

    source_dir="$(absolute_path "$1")"
    [ -d "$source_dir" ] || fail "extension source directory not found: $source_dir"
    metadata="$source_dir/metadata.json"
    [ -f "$metadata" ] || fail "metadata.json not found: $metadata"
    [ -f "$source_dir/extension.js" ] || fail "extension.js not found: $source_dir/extension.js"

    uuid="$(python3 - "$metadata" <<'PY'
import json
import sys
with open(sys.argv[1], encoding='utf-8') as handle:
    value = json.load(handle).get('uuid', '')
if not isinstance(value, str) or not value:
    raise SystemExit('metadata.json has no string uuid')
print(value)
PY
)"
    validate_uuid "$uuid"

    info="$(extension_info "$uuid")"
    state_before="$(extension_state_from_info "$info")"
    installed_dir="$(extension_path_from_info "$info")"
    if [ -z "$installed_dir" ]; then
        installed_dir="$HOME/.local/share/gnome-shell/extensions/$uuid"
    fi
    installed_dir="$(absolute_path "$installed_dir")"
    home_real="$(absolute_path "$HOME")"
    case "$installed_dir" in
        "$home_real"/*) ;;
        *) fail "refusing to replace a non-user extension path: $installed_dir" ;;
    esac
    [ "$installed_dir" != "$source_dir" ] || \
        fail "installed path is the source tree; use a separate user extension installation"

    if enabled_now "$uuid"; then
        enabled_before=true
    fi
    if [ -e "$installed_dir" ] || [ -L "$installed_dir" ]; then
        installed_existed=true
    fi
    if [ -L "$installed_dir" ]; then
        installed_was_symlink=true
    fi

    token="$(date +%s%N 2>/dev/null || date +%s)-$$"
    marker="[gnome-wayland-reload-login:$token] uuid=$uuid"
    prepared_at="$(date --iso-8601=seconds)"
    session_dir="$STATE_ROOT/$token"
    stage_dir="$session_dir/staged-extension"
    backup_dir="$session_dir/backup"
    clean_extension="$session_dir/extension.js.clean"
    receipt="$session_dir/receipt.json"

    umask 077
    mkdir -p "$stage_dir" "$backup_dir"
    cp -a "$source_dir/." "$stage_dir/"
    cp -a "$source_dir/extension.js" "$clean_extension"
    python3 - "$stage_dir/extension.js" "$marker" <<'PY'
import json
import sys

path, marker = sys.argv[1:]
with open(path, 'a', encoding='utf-8') as handle:
    handle.write('\nconsole.log(' + json.dumps(marker) + ');\n')
PY

    if $installed_existed; then
        cp -a -- "$installed_dir" "$backup_dir/installed"
    fi

    source_sha="$(sha256sum "$source_dir/extension.js" | awk '{print $1}')"
    staged_sha="$(sha256sum "$stage_dir/extension.js" | awk '{print $1}')"
    shell_before="$(shell_identity)"

    python3 - "$receipt" "$uuid" "$source_dir" "$installed_dir" \
        "$stage_dir" "$backup_dir" "$clean_extension" "$token" "$marker" "$prepared_at" \
        "$source_sha" "$staged_sha" "$shell_before" "$state_before" \
        "$enabled_before" "$installed_existed" "$installed_was_symlink" <<'PY'
import json
import os
import sys

(
    receipt, uuid, source_dir, installed_dir, stage_dir, backup_dir, clean_extension,
    token, marker, prepared_at, source_sha, staged_sha, shell_before, state_before,
    enabled_before, installed_existed, installed_was_symlink,
) = sys.argv[1:]
data = {
    'schema': 1,
    'status': 'PREPARING',
    'uuid': uuid,
    'source_dir': source_dir,
    'installed_dir': installed_dir,
    'stage_dir': stage_dir,
    'backup_dir': backup_dir,
    'clean_extension_file': clean_extension,
    'token': token,
    'marker': marker,
    'prepared_at': prepared_at,
    'source_extension_sha256': source_sha,
    'staged_extension_sha256': staged_sha,
    'shell_before': shell_before,
    'extension_state_before': state_before,
    'enabled_before': enabled_before == 'true',
    'installed_existed': installed_existed == 'true',
    'installed_was_symlink': installed_was_symlink == 'true',
    'receipt_file': receipt,
}
tmp = receipt + '.tmp'
with open(tmp, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write('\n')
os.chmod(tmp, 0o600)
os.replace(tmp, receipt)
PY

    atomic_replace_tree "$stage_dir" "$installed_dir" || \
        fail "could not atomically deploy the staged extension"
    installed_sha="$(sha256sum "$installed_dir/extension.js" | awk '{print $1}')"
    [ "$installed_sha" = "$staged_sha" ] || \
        fail "installed extension.js does not match the staged proof copy"

    python3 - "$receipt" <<'PY'
import json
import os
import sys

receipt = sys.argv[1]
with open(receipt, encoding='utf-8') as handle:
    data = json.load(handle)
data['status'] = 'PREPARED_LOGOUT'
data['next_stage'] = 'LOG_OUT_AND_IN'
tmp = receipt + '.tmp'
with open(tmp, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write('\n')
os.chmod(tmp, 0o600)
os.replace(tmp, receipt)
PY

    mkdir -p "$STATE_ROOT"
    printf '%s\n' "$receipt" > "$STATE_ROOT/latest.tmp"
    chmod 600 "$STATE_ROOT/latest.tmp"
    mv "$STATE_ROOT/latest.tmp" "$STATE_ROOT/latest"

    script_path="$(absolute_path "${BASH_SOURCE[0]}")"
    printf 'prepared: %s\n' "$uuid"
    printf 'snapshot: %s\n' "$backup_dir"
    printf 'deployed: %s\n' "$installed_dir"
    printf 'marker:   %s\n' "$marker"
    printf 'receipt:  %s\n\n' "$receipt"
    printf 'Log out and back in. Then run:\n\n'
    printf '  %q verify %q\n' "$script_path" "$receipt"
}

verify() {
    [ "$#" -le 1 ] || { usage >&2; exit 2; }
    require_command python3
    require_command sha256sum
    require_command gnome-extensions
    require_command journalctl

    local receipt status uuid source_dir installed_dir marker prepared_at
    local staged_sha source_sha shell_before shell_after info state journal installed_sha
    local enabled_before installed_was_symlink clean_extension source_unchanged=true

    receipt="$(resolve_receipt "${1:-}")"
    [ -f "$receipt" ] || fail "receipt not found: $receipt"
    status="$(json_field "$receipt" status)"
    case "$status" in
        PREPARED_LOGOUT|INCONCLUSIVE) ;;
        VERIFIED) python3 -m json.tool "$receipt"; return 0 ;;
        *) fail "receipt cannot be verified from status: $status" ;;
    esac

    uuid="$(json_field "$receipt" uuid)"
    source_dir="$(json_field "$receipt" source_dir)"
    installed_dir="$(json_field "$receipt" installed_dir)"
    marker="$(json_field "$receipt" marker)"
    prepared_at="$(json_field "$receipt" prepared_at)"
    staged_sha="$(json_field "$receipt" staged_extension_sha256)"
    source_sha="$(json_field "$receipt" source_extension_sha256)"
    shell_before="$(json_field "$receipt" shell_before)"
    enabled_before="$(json_field "$receipt" enabled_before)"
    installed_was_symlink="$(json_field "$receipt" installed_was_symlink)"
    clean_extension="$(json_field "$receipt" clean_extension_file)"

    shell_after="$(shell_identity)"
    [ "$shell_after" != "$shell_before" ] || \
        fail "GNOME Shell is still the pre-test process; log out and back in first"

    [ -f "$installed_dir/extension.js" ] || \
        fail "installed extension.js is missing after login: $installed_dir/extension.js"
    installed_sha="$(sha256sum "$installed_dir/extension.js" | awk '{print $1}')"
    [ "$installed_sha" = "$staged_sha" ] || \
        fail "installed extension.js changed before proof was collected"

    info="$(extension_info "$uuid")"
    state="$(extension_state_from_info "$info")"
    if [ "$state" != ACTIVE ]; then
        gnome-extensions enable "$uuid" >/dev/null 2>&1 || true
        sleep "${GNOME_WAYLAND_RELOAD_LOGIN_PROOF_ENABLE_DELAY:-2}"
        info="$(extension_info "$uuid")"
        state="$(extension_state_from_info "$info")"
    fi

    journal="$(
        journalctl -b --since "$prepared_at" -o cat _COMM=gnome-shell 2>/dev/null ||
        journalctl -b --since "$prepared_at" -o cat /usr/bin/gnome-shell 2>/dev/null ||
        true
    )"

    if [ "$state" != ACTIVE ] || ! grep -Fq -- "$marker" <<< "$journal"; then
        python3 - "$receipt" "$shell_after" "$state" "$info" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

receipt, shell_after, state, info = sys.argv[1:]
with open(receipt, encoding='utf-8') as handle:
    data = json.load(handle)
data['status'] = 'INCONCLUSIVE'
data['checked_at'] = datetime.now(timezone.utc).astimezone().isoformat(timespec='seconds')
data['shell_after'] = shell_after
data['extension_state_after'] = state
data['extension_info_after'] = info
data['next_stage'] = 'RERUN_VERIFY_OR_RESTORE'
tmp = receipt + '.tmp'
with open(tmp, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write('\n')
os.chmod(tmp, 0o600)
os.replace(tmp, receipt)
PY
        printf 'inconclusive: extension_state=%s marker_found=%s\n' \
            "${state:-UNKNOWN}" "$(grep -Fq -- "$marker" <<< "$journal" && echo true || echo false)" >&2
        printf 'rerun safely: %q verify %q\n' "$(absolute_path "${BASH_SOURCE[0]}")" "$receipt" >&2
        return 3
    fi

    [ -f "$clean_extension" ] || fail "clean proof copy is missing: $clean_extension"
    install -m 0644 "$clean_extension" "$installed_dir/extension.js"
    [ "$(sha256sum "$installed_dir/extension.js" | awk '{print $1}')" = "$source_sha" ] || \
        fail "could not restore the exact marker-free proof bytes"

    if [ "$(sha256sum "$source_dir/extension.js" | awk '{print $1}')" != "$source_sha" ]; then
        source_unchanged=false
    fi
    if [ "$installed_was_symlink" = true ] && [ "$source_unchanged" = true ]; then
        atomic_restore_snapshot "$(json_field "$receipt" backup_dir)/installed" "$installed_dir"
    fi
    if [ "$enabled_before" != true ]; then
        gnome-extensions disable "$uuid" >/dev/null 2>&1 || true
    fi

    python3 - "$receipt" "$shell_after" "$state" "$info" "$source_sha" \
        "$installed_was_symlink" "$source_unchanged" "$enabled_before" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

(
    receipt, shell_after, state, info, source_sha, installed_was_symlink,
    source_unchanged, enabled_before,
) = sys.argv[1:]
with open(receipt, encoding='utf-8') as handle:
    data = json.load(handle)
data['status'] = 'VERIFIED'
data['verified_at'] = datetime.now(timezone.utc).astimezone().isoformat(timespec='seconds')
data['shell_after'] = shell_after
data['extension_state_after'] = state
data['extension_info_after'] = info
data['marker_found'] = True
data['marker_free_source_restored'] = True
data['source_unchanged_during_test'] = source_unchanged == 'true'
data['installation_topology_restored'] = (
    installed_was_symlink != 'true' or source_unchanged == 'true'
)
data['enabled_state_restored'] = True
data['restored_source_extension_sha256'] = source_sha
data['next_stage'] = 'COMPLETE'
tmp = receipt + '.tmp'
with open(tmp, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write('\n')
os.chmod(tmp, 0o600)
os.replace(tmp, receipt)
PY

    printf 'VERIFIED: %s loaded in a fresh GNOME Shell process\n' "$uuid"
    printf 'ACTIVE:   yes\n'
    printf 'MARKER:   %s\n' "$marker"
    printf 'CLEANUP:  exact marker-free proof bytes restored on disk\n'
    if [ "$installed_was_symlink" = true ] && [ "$source_unchanged" = true ]; then
        printf 'TOPOLOGY: development symlink restored\n'
    elif [ "$installed_was_symlink" = true ]; then
        printf 'TOPOLOGY: source changed during test; deployed directory retained\n'
    fi
    printf 'RECEIPT:  %s\n' "$receipt"
}

restore() {
    [ "$#" -le 1 ] || { usage >&2; exit 2; }
    require_command python3
    require_command gnome-extensions

    local receipt installed_dir backup_dir installed_existed enabled_before uuid
    receipt="$(resolve_receipt "${1:-}")"
    [ -f "$receipt" ] || fail "receipt not found: $receipt"
    installed_dir="$(json_field "$receipt" installed_dir)"
    backup_dir="$(json_field "$receipt" backup_dir)"
    installed_existed="$(json_field "$receipt" installed_existed)"
    enabled_before="$(json_field "$receipt" enabled_before)"
    uuid="$(json_field "$receipt" uuid)"

    if [ "$installed_existed" = true ]; then
        [ -e "$backup_dir/installed" ] || [ -L "$backup_dir/installed" ] || \
            fail "installation backup is missing: $backup_dir/installed"
        atomic_restore_snapshot "$backup_dir/installed" "$installed_dir"
    else
        rm -rf -- "$installed_dir"
    fi

    if [ "$enabled_before" = true ]; then
        gnome-extensions enable "$uuid" >/dev/null 2>&1 || true
    else
        gnome-extensions disable "$uuid" >/dev/null 2>&1 || true
    fi

    python3 - "$receipt" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

receipt = sys.argv[1]
with open(receipt, encoding='utf-8') as handle:
    data = json.load(handle)
data['status'] = 'RESTORED'
data['restored_at'] = datetime.now(timezone.utc).astimezone().isoformat(timespec='seconds')
data['next_stage'] = None
tmp = receipt + '.tmp'
with open(tmp, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write('\n')
os.chmod(tmp, 0o600)
os.replace(tmp, receipt)
PY
    printf 'restored pre-test installation: %s\n' "$installed_dir"
}

status_receipt() {
    [ "$#" -le 1 ] || { usage >&2; exit 2; }
    python3 -m json.tool "$(resolve_receipt "${1:-}")"
}

case "${1:-}" in
    prepare)
        shift
        prepare "$@"
        ;;
    verify)
        shift
        verify "$@"
        ;;
    restore)
        shift
        restore "$@"
        ;;
    status)
        shift
        status_receipt "$@"
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
