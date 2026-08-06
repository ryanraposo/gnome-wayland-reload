#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="gnome-wayland-reload"
STATE_ROOT="${GNOME_WAYLAND_RELOAD_PR_TEST_HOME:-$HOME/.local/state/$NAME/pr-execution-test}"
LATEST="$STATE_ROOT/latest"
AGENT_SKILL="${AGENTS_HOME:-$HOME/.agents}/skills/$NAME"
HERMES_SKILL="${HERMES_HOME:-$HOME/.hermes}/skills/$NAME"

usage() {
    cat <<'EOF'
Usage:
  scripts/test-execution-pr.sh prepare [UUID]
  scripts/test-execution-pr.sh verify
  scripts/test-execution-pr.sh restore

prepare  Run the PR suites, snapshot current skill installs, install this tree,
         choose an ACTIVE user extension, add a reversible fresh-login marker,
         and print the exact command to run after logging out and back in.
verify   After login, prove the marked extension loaded in the fresh Shell and
         that both installed skill copies still match this PR tree.
restore  Restore the extension.js and skill directories captured by prepare.

Set GNOME_WAYLAND_RELOAD_TEST_UUID to avoid automatic extension selection.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
info() { printf '\033[34m[INFO]\033[0m %s\n' "$*"; }
ok() { printf '\033[32m[OK]\033[0m %s\n' "$*"; }

require() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

field() {
    local file="$1" key="$2"
    awk -F '\t' -v wanted="$key" '$1 == wanted {sub($1 FS, ""); print; exit}' "$file"
}

extension_info_field() {
    local info="$1" key="$2"
    sed -n "s/^[[:space:]]*$key:[[:space:]]*//p" <<<"$info" | head -n 1
}

candidate_line() {
    local uuid="$1" info state path mtime
    info="$(LC_ALL=C gnome-extensions info "$uuid" 2>/dev/null || true)"
    state="$(extension_info_field "$info" State)"
    path="$(extension_info_field "$info" Path)"
    [ -n "$path" ] || path="$HOME/.local/share/gnome-shell/extensions/$uuid"
    [ "$state" = ACTIVE ] || return 0
    [ -f "$path/extension.js" ] || return 0
    case "$path" in "$HOME"/*) ;; *) return 0 ;; esac
    mtime="$(stat -c %Y "$path/extension.js" 2>/dev/null || printf 0)"
    printf '%s\t%s\t%s\n' "$mtime" "$uuid" "$path"
}

select_extension() {
    local requested="${1:-${GNOME_WAYLAND_RELOAD_TEST_UUID:-}}"
    local info state path candidates selected

    if [ -n "$requested" ]; then
        info="$(LC_ALL=C gnome-extensions info "$requested" 2>/dev/null || true)"
        state="$(extension_info_field "$info" State)"
        path="$(extension_info_field "$info" Path)"
        [ -n "$path" ] || path="$HOME/.local/share/gnome-shell/extensions/$requested"
        [ "$state" = ACTIVE ] || die "$requested must be ACTIVE; found ${state:-missing}"
        [ -f "$path/extension.js" ] || die "missing $path/extension.js"
        case "$path" in "$HOME"/*) ;; *) die "refusing non-user extension path: $path" ;; esac
        printf '%s\t%s\n' "$requested" "$path"
        return
    fi

    candidates="$(
        while IFS= read -r uuid; do
            [ -n "$uuid" ] && candidate_line "$uuid"
        done < <(gnome-extensions list --enabled)
    )"
    [ -n "$candidates" ] || die "no ACTIVE user extension with extension.js was found; rerun with a UUID"
    selected="$(sort -nr <<<"$candidates" | head -n 1)"
    printf '%s\t%s\n' "$(cut -f2 <<<"$selected")" "$(cut -f3- <<<"$selected")"
}

snapshot_path() {
    local label="$1" path="$2" session="$3"
    if [ -e "$path" ] || [ -L "$path" ]; then
        cp -a -- "$path" "$session/$label"
        printf '%s\tpresent\n' "$label" >> "$session/state.tsv"
    else
        printf '%s\tabsent\n' "$label" >> "$session/state.tsv"
    fi
}

restore_path() {
    local label="$1" path="$2" session="$3" state
    state="$(field "$session/state.tsv" "$label")"
    rm -rf -- "$path"
    if [ "$state" = present ]; then
        mkdir -p "$(dirname "$path")"
        cp -a -- "$session/$label" "$path"
    fi
}

prepare() {
    local selection uuid ext_dir stamp session marker prepared_at branch head

    require git
    require python3
    require node
    require gnome-extensions
    require journalctl
    require sha256sum

    branch="$(git -C "$ROOT" branch --show-current)"
    [ "$branch" = agent/looking-glass-agent-execution ] ||
        die "switch to agent/looking-glass-agent-execution first (current: $branch)"
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
    snapshot_path agents "$AGENT_SKILL" "$session"
    snapshot_path hermes "$HERMES_SKILL" "$session"
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

    info "Installing the PR tree over whatever is installed now"
    "$ROOT/install.sh" --skip-devkit
    cmp -s "$ROOT/scripts/looking-glass-hotswap.sh" "$AGENT_SKILL/scripts/looking-glass-hotswap.sh"
    cmp -s "$ROOT/scripts/looking-glass-hotswap.sh" "$HERMES_SKILL/scripts/looking-glass-hotswap.sh"
    ok "Agent and Hermes skill copies match the PR"

    printf '\n// [%s] fresh Shell import proof\nconsole.log(%q);\n' \
        "$marker" "[$marker] extension.js imported" >> "$ext_dir/extension.js"

    grep -Fq "$marker" "$ext_dir/extension.js"
    sha256sum "$session/extension.js.before" "$ext_dir/extension.js" > "$session/extension.sha256"

    printf '\nPrepared fresh-login acceptance test\n'
    printf '  PR head:   %s\n' "$head"
    printf '  Extension: %s\n' "$uuid"
    printf '  Path:      %s\n' "$ext_dir"
    printf '  Marker:    %s\n' "$marker"
    printf '  State:     %s\n\n' "$session"
    printf 'Log out and back in. Then run exactly:\n\n'
    printf '  cd %q && ./scripts/test-execution-pr.sh verify\n\n' "$ROOT"
}

verify() {
    local session root head uuid ext_dir marker prepared_at info state log
    [ -L "$LATEST" ] || die "no prepared session; run prepare first"
    session="$(readlink -f "$LATEST")"
    [ -f "$session/session.tsv" ] || die "invalid latest session: $session"

    root="$(field "$session/session.tsv" root)"
    head="$(field "$session/session.tsv" head)"
    uuid="$(field "$session/session.tsv" uuid)"
    ext_dir="$(field "$session/session.tsv" extension_dir)"
    marker="$(field "$session/session.tsv" marker)"
    prepared_at="$(field "$session/session.tsv" prepared_at)"

    [ "$(git -C "$root" rev-parse HEAD)" = "$head" ] || die "checkout moved away from prepared PR head"
    cmp -s "$root/scripts/looking-glass-hotswap.sh" "$AGENT_SKILL/scripts/looking-glass-hotswap.sh"
    cmp -s "$root/scripts/looking-glass-hotswap.sh" "$HERMES_SKILL/scripts/looking-glass-hotswap.sh"
    grep -Fq "$marker" "$ext_dir/extension.js"

    info="$(LC_ALL=C gnome-extensions info "$uuid")"
    state="$(extension_info_field "$info" State)"
    [ "$state" = ACTIVE ] || die "$uuid is not ACTIVE after login: ${state:-unknown}"

    log="$(journalctl -b --since "$prepared_at" -o cat --no-pager /usr/bin/gnome-shell 2>/dev/null || true)"
    grep -Fq "[$marker] extension.js imported" <<<"$log" ||
        die "fresh Shell marker not found in the current boot journal"

    printf '%s\n' "$log" | grep -F "[$marker] extension.js imported" > "$session/journal-proof.txt"
    printf '%s\n' "$info" > "$session/extension-info.after.txt"
    printf 'VERIFIED\n' > "$session/result"

    ok "Fresh Shell loaded the marked extension.js"
    ok "$uuid is ACTIVE"
    ok "Installed Agent and Hermes skills match PR head $head"
    printf '\nProof directory: %s\n' "$session"
    printf 'Restore the marker and previous skill installs with:\n\n'
    printf '  cd %q && ./scripts/test-execution-pr.sh restore\n\n' "$root"
}

restore() {
    local session ext_dir
    [ -L "$LATEST" ] || die "no prepared session to restore"
    session="$(readlink -f "$LATEST")"
    ext_dir="$(field "$session/session.tsv" extension_dir)"

    [ -f "$session/extension.js.before" ] || die "missing extension backup"
    install -m 0644 "$session/extension.js.before" "$ext_dir/extension.js"
    restore_path agents "$AGENT_SKILL" "$session"
    restore_path hermes "$HERMES_SKILL" "$session"
    printf 'RESTORED\n' > "$session/restored"
    rm -f "$LATEST"
    ok "Extension source and previous skill installations restored"
    printf 'The restored extension.js becomes active at the next fresh Shell login.\n'
}

case "${1:-}" in
    prepare)
        [ "$#" -le 2 ] || { usage >&2; exit 2; }
        prepare "${2:-}"
        ;;
    verify)
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        verify
        ;;
    restore)
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        restore
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
