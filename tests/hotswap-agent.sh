#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${HOTSWAP_SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/scripts/looking-glass-hotswap.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0
pass() { printf 'ok - %s\n' "$1"; ((passed++)) || true; }
fail() { printf 'not ok - %s\n' "$1" >&2; ((failed++)) || true; }
assert() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

assert "hot-swap helper has valid shell syntax" bash -n "$SCRIPT"
assert "hot-swap helper exposes the complete agent lifecycle" bash -c \
    'out="$($1 --help)"; grep -q "prepare .*UUID" <<< "$out" && grep -q "executed RECEIPT" <<< "$out" && grep -q "verify RECEIPT" <<< "$out"' \
    sh "$SCRIPT"

payload="$($SCRIPT --one-line --token fixed-token test@example.com 2>/dev/null)"
assert "one-line payload is complete and evaluator-safe" sh -c \
    'test "$(printf "%s" "$1" | wc -l)" -eq 0 && printf "%s" "$1" | grep -q "^const uuid = .*JSON.stringify(proof)$"' \
    sh "$payload"
assert "payload refuses non-ACTIVE targets before mutation" \
    grep -q "Extension must start ACTIVE" <<< "$payload"
assert "payload fails closed when order restoration is incomplete" bash -c \
    'grep -q "phase = '\''restore-order'\''" <<< "$1" && grep -q "Extension-order bookkeeping could not be restored" <<< "$1"' \
    sh "$payload"
assert "payload requires replacement cleanup proof for rollback success" bash -c \
    'grep -q "replacementCleanupProven" <<< "$1" && grep -q "replacementCleanupOk === true" <<< "$1"' \
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
prepared="$(GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$state" \
    "$SCRIPT" prepare --token receipt-token test@example.com)"
receipt="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["receipt_file"])' "$prepared")"
prepared_payload="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["payload_file"])' "$prepared")"
token="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["token"])' "$prepared")"
assert "prepare creates private receipt and payload files" sh -c \
    'test -f "$1" && test -f "$2" && test "$(stat -c %a "$1")" = 600 && test "$(stat -c %a "$2")" = 600' \
    sh "$receipt" "$prepared_payload"
assert "prepare records schema 2 and deterministic token" sh -c \
    'grep -q "\"schema\": 2" "$1" && grep -q "\"token\": \"receipt-token\"" "$1"' \
    sh "$receipt"
shown="$(GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$state" "$SCRIPT" show "$receipt")"
assert "show returns the exact prepared one-line payload" sh -c \
    'test "$1" = "$(cat "$2")" && test "$(printf "%s" "$1" | wc -l)" -eq 0' \
    sh "$shown" "$prepared_payload"

collision_rc=0
GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$state" \
    "$SCRIPT" prepare --token receipt-token test@example.com >/dev/null 2>&1 || collision_rc=$?
assert "prepare refuses to overwrite an existing token receipt" test "$collision_rc" -eq 2

cp "$prepared_payload" "$TMP/payload.clean"
printf 'tamper' >> "$prepared_payload"
show_rc=0
GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$state" \
    "$SCRIPT" show "$receipt" >/dev/null 2>&1 || show_rc=$?
assert "show refuses a payload whose hash changed" test "$show_rc" -eq 2
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

verify_before_executed_rc=0
MOCK_JOURNAL='' PATH="$mock_bin:/usr/bin:/bin" \
    "$SCRIPT" verify "$receipt" >/dev/null 2>&1 || verify_before_executed_rc=$?
assert "verify refuses a receipt that has not been marked executed" \
    test "$verify_before_executed_rc" -eq 2
assert "premature verify leaves the receipt PREPARED" \
    grep -q '"status": "PREPARED"' "$receipt"

"$SCRIPT" executed "$receipt" > "$TMP/executed.json"
assert "executed closes the abort window and advances token verification" sh -c \
    'grep -q "\"status\": \"EXECUTED\"" "$1" && grep -q "\"next_stage\": \"TOKEN_VERIFICATION\"" "$1"' \
    sh "$receipt"
abort_executed_rc=0
"$SCRIPT" abort "$receipt" >/dev/null 2>&1 || abort_executed_rc=$?
assert "abort refuses a receipt after execution is recorded" test "$abort_executed_rc" -eq 2

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

prepared2="$(GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$state" \
    "$SCRIPT" prepare --token second-token second@example.com)"
receipt2="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["receipt_file"])' "$prepared2")"
token2="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["token"])' "$prepared2")"
"$SCRIPT" executed "$receipt2" >/dev/null
inconclusive_rc=0
MOCK_JOURNAL='unrelated journal line' PATH="$mock_bin:/usr/bin:/bin" \
    "$SCRIPT" verify "$receipt2" >/dev/null || inconclusive_rc=$?
assert "verify returns a distinct inconclusive exit code without exact marker" \
    test "$inconclusive_rc" -eq 3
assert "inconclusive receipt remains safely re-checkable" sh -c \
    'grep -q "\"status\": \"INCONCLUSIVE\"" "$1" && grep -q "RECHECK_OR_INSPECT" "$1"' \
    sh "$receipt2"
success_proof2="$(python3 - "$token2" <<'PY'
import json,sys
token=sys.argv[1]
print(json.dumps({
    'ok': True,
    'uuid': 'second@example.com',
    'token': token,
    'phase': 'complete',
    'stateObjectReplaced': True,
    'orderBookkeepingRestored': True,
}))
PY
)"
MOCK_JOURNAL="prefix [gnome-wayland-reload:$token2] $success_proof2" \
PATH="$mock_bin:/usr/bin:/bin" \
    "$SCRIPT" verify "$receipt2" >/dev/null
assert "the same inconclusive receipt can later verify without re-execution" sh -c \
    'grep -q "\"status\": \"VERIFIED\"" "$1" && grep -q "\"verification_attempts\": 2" "$1"' \
    sh "$receipt2"

prepared3="$(GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$state" \
    "$SCRIPT" prepare --token malformed-token malformed@example.com)"
receipt3="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["receipt_file"])' "$prepared3")"
"$SCRIPT" executed "$receipt3" >/dev/null
malformed_rc=0
MOCK_JOURNAL='prefix [gnome-wayland-reload:malformed-token] {broken' \
PATH="$mock_bin:/usr/bin:/bin" \
    "$SCRIPT" verify "$receipt3" >/dev/null || malformed_rc=$?
assert "malformed exact-marker proof stays inconclusive instead of crashing" \
    test "$malformed_rc" -eq 3
assert "malformed proof diagnostic is persisted" \
    grep -q 'journal proof is not valid JSON' "$receipt3"

prepared4="$(GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$state" \
    "$SCRIPT" prepare --token abort-token abort@example.com)"
receipt4="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["receipt_file"])' "$prepared4")"
abort_out="$("$SCRIPT" abort "$receipt4")"
assert "abort closes a prepared workflow without host mutation" bash -c \
    'grep -q "\"status\": \"ABORTED\"" <<< "$1" && grep -q "\"status\": \"ABORTED\"" "$2"' \
    sh "$abort_out" "$receipt4"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
