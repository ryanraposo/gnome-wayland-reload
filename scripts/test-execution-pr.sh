#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME=gnome-wayland-reload
STATE_ROOT="${GNOME_WAYLAND_RELOAD_PR_TEST_HOME:-$HOME/.local/state/$NAME/pr-execution-test}"
LATEST="$STATE_ROOT/latest"
AGENT_SKILL="${AGENTS_HOME:-$HOME/.agents}/skills/$NAME"
HERMES_SKILL="${HERMES_HOME:-$HOME/.hermes}/skills/$NAME"

usage() {
    cat <<'EOF'
Usage:
  bash scripts/test-execution-pr.sh prepare [UUID]
  bash scripts/test-execution-pr.sh verify
  bash scripts/test-execution-pr.sh restore

prepare runs every PR test, snapshots the current skill installs, installs this
PR tree, chooses the newest ACTIVE user extension, adds a reversible fresh-login
proof marker, and prints the post-login command.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
info() { printf '\033[34m[INFO]\033[0m %s\n' "$*"; }
ok() { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

field() {
    awk -F '\t' -v key="$2" '$1 == key {sub($1 FS, ""); print; exit}' "$1"
}

info_field() {
    sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" <<<"$1" | head -n 1
}

extension_candidate() {
    local uuid="$1" output state path mtime
    output="$(LC_ALL=C gnome-extensions info "$uuid" 2>/dev/null || true)"
    state="$(info_field "$output" State)"
    path="$(info_field "$output" Path)"
    [ -n "$path" ] || path="$HOME/.local/share/gnome-shell/extensions/$uuid"
    [ "$state" = ACTIVE ] || return 0
    [ -f "$path/extension.js" ] || return 0
    case "$path" in "$HOME"/*) ;; *) return 0 ;; esac
    mtime="$(stat -c %Y "$path/extension.js" 2>/dev/null || printf 0)"
    printf '%s\t%s\t%s\n' "$mtime" "$uuid" "$path"
}

select_extension() {
    local requested="${1:-${GNOME_WAYLAND_RELOAD_TEST_UUID:-}}" output state path rows row
    if [ -n "$requested" ]; then
        output="$(LC_ALL=C gnome-extensions info "$requested" 2>/dev/null || true)"
        state="$(info_field "$output" State)"
        path="$(info_field "$output" Path)"
        [ -n "$path" ] || path="$HOME/.local/share/gnome-shell/extensions/$requested"
        [ "$state" = ACTIVE ] || die "$requested must be ACTIVE; found ${state:-missing}"
        [ -f "$path/extension.js" ] || die "missing $path/extension.js"
        case "$path" in "$HOME"/*) ;; *) die "refusing system extension: $path" ;; esac
        printf '%s\t%s\n' "$requested" "$path"
        return
    fi
    rows="$(while IFS= read -r uuid; do extension_candidate "$uuid"; done < <(gnome-extensions list --enabled))"
    [ -n "$rows" ] || die "no ACTIVE user extension found; pass its UUID explicitly"
    row="$(sort -nr <<<"$rows" | head -n 1)"
    printf '%s\t%s\n' "$(cut -f2 <<<"$row")" "$(cut -f3- <<<"$row")"
}

snapshot() {
    local label="$1" path="$2" session="$3"
    if [ -e "$path" ] || [ -L "$path" ]; then
        cp -a -- "$path" "$session/$label"
        printf '%s\tpresent\n' "$label" >> "$session/state.tsv"
    else
        printf '%s\tabsent\n' "$label" >> "$session/state.tsv"
    fi
}

restore_snapshot() {
    local label="$1" path="$2" session="$3"
    rm -rf -- "$path"
    if [ "$(field "$session/state.tsv" "$label")" = present ]; then
        mkdir -p "$(dirname "$path")"
        cp -a -- "$session/$label" "$path"
    fi
}

prepare() {
    local branch selection uuid ext_dir stamp session marker prepared_at head
    for command in git python3 node gnome-extensions journalctl sha256sum; do need "$command"; done

    branch="$(git -C "$ROOT" branch --show-current)"
    [ "$branch" = agent/looking-glass-agent-execution ] || die "wrong branch: $branch"
    [ -z "$(git -C "$ROOT" status --porcelain)" ] || die "working tree must be clean"

    info "Running the complete PR proof surface"
    git -C "$ROOT" diff --check origin/main...HEAD
    bash -n "$ROOT/scripts/looking-glass-hotswap.sh"
    bash "$ROOT/tests/skill-ux.sh"
    bash "$ROOT/tests/run.sh"
    bash "$ROOT/tests/hotswap-agent.sh"
    node "$ROOT/tests/hotswap-payload.mjs"
    ok "Automated suites passed"

    selection="$(select_extension "${1:-}")"
    uuid="$(cut -f1 <<<"$selection")"
    ext_dir="$(cut -f2- <<<"$selection")"
    stamp="$(date +%Y%m%d-%H%M%S)"
    session="$STATE_ROOT/$stamp"
    marker="gwr-pr-execution-$stamp-$$"
    prepared_at="$(date --iso-8601=seconds)"
    head="$(git -C "$ROOT" rev-parse HEAD)"

    mkdir -p "$session"
    : > "$session/state.tsv"
    snapshot agents "$AGENT_SKILL" "$session"
    snapshot hermes "$HERMES_SKILL" "$session"
    cp -a -- "$ext_dir/extension.js" "$session/extension.js.before"
    cat > "$session/session.tsv" <<EOF
root	$ROOT
head	$head
uuid	$uuid
extension_dir	$ext_dir
marker	$marker
prepared_at	$prepared_at
EOF
    ln -sfn "$session" "$LATEST"

    info "Installing this PR over the current skill state"
    "$ROOT/install.sh" --skip-devkit
    cmp -s "$ROOT/scripts/looking-glass-hotswap.sh" "$AGENT_SKILL/scripts/looking-glass-hotswap.sh"
    cmp -s "$ROOT/scripts/looking-glass-hotswap.sh" "$HERMES_SKILL/scripts/looking-glass-hotswap.sh"
    ok "Installed Agent and Hermes copies match the PR"

    python3 - "$ext_dir/extension.js" "$marker" <<'PY'
import json
import sys
path, marker = sys.argv[1:]
message = f"[{marker}] extension.js imported"
with open(path, "a", encoding="utf-8") as handle:
    handle.write(f"\n// [{marker}] fresh Shell import proof\n")
    handle.write(f"console.log({json.dumps(message)});\n")
PY
    grep -Fq "$marker" "$ext_dir/extension.js"
    sha256sum "$session/extension.js.before" "$ext_dir/extension.js" > "$session/extension.sha256"

    printf '\nPrepared fresh-login acceptance test\n'
    printf '  PR head:   %s\n  Extension: %s\n  Marker:    %s\n  State:     %s\n\n' "$head" "$uuid" "$marker" "$session"
    printf 'Log out and back in. Then run exactly:\n\n'
    printf '  cd %q && bash scripts/test-execution-pr.sh verify\n\n' "$ROOT"
}

verify() {
    local session root head uuid ext_dir marker prepared_at output state logs
    [ -L "$LATEST" ] || die "no prepared test; run prepare first"
    session="$(readlink -f "$LATEST")"
    root="$(field "$session/session.tsv" root)"
    head="$(field "$session/session.tsv" head)"
    uuid="$(field "$session/session.tsv" uuid)"
    ext_dir="$(field "$session/session.tsv" extension_dir)"
    marker="$(field "$session/session.tsv" marker)"
    prepared_at="$(field "$session/session.tsv" prepared_at)"

    [ "$(git -C "$root" rev-parse HEAD)" = "$head" ] || die "checkout moved after prepare"
    cmp -s "$root/scripts/looking-glass-hotswap.sh" "$AGENT_SKILL/scripts/looking-glass-hotswap.sh"
    cmp -s "$root/scripts/looking-glass-hotswap.sh" "$HERMES_SKILL/scripts/looking-glass-hotswap.sh"
    grep -Fq "$marker" "$ext_dir/extension.js"

    output="$(LC_ALL=C gnome-extensions info "$uuid")"
    state="$(info_field "$output" State)"
    [ "$state" = ACTIVE ] || die "$uuid is not ACTIVE: ${state:-unknown}"
    logs="$(journalctl -b --since "$prepared_at" -o cat --no-pager /usr/bin/gnome-shell 2>/dev/null || true)"
    grep -Fq "[$marker] extension.js imported" <<<"$logs" || die "fresh-login marker absent from current boot journal"

    printf '%s\n' "$logs" | grep -F "[$marker] extension.js imported" > "$session/journal-proof.txt"
    printf '%s\n' "$output" > "$session/extension-info.after.txt"
    printf 'VERIFIED\n' > "$session/result"
    ok "Fresh Shell loaded the marked extension.js"
    ok "$uuid is ACTIVE"
    ok "Installed Agent and Hermes copies match $head"
    printf '\nProof: %s\n\nRestore with:\n  cd %q && bash scripts/test-execution-pr.sh restore\n\n' "$session" "$root"
}

restore() {
    local session ext_dir
    [ -L "$LATEST" ] || die "no prepared test to restore"
    session="$(readlink -f "$LATEST")"
    ext_dir="$(field "$session/session.tsv" extension_dir)"
    install -m 0644 "$session/extension.js.before" "$ext_dir/extension.js"
    restore_snapshot agents "$AGENT_SKILL" "$session"
    restore_snapshot hermes "$HERMES_SKILL" "$session"
    printf 'RESTORED\n' > "$session/restored"
    rm -f "$LATEST"
    ok "Extension source and previous skill installs restored"
    printf 'The restored extension.js becomes active after the next login.\n'
}

case "${1:-}" in
    prepare) [ "$#" -le 2 ] || die "prepare accepts at most one UUID"; prepare "${2:-}" ;;
    verify) [ "$#" -eq 1 ] || die "verify accepts no arguments"; verify ;;
    restore) [ "$#" -eq 1 ] || die "restore accepts no arguments"; restore ;;
    --help|-h) usage ;;
    *) usage >&2; exit 2 ;;
esac
