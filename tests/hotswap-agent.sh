#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/looking-glass-hotswap.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0
pass() { printf 'ok - %s\n' "$1"; ((passed++)) || true; }
fail() { printf 'not ok - %s\n' "$1" >&2; ((failed++)) || true; }
assert() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

assert "hot-swap helper has valid shell syntax" bash -n "$SCRIPT"
assert "hot-swap helper exposes agent lifecycle commands" bash -c \
    'out="$($1 --help)"; grep -q "prepare UUID" <<< "$out" && grep -q "verify RECEIPT" <<< "$out"' \
    sh "$SCRIPT"

payload="$($SCRIPT --one-line --token fixed-token test@example.com 2>/dev/null)"
assert "one-line payload is complete and evaluator-safe" sh -c \
    'test "$(printf "%s" "$1" | wc -l)" -eq 0 && printf "%s" "$1" | grep -q "^const uuid = .*JSON.stringify(proof)$"' \
    sh "$payload"
assert "payload refuses non-ACTIVE targets before mutation" \
    grep -q "Extension must start ACTIVE" <<< "$payload"
assert "payload verifies rollback and order bookkeeping" bash -c \
    'grep -q "rollback.orderBookkeepingRestored" <<< "$1" && grep -q "orderBookkeepingRestored" <<< "$1" && grep -q "stateObjectRestored" <<< "$1"' \
    sh "$payload"
assert "payload emits an exact token marker" \
    grep -q '\[gnome-wayland-reload:${reloadToken}\]' <<< "$payload"

if command -v node >/dev/null 2>&1; then
    PAYLOAD="$payload" node <<'NODE'
const command = process.env.PAYLOAD;
const lines = command.split(';');
lines.push(`return ${lines.pop()}`);
const AsyncFunction = async function () {}.constructor;
new AsyncFunction(lines.join(';'));
NODE
    pass "payload parses with Looking Glass evaluator rewriting"
else
    pass "payload parser check skipped without node"
fi

state="$TMP/state"
prepared="$(GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$state" "$SCRIPT" prepare test@example.com)"
receipt="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["receipt_file"])' "$prepared")"
prepared_payload="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["payload_file"])' "$prepared")"
token="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["token"])' "$prepared")"
assert "prepare creates private receipt and payload files" sh -c \
    'test -f "$1" && test -f "$2" && test "$(stat -c %a "$1")" = 600 && test "$(stat -c %a "$2")" = 600' \
    sh "$receipt" "$prepared_payload"
shown="$(GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$state" "$SCRIPT" show "$receipt")"
assert "show returns the exact prepared one-line payload" sh -c \
    'test "$1" = "$(cat "$2")" && test "$(printf "%s" "$1" | wc -l)" -eq 0' \
    sh "$shown" "$prepared_payload"

cp "$prepared_payload" "$TMP/payload.clean"
printf 'tamper' >> "$prepared_payload"
show_rc=0
GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$state" "$SCRIPT" show "$receipt" >/dev/null 2>&1 || show_rc=$?
assert "show refuses a payload whose hash changed" test "$show_rc" -ne 0
cp "$TMP/payload.clean" "$prepared_payload"

mock_bin="$TMP/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$MOCK_JOURNAL"
MOCK
cat > "$mock_bin/gnome-extensions" <<'MOCK'
#!/usr/bin/env bash
if [ "${MOCK_EXTENSION_ACTIVE:-true}" = true ]; then
    printf 'Name: Test\nState: ACTIVE\n'
else
    printf 'Name: Test\nState: ERROR\n'
fi
MOCK
chmod +x "$mock_bin/"*

success_proof="$(python3 - "$token" <<'PY'
import json,sys
token=sys.argv[1]
print(json.dumps({
    'ok': True,
    'uuid': 'test@example.com',
    'token': token,
    'phase': 'complete',
    'stateObjectReplaced': True,
    'orderBookkeepingRestored': True,
}))
PY
)"
MOCK_JOURNAL="prefix [gnome-wayland-reload:$token] $success_proof" \
PATH="$mock_bin:/usr/bin:/bin" \
    "$SCRIPT" verify "$receipt" > "$TMP/verified.json"
assert "verify accepts only exact-token proof plus ACTIVE state" \
    grep -q '"status": "VERIFIED"' "$receipt"
assert "verify advances to behavior verification" \
    grep -q '"next_stage": "BEHAVIOR_VERIFICATION"' "$receipt"

prepared2="$(GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$state" "$SCRIPT" prepare second@example.com)"
receipt2="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["receipt_file"])' "$prepared2")"
inconclusive_rc=0
MOCK_JOURNAL='unrelated journal line' PATH="$mock_bin:/usr/bin:/bin" \
    "$SCRIPT" verify "$receipt2" >/dev/null || inconclusive_rc=$?
assert "verify returns a distinct inconclusive exit code without exact marker" \
    test "$inconclusive_rc" -eq 3
assert "inconclusive receipt routes to recovery" sh -c \
    'grep -q "\"status\": \"INCONCLUSIVE\"" "$1" && grep -q "RECOVER_OR_ESCALATE" "$1"' \
    sh "$receipt2"

prepared3="$(GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$state" "$SCRIPT" prepare third@example.com)"
receipt3="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["receipt_file"])' "$prepared3")"
abort_out="$($SCRIPT abort "$receipt3")"
assert "abort closes a prepared workflow without host mutation" bash -c \
    'grep -q "\"status\": \"ABORTED\"" <<< "$1" && grep -q "\"status\": \"ABORTED\"" "$2"' \
    sh "$abort_out" "$receipt3"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
