#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

check_description() {
    local file="$1"
    local label="$2"
    local description

    description=$(sed -n 's/^description:[[:space:]]*//p' "$file" | head -n1)
    [ -n "$description" ] || fail "$label has a description"
    case "$description" in
        '>'|'|'|'>-'|'|-') fail "$label description must be an inline scalar" ;;
    esac
    [ "${#description}" -le 60 ] || \
        fail "$label description is at most 60 characters"
    case "$description" in
        *.) ;;
        *) fail "$label description ends with a period" ;;
    esac
    pass "$label description is ${#description} characters"
}

check_description "$ROOT/SKILL.md" "portable skill"
check_description "$ROOT/runtimes/hermes-frontmatter.yaml" "Hermes skill"

grep -q '^## Workflow Contract$' "$ROOT/SKILL.md" || \
    fail "skill owns the workflow"
grep -q '^## Completion Receipt$' "$ROOT/SKILL.md" || \
    fail "skill defines completion proof"
pass "runtime workflow and receipt are explicit"

grep -q '/gnome-wayland-reload PATH' "$ROOT/SKILL.md" || \
    fail "direct path invocation is defined"
grep -q 'scripts/debug-extension.sh PATH' "$ROOT/SKILL.md" || \
    fail "direct path invocation routes to devkit debugging"
grep -q 'Do not.*host hot-swap planner' "$ROOT/SKILL.md" || \
    fail "direct path invocation cannot mutate the host"
pass "direct path invocation means isolated devkit debugging"

for phrase in \
    'not taking effect' \
    'disable/enable did not load new code' \
    'cache-busted host hot-swap' \
    'gnome-shell --replace, logout/login' \
    'ordinary GNOME app automation'; do
    grep -q -- "$phrase" "$ROOT/SKILL.md" || \
        fail "trigger coverage contains: $phrase"
done
pass "skill body preserves rich trigger coverage"

grep -q '^## Maintaining this repository$' "$ROOT/AGENTS.md" || \
    fail "repository guide owns maintenance"
grep -q 'Keep `AGENTS.md` repository-facing and `SKILL.md` invocation-facing' \
    "$ROOT/AGENTS.md" || fail "repository and runtime authority stay distinct"
pass "repository guidance stays repository-facing"

test -f "$ROOT/references/skill-ux-contract.md" || \
    fail "reload UX contract exists"
grep -q '^## Phase transitions$' "$ROOT/references/skill-ux-contract.md" || \
    fail "reload UX contract defines phases"
grep -q 'references/skill-ux-contract.md' "$ROOT/install.sh" || \
    fail "installer ships the reload UX contract"
grep -q 'references/research-notes.md' "$ROOT/install.sh" || \
    fail "installer ships the research record"
pass "reload UX contract is defined and delivered"

version=$(tr -d '[:space:]' < "$ROOT/VERSION")
grep -q "^version: ${version}$" "$ROOT/runtimes/hermes-frontmatter.yaml" || \
    fail "Hermes version matches VERSION"
pass "version identity is consistent"
