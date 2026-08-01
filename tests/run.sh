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

assert "README references the canonical install URL" \
    grep -q 'ryanraposo.github.io/gnome-wayland-reload/install.sh' "$ROOT/README.md"
assert "license is explicit MIT" grep -q '^MIT License$' "$ROOT/LICENSE"
assert "orb asset is valid XML-shaped SVG" grep -q '<svg ' "$ROOT/assets/orb.svg"

agents_home="$TEST_TMP/agents"
hermes_home="$TEST_TMP/hermes"
state_home="$TEST_TMP/state"
AGENTS_HOME="$agents_home" HERMES_HOME="$hermes_home" \
GNOME_WAYLAND_RELOAD_STATE_HOME="$state_home" "$ROOT/install.sh" >/dev/null
assert "local install creates Agent Skills copy" test -f "$agents_home/skills/gnome-wayland-reload/SKILL.md"
assert "local install creates Hermes copy" test -f "$hermes_home/skills/gnome-wayland-reload/SKILL.md"
assert "installed copy has managed marker" test -f "$agents_home/skills/gnome-wayland-reload/.gnome-wayland-reload-managed"
assert "installed helper remains executable" test -x "$agents_home/skills/gnome-wayland-reload/scripts/dev-shell.sh"

AGENTS_HOME="$agents_home" HERMES_HOME="$hermes_home" \
GNOME_WAYLAND_RELOAD_STATE_HOME="$state_home" "$ROOT/install.sh" >/dev/null
assert "installer is idempotent" test -f "$hermes_home/skills/gnome-wayland-reload/assets/orb.svg"

backup_agents="$TEST_TMP/backup-agents"
backup_hermes="$TEST_TMP/backup-hermes"
backup_state="$TEST_TMP/backup-state"
mkdir -p "$backup_agents/skills/gnome-wayland-reload"
printf 'original\n' > "$backup_agents/skills/gnome-wayland-reload/original.txt"
AGENTS_HOME="$backup_agents" HERMES_HOME="$backup_hermes" \
GNOME_WAYLAND_RELOAD_STATE_HOME="$backup_state" "$ROOT/install.sh" --agents-only >/dev/null
AGENTS_HOME="$backup_agents" HERMES_HOME="$backup_hermes" \
GNOME_WAYLAND_RELOAD_STATE_HOME="$backup_state" "$ROOT/uninstall.sh" --agents-only --restore >/dev/null
assert "uninstall --restore recovers an unmanaged prior skill" \
    test -f "$backup_agents/skills/gnome-wayland-reload/original.txt"

remote_agents="$TEST_TMP/remote-agents"
remote_hermes="$TEST_TMP/remote-hermes"
remote_state="$TEST_TMP/remote-state"
AGENTS_HOME="$remote_agents" HERMES_HOME="$remote_hermes" \
GNOME_WAYLAND_RELOAD_STATE_HOME="$remote_state" \
GNOME_WAYLAND_RELOAD_BASE_URL="file://$ROOT" bash < "$ROOT/install.sh" >/dev/null
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

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
