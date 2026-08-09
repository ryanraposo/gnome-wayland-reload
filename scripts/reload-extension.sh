#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INJECTOR="${GNOME_WAYLAND_RELOAD_INJECTOR:-$SCRIPT_DIR/looking-glass-inject.sh}"
RECYCLER="${GNOME_WAYLAND_RELOAD_RECYCLER:-$SCRIPT_DIR/recycle-extension.sh}"
DIAGNOSE="${GNOME_WAYLAND_RELOAD_DIAGNOSE:-$SCRIPT_DIR/diagnose.sh}"

usage() {
    cat <<'USAGE'
Usage:
  reload-extension.sh [--plan] [--no-wait] [--token TOKEN] [SOURCE_OR_REPO]

Inspect an extension source tree, choose the smallest safe refresh boundary,
deploy the source when appropriate, and perform that refresh.

SOURCE_OR_REPO defaults to ".". If it is a repository root, exactly one
metadata.json is discovered within six directory levels.

Routes:
  HOST_HOTSWAP   ACTIVE + top-level extension.js: deploy, prove bytes, Looking Glass
  SOFT_CYCLE     stylesheet/resource-only change: deploy, lifecycle recycle
  PREFS_REOPEN   prefs-only change: deploy, require preferences reopen
  FRESH_PROCESS  imported JS / metadata / native change: deploy, use a fresh nested Shell
  SCHEMA_REFRESH schema XML changed: deploy, compile schemas, refresh consumers
  REPAIR         installed extension is in ERROR: deploy, diagnose, use a fresh process
  INACTIVE       installed but not ACTIVE: deploy, never silently enable it
  INSTALL        UUID is not installed in the current GNOME session

Options:
  --plan         Inspect and print the route without changing files or runtime state.
  --no-wait      Pass through to looking-glass-inject.sh for HOST_HOTSWAP.
  --token TOKEN  Pass a deterministic transaction token to the injector.
  --help         Show this usage text.

Exit codes:
  0  selected refresh completed, or --plan completed
  1  selected refresh ran but verification failed
  2  usage/dependency/integrity error
  3  Looking Glass verification/injection remains inconclusive
  4  a different boundary or explicit user decision is required
USAGE
}

fail() { printf 'error: %s\n' "$*" >&2; exit 2; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

plan_only=false
inject_args=()
source_arg="."
source_seen=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --plan)
            plan_only=true
            shift
            ;;
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
        0) fail "no extension metadata.json found under $source_root" ;;
        1) source_dir="$(dirname "${metadata_files[0]}")" ;;
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

INFO="$(LC_ALL=C gnome-extensions info "$UUID" 2>/dev/null || true)"
STATE="$(sed -n 's/^[[:space:]]*State:[[:space:]]*//p' <<<"$INFO" | head -n1)"
installed_dir="$(sed -n 's/^[[:space:]]*Path:[[:space:]]*//p' <<<"$INFO" | head -n1)"
[ -n "$installed_dir" ] || installed_dir="$HOME/.local/share/gnome-shell/extensions/$UUID"

if [ -z "$INFO" ] || [ ! -d "$installed_dir" ]; then
    printf 'route=INSTALL\n'
    printf 'uuid=%s\n' "$UUID"
    printf 'state=NOT_INSTALLED\n'
    printf 'source=%s\n' "$source_dir"
    printf 'installed=%s\n' "$installed_dir"
    printf 'reason=the UUID is not installed in the current GNOME session\n'
    $plan_only && exit 0
    printf 'next=install the extension, then rerun this command; no host Shell restart is needed merely to install files\n' >&2
    exit 4
fi

[ -w "$installed_dir" ] || fail "installed extension directory is not writable: $installed_dir"

CLASS_JSON="$(python3 - "$source_dir" "$installed_dir" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

source = Path(sys.argv[1]).resolve()
installed = Path(sys.argv[2]).resolve()
ignored_dirs = {".git", ".github", "node_modules", ".venv", "venv", "__pycache__"}
ignored_paths = {"schemas/gschemas.compiled"}


def digest(path: Path) -> str:
    if path.is_symlink():
        return "symlink:" + os.readlink(path)
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def manifest(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for current, dirs, files in os.walk(root):
        dirs[:] = [name for name in dirs if name not in ignored_dirs]
        current_path = Path(current)
        for name in files:
            path = current_path / name
            rel = path.relative_to(root).as_posix()
            if rel in ignored_paths:
                continue
            try:
                result[rel] = digest(path)
            except FileNotFoundError:
                pass
    return result


def git_dirty_paths(root: Path) -> list[str]:
    try:
        repo = Path(subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()).resolve()
        rel_root = root.relative_to(repo).as_posix()
        scope = "." if rel_root == "." else rel_root
        changed = subprocess.check_output(
            ["git", "-C", str(repo), "diff", "--name-only", "HEAD", "--", scope],
            text=True,
            stderr=subprocess.DEVNULL,
        ).splitlines()
        untracked = subprocess.check_output(
            ["git", "-C", str(repo), "ls-files", "--others", "--exclude-standard", "--", scope],
            text=True,
            stderr=subprocess.DEVNULL,
        ).splitlines()
    except (subprocess.CalledProcessError, ValueError):
        return []

    prefix = "" if rel_root == "." else rel_root.rstrip("/") + "/"
    paths: set[str] = set()
    for item in changed + untracked:
        item = item.strip()
        if not item:
            continue
        if prefix and item.startswith(prefix):
            item = item[len(prefix):]
        if item in ignored_paths or any(part in ignored_dirs for part in Path(item).parts):
            continue
        paths.add(item)
    return sorted(paths)


if source == installed:
    changed = git_dirty_paths(source)
    basis = "co-located-git" if changed else "co-located-runtime-intent"
else:
    source_manifest = manifest(source)
    installed_manifest = manifest(installed)
    changed = sorted(
        path
        for path in set(source_manifest) | set(installed_manifest)
        if source_manifest.get(path) != installed_manifest.get(path)
    )
    basis = "source-vs-installed"

lower = [path.lower() for path in changed]
basenames = [Path(path).name.lower() for path in changed]

route = "HOST_HOTSWAP"
reason = "top-level extension.js can be cache-busted and replaced in an ACTIVE host Shell"

if any(name == "metadata.json" for name in basenames):
    route = "FRESH_PROCESS"
    reason = "metadata changed and requires a fresh Shell process"
elif any(path.endswith(".gschema.xml") for path in lower):
    route = "SCHEMA_REFRESH"
    reason = "schema XML changed and its consumers need freshly compiled schema state"
elif any(path.endswith((".so", ".typelib")) for path in lower):
    route = "FRESH_PROCESS"
    reason = "native or typelib state changed and cannot be unloaded from the host Shell"
else:
    prefs_related = [
        path for path in lower
        if Path(path).name == "prefs.js"
        or path.startswith("prefs/")
        or "/prefs/" in f"/{path}"
    ]
    shell_js = [
        path for path in lower
        if path.endswith((".js", ".mjs"))
        and Path(path).name != "prefs.js"
        and not path.startswith("prefs/")
        and "/prefs/" not in f"/{path}"
    ]

    if changed and len(prefs_related) == len(changed):
        route = "PREFS_REOPEN"
        reason = "preferences run in a separate gjs process; reopen that process"
    elif any(path != "extension.js" for path in shell_js):
        route = "FRESH_PROCESS"
        reason = "an imported Shell-side JavaScript module changed and remains cached in the host process"
    elif changed and all(path.endswith(".css") for path in lower):
        route = "SOFT_CYCLE"
        reason = "stylesheet-only changes need lifecycle refresh, not a new JavaScript module"
    elif "extension.js" in lower or not changed:
        route = "HOST_HOTSWAP"
    else:
        route = "SOFT_CYCLE"
        reason = "resource-only changes are safest to pick up through the extension lifecycle"

print(json.dumps({"route": route, "reason": reason, "basis": basis, "changed": changed}, sort_keys=True))
PY
)"

ARTIFACT_ROUTE="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["route"])' "$CLASS_JSON")"
REASON="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["reason"])' "$CLASS_JSON")"
BASIS="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["basis"])' "$CLASS_JSON")"
CHANGED="$(python3 -c 'import json,sys; print(",".join(json.loads(sys.argv[1])["changed"]) or "(none detected)")' "$CLASS_JSON")"

ROUTE="$ARTIFACT_ROUTE"
case "$STATE" in
    ACTIVE) ;;
    ERROR)
        ROUTE="REPAIR"
        REASON="the installed extension is in ERROR; deploy the candidate bytes, inspect the failure, and use a fresh process for Shell-side code"
        ;;
    *)
        ROUTE="INACTIVE"
        REASON="the extension is installed but not ACTIVE; do not silently enable it or pretend lifecycle activation refreshes cached JavaScript"
        ;;
esac

print_plan() {
    printf 'route=%s\n' "$ROUTE"
    printf 'artifact_route=%s\n' "$ARTIFACT_ROUTE"
    printf 'uuid=%s\n' "$UUID"
    printf 'state=%s\n' "${STATE:-unknown}"
    printf 'source=%s\n' "$source_dir"
    printf 'installed=%s\n' "$installed_dir"
    printf 'basis=%s\n' "$BASIS"
    printf 'changed=%s\n' "$CHANGED"
    printf 'reason=%s\n' "$REASON"
}

if $plan_only; then
    print_plan
    exit 0
fi

source_real="$(readlink -f "$source_dir")"
installed_real="$(readlink -f "$installed_dir")"

deploy_source() {
    if [ "$source_real" = "$installed_real" ]; then
        printf '[reload] source is already the installed extension directory; deployment is a no-op\n' >&2
        return
    fi

    printf '[reload] mirroring source tree into installed extension directory ...\n' >&2
    python3 - "$source_dir" "$installed_dir" <<'PY'
from __future__ import annotations

import hashlib
import os
import shutil
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
ignored_dirs = {".git", ".github", "node_modules", ".venv", "venv", "__pycache__"}
# Compiled schemas are generated runtime state, not source-managed bytes.
ignored_paths = {"schemas/gschemas.compiled"}


def digest(path: Path) -> str:
    if path.is_symlink():
        return "symlink:" + os.readlink(path)
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def manifest(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for current, dirs, files in os.walk(root):
        dirs[:] = [name for name in dirs if name not in ignored_dirs]
        current_path = Path(current)
        for name in files:
            path = current_path / name
            rel = path.relative_to(root).as_posix()
            if rel in ignored_paths:
                continue
            result[rel] = digest(path)
    return result


source_manifest = manifest(source)
target_manifest = manifest(target)

# Remove stale source-managed files first. The installed root itself is never
# replaced, so a user extension symlink remains a symlink.
for rel in sorted(set(target_manifest) - set(source_manifest), reverse=True):
    stale = target / rel
    if stale.is_dir() and not stale.is_symlink():
        shutil.rmtree(stale)
    else:
        stale.unlink(missing_ok=True)

for current, dirs, files in os.walk(source):
    dirs[:] = [name for name in dirs if name not in ignored_dirs]
    current_path = Path(current)
    rel_dir = current_path.relative_to(source)
    target_dir = target / rel_dir
    if target_dir.is_symlink() and rel_dir != Path('.'):
        target_dir.unlink()
    target_dir.mkdir(parents=True, exist_ok=True)

    for name in files:
        src = current_path / name
        rel = src.relative_to(source).as_posix()
        if rel in ignored_paths:
            continue
        dst = target / rel
        if src.is_symlink():
            link = os.readlink(src)
            if dst.is_symlink() and os.readlink(dst) == link:
                continue
            if dst.exists() or dst.is_symlink():
                if dst.is_dir() and not dst.is_symlink():
                    shutil.rmtree(dst)
                else:
                    dst.unlink()
            dst.symlink_to(link)
        else:
            if dst.is_symlink():
                dst.unlink()
            elif dst.is_dir():
                shutil.rmtree(dst)
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)

# Remove empty target-only directories after stale files are gone.
for current, dirs, _files in os.walk(target, topdown=False):
    current_path = Path(current)
    if current_path == target:
        continue
    rel = current_path.relative_to(target)
    if any(part in ignored_dirs for part in rel.parts):
        continue
    source_peer = source / rel
    if not source_peer.exists() and not source_peer.is_symlink():
        try:
            current_path.rmdir()
        except OSError:
            pass

final_manifest = manifest(target)
if final_manifest != source_manifest:
    missing = sorted(set(source_manifest) - set(final_manifest))
    extra = sorted(set(final_manifest) - set(source_manifest))
    changed = sorted(
        path for path in set(source_manifest) & set(final_manifest)
        if source_manifest[path] != final_manifest[path]
    )
    raise SystemExit(
        f"deployment manifest mismatch: missing={missing} extra={extra} changed={changed}"
    )
PY
}

printf '[reload] source=%s\n' "$source_dir" >&2
printf '[reload] uuid=%s state=%s route=%s\n' "$UUID" "${STATE:-unknown}" "$ROUTE" >&2
printf '[reload] installed=%s\n' "$installed_dir" >&2
printf '[reload] changed=%s\n' "$CHANGED" >&2

case "$ROUTE" in
    REPAIR)
        deploy_source
        print_plan >&2
        if [ -x "$DIAGNOSE" ]; then
            bash "$DIAGNOSE" "$UUID" || true
        fi
        printf 'next=%s\n' "$SCRIPT_DIR/dev-shell.sh" >&2
        exit 4
        ;;
    INACTIVE)
        deploy_source
        print_plan >&2
        printf 'next=use %s for a fresh Shell-side process, or explicitly enable %s only when that state change is intended\n' \
            "$SCRIPT_DIR/dev-shell.sh" "$UUID" >&2
        exit 4
        ;;
    FRESH_PROCESS)
        deploy_source
        print_plan >&2
        printf 'next=%s\n' "$SCRIPT_DIR/dev-shell.sh" >&2
        printf '[reload] installed bytes are current; the live host runtime was intentionally left untouched\n' >&2
        exit 4
        ;;
    SCHEMA_REFRESH)
        deploy_source
        if [ -d "$installed_dir/schemas" ] && command -v glib-compile-schemas >/dev/null 2>&1; then
            glib-compile-schemas "$installed_dir/schemas"
            printf '[reload] compiled schemas in %s/schemas\n' "$installed_dir" >&2
        fi
        print_plan >&2
        printf 'next=reopen preferences and use %s if the Shell process consumes the schema\n' \
            "$SCRIPT_DIR/dev-shell.sh" >&2
        exit 4
        ;;
    PREFS_REOPEN)
        deploy_source
        print_plan >&2
        printf 'next=close the existing preferences window, then run: gnome-extensions prefs %q\n' "$UUID" >&2
        exit 4
        ;;
    SOFT_CYCLE)
        deploy_source
        [ -x "$RECYCLER" ] || fail "recycle helper not found: $RECYCLER"
        printf '[reload] lifecycle-cycling %s; JavaScript module identity is unchanged\n' "$UUID" >&2
        exec bash "$RECYCLER" "$UUID"
        ;;
    HOST_HOTSWAP)
        deploy_source
        ;;
    *)
        fail "internal planner returned unknown route: $ROUTE"
        ;;
esac

command -v cmp >/dev/null 2>&1 || fail "required command not found: cmp"
cmp -s "$source_dir/extension.js" "$installed_dir/extension.js" || \
    fail "installed extension.js does not match source after deployment"

hash="$(sha256sum "$installed_dir/extension.js" | awk '{print $1}')"
printf '[reload] deployed extension.js sha256=%s\n' "$hash" >&2
printf '[reload] hot-swapping live ACTIVE extension through Looking Glass ...\n' >&2

[ -f "$INJECTOR" ] || fail "Looking Glass injector not found: $INJECTOR"
exec bash "$INJECTOR" "${inject_args[@]}" "$UUID"
