#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

passed=0
failed=0

pass() { printf 'ok - %s\n' "$1"; ((passed++)) || true; }
fail() { printf 'not ok - %s\n' "$1" >&2; ((failed++)) || true; }
assert() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

for script in "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/scripts/"*.sh "$ROOT/tests/run.sh"; do
    assert "shell syntax: ${script#"$ROOT/"}" bash -n "$script"
done

validator="${SKILL_VALIDATOR:-$HOME/.codex/skills/.system/skill-creator/scripts/quick_validate.py}"
if [ -f "$validator" ]; then
    assert "canonical skill passes quick_validate.py" python3 "$validator" "$ROOT"
else
    assert "canonical skill has matching name" grep -q '^name: gnome-wayland-reload$' "$ROOT/SKILL.md"
    assert "canonical skill has a description" grep -q '^description: ' "$ROOT/SKILL.md"
fi

assert "trigger description covers stale extension code" \
    grep -q 'not taking effect' "$ROOT/SKILL.md"
assert "trigger description covers ineffective lifecycle cycling" \
    grep -q 'disable/enable did not load new code' "$ROOT/SKILL.md"
assert "trigger description covers host hot-swaps" \
    grep -q 'cache-busted host hot-swap' "$ROOT/SKILL.md"
assert "trigger description covers unsafe restart questions" \
    grep -q 'gnome-shell --replace, logout/login' "$ROOT/SKILL.md"
assert "trigger description excludes unrelated desktop automation" \
    grep -q 'ordinary GNOME app automation' "$ROOT/SKILL.md"
assert "skill metadata permits implicit invocation" \
    grep -q '^  allow_implicit_invocation: true$' "$ROOT/agents/openai.yaml"
assert "OpenAI skill frontmatter stays minimal" sh -c \
    'sed -n "2,/^---$/p" "$1" | grep -Eq "^(name|description):" && ! sed -n "2,/^---$/p" "$1" | grep -Eq "^(version|author|license|platforms|metadata):"' \
    sh "$ROOT/SKILL.md"
assert "Hermes payload starts with use-when triggering" \
    grep -q '^  Use when GNOME Shell extension changes' "$ROOT/runtimes/hermes-frontmatter.yaml"
assert "Hermes payload carries versioned platform metadata" sh -c \
    'grep -q "^version: " "$1" && grep -q "^platforms: \[linux\]" "$1" && grep -q "^  hermes:$" "$1"' \
    sh "$ROOT/runtimes/hermes-frontmatter.yaml"

assert "README references the canonical install URL" \
    grep -q 'ryanraposo.github.io/gnome-wayland-reload/install.sh' "$ROOT/README.md"
assert "license is explicit MIT" grep -q '^MIT License$' "$ROOT/LICENSE"
assert "README introduces the Reloop mascot" grep -q 'Reloop, the nested-Shell mechanic' "$ROOT/README.md"
assert "README hero is text, not an image" sh -c \
    '! grep -q "<img" "$1" && grep -q "<pre>" "$1"' sh "$ROOT/README.md"
assert "Reloop mascot keeps its block-character face" grep -q '0x0' "$ROOT/assets/mascot.txt"
assert "Reloop mascot carries a staff" grep -q '█──█' "$ROOT/assets/mascot.txt"
assert "social preview is a PNG" sh -c \
    'test "$(od -An -tx1 -N8 "$1" | tr -d " \n")" = 89504e470d0a1a0a' \
    sh "$ROOT/assets/github-social-preview.png"
assert "social preview is the only image asset" sh -c \
    'test "$(find "$1/assets" -maxdepth 1 -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o -iname "*.gif" -o -iname "*.svg" \) -printf "%f\n")" = github-social-preview.png' \
    sh "$ROOT"

reserved_private_word="$(printf '\157\162\142')"
if grep -RIl --exclude-dir=.git -i -- "$reserved_private_word" "$ROOT" | grep -q . ||
   find "$ROOT" -path "$ROOT/.git" -prune -o -iname "*$reserved_private_word*" -print | grep -q .; then
    fail "reserved private vocabulary stays absent"
else
    pass "reserved private vocabulary stays absent"
fi

install_help=$("$ROOT/install.sh" --help)
assert "installer advertises integrated devkit setup" \
    grep -q -- '--skip-devkit' <<< "$install_help"

devkit_home="$TEST_TMP/devkit-home"
devkit_bin="$TEST_TMP/devkit-bin"
devkit_state="$TEST_TMP/devkit-installed"
devkit_log="$TEST_TMP/pkexec.log"
mkdir -p "$devkit_home" "$devkit_bin"
cat > "$devkit_bin/dpkg-query" <<'SH'
#!/usr/bin/env bash
[ -f "$DEVKIT_STATE" ] || exit 1
case "$*" in
    *'${Status}'*) printf 'install ok installed' ;;
    *'${Version}'*) printf '50.1-test' ;;
    *) exit 1 ;;
esac
SH
cat > "$devkit_bin/pkexec" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PKEXEC_LOG"
[ "$*" = 'apt-get install -y mutter-dev-bin' ] || exit 1
: > "$DEVKIT_STATE"
SH
cat > "$devkit_bin/apt-get" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$devkit_bin/"*
DEVKIT_STATE="$devkit_state" PKEXEC_LOG="$devkit_log" \
HOME="$devkit_home" AGENTS_HOME="$devkit_home/.agents" \
HERMES_HOME="$devkit_home/.hermes" \
GNOME_WAYLAND_RELOAD_STATE_HOME="$devkit_home/state" \
PATH="$devkit_bin:/usr/bin:/bin" \
    "$ROOT/install.sh" --agents-only > "$TEST_TMP/devkit-install.out"
assert "installer uses a narrow graphical package prompt" \
    grep -qx 'apt-get install -y mutter-dev-bin' "$devkit_log"
assert "installer verifies the installed development runner" \
    grep -q 'Nested Shell development runner installed (50.1-test)' "$TEST_TMP/devkit-install.out"
assert "installer explains the development runner simply" sh -c \
    'grep -q "fresh GNOME Shell test sessions in a window" "$1" && grep -q "without logging out or restarting your real desktop" "$1"' \
    sh "$TEST_TMP/devkit-install.out"
assert "installer output uses three numbered phases" sh -c \
    'grep -q "\[1/3\]" "$1" && grep -q "\[2/3\]" "$1" && grep -q "\[3/3\]" "$1"' \
    sh "$TEST_TMP/devkit-install.out"
assert "installer output reports launch and next actions" sh -c \
    'grep -q "All done\." "$1" && grep -q "Launch:" "$1" && grep -q "Next:" "$1"' \
    sh "$TEST_TMP/devkit-install.out"

agents_home="$TEST_TMP/agents"
hermes_home="$TEST_TMP/hermes"
state_home="$TEST_TMP/state"
AGENTS_HOME="$agents_home" HERMES_HOME="$hermes_home" \
GNOME_WAYLAND_RELOAD_STATE_HOME="$state_home" "$ROOT/install.sh" --skip-devkit > "$TEST_TMP/install.out"
assert "successful install prints alternate Reloop" grep -q '\^x\^' "$TEST_TMP/install.out"
assert "successful install prints alternate staff pose" grep -q '^█───█' "$TEST_TMP/install.out"
assert "local install creates Agent Skills copy" test -f "$agents_home/skills/gnome-wayland-reload/SKILL.md"
assert "local install creates Hermes copy" test -f "$hermes_home/skills/gnome-wayland-reload/SKILL.md"
assert "Agent install keeps OpenAI UI metadata" \
    test -f "$agents_home/skills/gnome-wayland-reload/agents/openai.yaml"
assert "Hermes install omits OpenAI-only UI metadata" \
    test ! -e "$hermes_home/skills/gnome-wayland-reload/agents/openai.yaml"
assert "Hermes install carries Hermes-native metadata" \
    grep -q '^version: 2.3.3$' "$hermes_home/skills/gnome-wayland-reload/SKILL.md"
assert "local install includes GNOME 50 debugging reference" \
    test -f "$agents_home/skills/gnome-wayland-reload/references/gnome-50-debugging-notes.md"
assert "local install includes the Reloop mascot" \
    test -f "$agents_home/skills/gnome-wayland-reload/assets/mascot.txt"
assert "installed copy has managed marker" test -f "$agents_home/skills/gnome-wayland-reload/.gnome-wayland-reload-managed"
assert "installed helper remains executable" test -x "$agents_home/skills/gnome-wayland-reload/scripts/dev-shell.sh"
assert "installed hot-swap helper remains executable" \
    test -x "$agents_home/skills/gnome-wayland-reload/scripts/looking-glass-hotswap.sh"
assert "installed update helper remains executable" \
    test -x "$agents_home/skills/gnome-wayland-reload/scripts/check-update.sh"

update_remote="$TEST_TMP/update-remote"
update_state="$TEST_TMP/update-state"
mkdir -p "$update_remote"
printf '9.9.9\n' > "$update_remote/VERSION"
update_out=$(GNOME_WAYLAND_RELOAD_BASE_URL="file://$update_remote" \
    GNOME_WAYLAND_RELOAD_UPDATE_STATE_HOME="$update_state" \
    "$ROOT/scripts/check-update.sh" --force)
assert "update checker reports a newer published version" \
    grep -q '2.3.3 -> 9.9.9' <<< "$update_out"
printf '0.0.1\n' > "$update_remote/VERSION"
cached_out=$(GNOME_WAYLAND_RELOAD_BASE_URL="file://$update_remote" \
    GNOME_WAYLAND_RELOAD_UPDATE_STATE_HOME="$update_state" \
    "$ROOT/scripts/check-update.sh")
assert "update checker caches the successful lookup" \
    grep -q '2.3.3 -> 9.9.9' <<< "$cached_out"
offline_out=$(GNOME_WAYLAND_RELOAD_BASE_URL='file:///does-not-exist' \
    GNOME_WAYLAND_RELOAD_UPDATE_STATE_HOME="$TEST_TMP/offline-state" \
    "$ROOT/scripts/check-update.sh" --force --quiet)
assert "offline quiet update checks are nonfatal" test -z "$offline_out"

AGENTS_HOME="$agents_home" HERMES_HOME="$hermes_home" \
GNOME_WAYLAND_RELOAD_STATE_HOME="$state_home" "$ROOT/install.sh" --skip-devkit >/dev/null
assert "installer is idempotent" test -f "$hermes_home/skills/gnome-wayland-reload/assets/mascot.txt"

backup_agents="$TEST_TMP/backup-agents"
backup_hermes="$TEST_TMP/backup-hermes"
backup_state="$TEST_TMP/backup-state"
mkdir -p "$backup_agents/skills/gnome-wayland-reload"
printf 'original\n' > "$backup_agents/skills/gnome-wayland-reload/original.txt"
AGENTS_HOME="$backup_agents" HERMES_HOME="$backup_hermes" \
GNOME_WAYLAND_RELOAD_STATE_HOME="$backup_state" "$ROOT/install.sh" --agents-only --skip-devkit >/dev/null
AGENTS_HOME="$backup_agents" HERMES_HOME="$backup_hermes" \
GNOME_WAYLAND_RELOAD_STATE_HOME="$backup_state" "$ROOT/uninstall.sh" --agents-only --restore >/dev/null
assert "uninstall --restore recovers an unmanaged prior skill" \
    test -f "$backup_agents/skills/gnome-wayland-reload/original.txt"

remote_agents="$TEST_TMP/remote-agents"
remote_hermes="$TEST_TMP/remote-hermes"
remote_state="$TEST_TMP/remote-state"
AGENTS_HOME="$remote_agents" HERMES_HOME="$remote_hermes" \
GNOME_WAYLAND_RELOAD_STATE_HOME="$remote_state" \
GNOME_WAYLAND_RELOAD_BASE_URL="file://$ROOT" bash -s -- --skip-devkit < "$ROOT/install.sh" >/dev/null
assert "curl-pipe mode fetches the full bundle" test -f "$remote_agents/skills/gnome-wayland-reload/scripts/recycle-extension.sh"

AGENTS_HOME="$agents_home" HERMES_HOME="$hermes_home" \
GNOME_WAYLAND_RELOAD_STATE_HOME="$state_home" "$ROOT/uninstall.sh" >/dev/null
assert "uninstaller removes Agent Skills discovery path" test ! -e "$agents_home/skills/gnome-wayland-reload"
assert "uninstaller removes Hermes discovery path" test ! -e "$hermes_home/skills/gnome-wayland-reload"
assert "uninstaller archives managed copies" test -f "$(find "$state_home/removed" -path '*/agents/SKILL.md' -print -quit)"

mock_bin="$TEST_TMP/mock-bin"
mkdir -p "$mock_bin"
printf '%s\n' '#!/usr/bin/env bash' \
    'case "$1" in' \
    '  info) exit 0 ;;' \
    '  list) printf "%s\\n" "test@example.com" ;;' \
    '  disable|enable) printf "%s\\n" "$*" >> "$MOCK_LOG" ;;' \
    'esac' > "$mock_bin/gnome-extensions"
chmod +x "$mock_bin/gnome-extensions"
MOCK_LOG="$TEST_TMP/recycle.log" GNOME_EXTENSION_RECYCLE_DELAY=0 \
PATH="$mock_bin:/usr/bin:/bin" "$ROOT/scripts/recycle-extension.sh" test@example.com >/dev/null
assert "recycle helper disables then enables" \
    test "$(tr '\n' ' ' < "$TEST_TMP/recycle.log")" = 'disable test@example.com enable test@example.com '
assert "development helper exposes usage" "$ROOT/scripts/dev-shell.sh" --help
dev_shell_bin="$TEST_TMP/dev-shell-bin"
mkdir -p "$dev_shell_bin"
cat > "$dev_shell_bin/gnome-shell" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Usage: gnome-shell --devkit --wayland'
SH
cat > "$dev_shell_bin/dbus-run-session" <<'SH'
#!/usr/bin/env bash
exit 99
SH
cat > "$dev_shell_bin/dpkg-query" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$dev_shell_bin/"*
dev_shell_rc=0
PATH="$dev_shell_bin:/usr/bin:/bin" "$ROOT/scripts/dev-shell.sh" \
    > /dev/null 2> "$TEST_TMP/dev-shell-missing.err" || dev_shell_rc=$?
assert "development helper refuses an incomplete runner" test "$dev_shell_rc" -ne 0
assert "development helper explains how to enable nested testing" sh -c \
    'grep -q "fresh GNOME Shell test sessions in a window" "$1" && grep -q "pkexec apt-get install -y mutter-dev-bin" "$1"' \
    sh "$TEST_TMP/dev-shell-missing.err"
assert "source inspector exposes usage" "$ROOT/scripts/inspect-shell-source.sh" --help
assert "hot-swap helper emits the requested UUID" \
    grep -q "const uuid = 'test@example.com';" \
        <("$ROOT/scripts/looking-glass-hotswap.sh" test@example.com 2>/dev/null)
hot_swap_out=$("$ROOT/scripts/looking-glass-hotswap.sh" test@example.com 2> "$TEST_TMP/hot-swap.err")
assert "hot-swap helper proves state-object replacement" sh -c \
    'printf "%s\n" "$1" | grep -q "stateObjectReplaced: extension.stateObj === nextState" && printf "%s\n" "$1" | grep -q "hot-swap proof"' \
    sh "$hot_swap_out"
assert "hot-swap helper emits a unique verification token" sh -c \
    'grep -Eq "proof: expect ok=true and token=[0-9]+-[0-9]+" "$1" && printf "%s\n" "$2" | grep -Eq "const reloadToken = '\''[0-9]+-[0-9]+'\'';"' \
    sh "$TEST_TMP/hot-swap.err" "$hot_swap_out"
hot_swap_one_line=$("$ROOT/scripts/looking-glass-hotswap.sh" --one-line test@example.com 2>/dev/null)
assert "hot-swap helper emits a complete single-line evaluator payload" sh -c \
    'test "$(printf "%s" "$1" | wc -l)" -eq 0 && printf "%s" "$1" | grep -q "^const uuid = .*JSON.stringify(proof)$"' \
    sh "$hot_swap_one_line"
assert "skill routes no-logout host reloads to Looking Glass, not soft cycle" sh -c \
    'grep -q "reload without logout/login" "$1" && grep -q "Do not silently substitute a soft cycle" "$1" && grep -q -- "--one-line UUID" "$1"' \
    sh "$ROOT/SKILL.md"
assert "skill requires deploy before Looking Glass and rejects cached-import false proof" sh -c \
    'grep -q "deploy bytes first, hot-swap second" "$1" && grep -q "proof does not mean that imported code changed" "$1"' \
    sh "$ROOT/SKILL.md"
assert "skill warns that undefined evaluator output is inconclusive" sh -c \
    'grep -q "evaluator result" "$1" && grep -q "undefined.*inconclusive" "$1"' \
    sh "$ROOT/SKILL.md"
assert "skill guards against animation sampling aliases" sh -c \
    'grep -q "one loop period" "$1" && grep -q "can look identical" "$1"' \
    sh "$ROOT/SKILL.md"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
