#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0
pass() { printf 'ok - %s\n' "$1"; ((passed++)) || true; }
fail() { printf 'not ok - %s\n' "$1" >&2; ((failed++)) || true; }
assert_route() {
    local name="$1" expected="$2" output
    if output="$(PATH="$TMP/bin:/usr/bin:/bin" \
        MOCK_STATE="${MOCK_STATE:-ACTIVE}" MOCK_PATH="${MOCK_PATH:-$TMP/installed}" \
        "$ROOT/scripts/reload-extension.sh" --plan "$TMP/source" 2>&1)" &&
        grep -qx "route=$expected" <<<"$output"; then
        pass "$name"
    else
        fail "$name"
        printf '%s\n' "$output" >&2
    fi
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gnome-extensions" <<'SH'
#!/usr/bin/env bash
if [ "${MOCK_STATE:-ACTIVE}" = NOT_INSTALLED ]; then
    exit 2
fi
cat <<EOF
test@example.com
  State: ${MOCK_STATE:-ACTIVE}
  Path: ${MOCK_PATH}
EOF
SH
chmod +x "$TMP/bin/gnome-extensions"

reset_fixture() {
    rm -rf "$TMP/source" "$TMP/installed"
    mkdir -p "$TMP/source" "$TMP/installed"
    printf '%s\n' '{"uuid":"test@example.com","shell-version":["50"]}' > "$TMP/source/metadata.json"
    printf '%s\n' 'export default class Extension {}' > "$TMP/source/extension.js"
    cp -a "$TMP/source/." "$TMP/installed/"
    MOCK_STATE=ACTIVE
    MOCK_PATH="$TMP/installed"
}

reset_fixture
before="$(sha256sum "$TMP/installed/extension.js")"
assert_route "unchanged ACTIVE extension selects deliberate host refresh" HOST_HOTSWAP
after="$(sha256sum "$TMP/installed/extension.js")"
if [ "$before" = "$after" ]; then pass "plan mode does not deploy"; else fail "plan mode does not deploy"; fi

reset_fixture
printf '%s\n' 'export default class Extension { enable() {} }' > "$TMP/source/extension.js"
assert_route "top-level extension.js selects host hot-swap" HOST_HOTSWAP

reset_fixture
mkdir -p "$TMP/source/lib" "$TMP/installed/lib"
printf '%s\n' 'export const value = 2;' > "$TMP/source/lib/state.js"
printf '%s\n' 'export const value = 1;' > "$TMP/installed/lib/state.js"
assert_route "imported Shell JavaScript selects a fresh process" FRESH_PROCESS

reset_fixture
printf '%s\n' '.panel { color: red; }' > "$TMP/source/stylesheet.css"
printf '%s\n' '.panel { color: blue; }' > "$TMP/installed/stylesheet.css"
assert_route "stylesheet-only change selects lifecycle cycle" SOFT_CYCLE

reset_fixture
printf '%s\n' 'export default class Prefs {}' > "$TMP/source/prefs.js"
printf '%s\n' 'export default class OldPrefs {}' > "$TMP/installed/prefs.js"
assert_route "preferences-only change selects preferences reopen" PREFS_REOPEN

reset_fixture
mkdir -p "$TMP/source/schemas" "$TMP/installed/schemas"
printf '%s\n' '<schemalist />' > "$TMP/source/schemas/org.test.gschema.xml"
printf '%s\n' '<schemalist></schemalist>' > "$TMP/installed/schemas/org.test.gschema.xml"
assert_route "schema XML selects schema refresh" SCHEMA_REFRESH

reset_fixture
printf '%s\n' '{"uuid":"test@example.com","shell-version":["50"],"version":2}' > "$TMP/source/metadata.json"
assert_route "metadata change selects a fresh process" FRESH_PROCESS

reset_fixture
MOCK_STATE=ERROR
assert_route "ERROR runtime state overrides artifact route" REPAIR

reset_fixture
MOCK_STATE=INACTIVE
assert_route "inactive extension is never silently enabled" INACTIVE

reset_fixture
MOCK_STATE=NOT_INSTALLED
MOCK_PATH="$TMP/missing"
assert_route "missing UUID selects installation boundary" INSTALL

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
