#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT="${GNOME_WAYLAND_RELOAD_HOTSWAP_HOME:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/gnome-wayland-reload/hotswap}"

usage() {
    cat <<'USAGE'
Usage:
  looking-glass-hotswap.sh [--one-line] [--token TOKEN] UUID
  looking-glass-hotswap.sh prepare [--token TOKEN] UUID
  looking-glass-hotswap.sh show RECEIPT.json
  looking-glass-hotswap.sh executed RECEIPT.json
  looking-glass-hotswap.sh verify RECEIPT.json
  looking-glass-hotswap.sh abort RECEIPT.json

Generate or run the guarded GNOME Shell 49–50 Looking Glass hot-swap workflow.
This private diagnostic is only for a top-level extension.js change with
reliable lifecycle cleanup. Prefer scripts/dev-shell.sh for normal development.

  --one-line    Print one evaluator-safe line instead of readable JavaScript.
  --token       Supply a verification token (primarily for deterministic tests).
  prepare       Create a payload plus durable machine-readable receipt.
  show          Verify payload integrity, then print the exact one-line payload.
  executed      Record that the prepared payload was submitted exactly once.
  verify        Prove the exact token in the Shell journal and ACTIVE state.
  abort         Mark an unexecuted prepared receipt as aborted.

Exit status:
  0  command completed or receipt VERIFIED
  1  exact execution proof was found but transaction verification FAILED
  2  usage, receipt, dependency, or integrity error
  3  verification remains INCONCLUSIVE; re-checking the same receipt is safe
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

validate_token() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) fail "token contains unsupported characters" ;;
    esac
}

new_token() {
    local now
    now="$(date +%s%N 2>/dev/null || date +%s)"
    printf '%s-%s\n' "$now" "$$"
}

make_snippet() {
    local uuid="$1"
    local reload_token="$2"

    cat <<EOF_JS
const uuid = '$uuid';
const reloadToken = '$reload_token';
const marker = \`[gnome-wayland-reload:\${reloadToken}]\`;
const manager = Main.extensionManager;
const requiredMethods = [
    'lookup',
    '_callExtensionDisable',
    '_callExtensionEnable',
    '_changeExtensionState',
];
let ExtensionState = null;
let extension = null;
let previousState = null;
let nextState = null;
let startingOrder = [];
let startingOrderIndex = -1;
let phase = 'preflight';
let mutationStarted = false;
let disableCompleted = false;
let proof;
let rollback = {
    needed: false,
    attempted: false,
    ok: null,
    replacementCleanupAttempted: false,
    replacementCleanupOk: null,
    stateObjectRestored: false,
    activeStateRestored: false,
    orderBookkeepingRestored: false,
    error: null,
};
const stateName = state => {
    if (!ExtensionState)
        return String(state);
    return Object.keys(ExtensionState).find(name => ExtensionState[name] === state) ?? String(state);
};
const appendRollbackError = message => {
    rollback.error = rollback.error ? \`\${rollback.error}; \${message}\` : message;
};
const restoreOrderBookkeeping = () => {
    const currentIndex = manager._extensionOrder.indexOf(uuid);
    if (currentIndex >= 0)
        manager._extensionOrder.splice(currentIndex, 1);
    manager._extensionOrder.splice(startingOrderIndex, 0, uuid);
    return JSON.stringify(manager._extensionOrder) === JSON.stringify(startingOrder);
};
try {
    for (const method of requiredMethods) {
        if (typeof manager[method] !== 'function')
            throw new Error(\`Unsupported GNOME Shell internals: missing \${method}\`);
    }
    if (!Array.isArray(manager._extensionOrder))
        throw new Error('Unsupported GNOME Shell internals: missing extension order');
    extension = manager.lookup(uuid);
    if (!extension)
        throw new Error(\`Extension not found: \${uuid}\`);
    ({ExtensionState} = await import(
        'resource:///org/gnome/shell/misc/extensionUtils.js'
    ));
    if (extension.state !== ExtensionState.ACTIVE)
        throw new Error(\`Extension must start ACTIVE, found \${stateName(extension.state)}\`);
    if (!extension.stateObj)
        throw new Error('Extension has no live state object');
    startingOrder = [...manager._extensionOrder];
    startingOrderIndex = startingOrder.indexOf(uuid);
    if (startingOrderIndex < 0)
        throw new Error('ACTIVE extension is absent from extension order');
    previousState = extension.stateObj;

    phase = 'import-replacement';
    const file = extension.dir.get_child('extension.js');
    if (!file.query_exists(null))
        throw new Error(\`Missing installed extension.js: \${file.get_path()}\`);
    const module = await import(
        \`\${file.get_uri()}?reload=\${encodeURIComponent(reloadToken)}\`
    );

    phase = 'construct-replacement';
    nextState = new module.default({
        ...extension.metadata,
        dir: extension.dir,
        path: extension.path,
    });

    phase = 'disable-current';
    mutationStarted = true;
    await manager._callExtensionDisable(uuid);
    if (extension.state !== ExtensionState.INACTIVE)
        throw new Error(\`Disable did not reach INACTIVE: \${stateName(extension.state)}\`);
    disableCompleted = true;

    phase = 'enable-replacement';
    extension.stateObj = nextState;
    await manager._callExtensionEnable(uuid);
    if (extension.state !== ExtensionState.ACTIVE || extension.stateObj !== nextState)
        throw new Error(\`Replacement did not reach ACTIVE: \${stateName(extension.state)}\`);

    phase = 'restore-order';
    const orderImmediatelyAfterEnable = [...manager._extensionOrder];
    const orderBookkeepingRestored = restoreOrderBookkeeping();
    if (!orderBookkeepingRestored)
        throw new Error('Extension-order bookkeeping could not be restored');

    phase = 'complete';
    const orderAfter = [...manager._extensionOrder];
    proof = {
        ok: true,
        uuid,
        token: reloadToken,
        phase,
        state: extension.state,
        stateName: stateName(extension.state),
        stateObjectReplaced: extension.stateObj === nextState,
        startingOrder,
        orderImmediatelyAfterEnable,
        orderAfter,
        reenableMovedTarget:
            orderImmediatelyAfterEnable.indexOf(uuid) !== startingOrderIndex,
        orderBookkeepingRestored,
        rollback,
    };
} catch (error) {
    rollback.needed = mutationStarted;
    if (disableCompleted && extension && previousState) {
        rollback.attempted = true;
        try {
            if (extension.stateObj === nextState && nextState) {
                rollback.replacementCleanupAttempted = true;
                try {
                    if (extension.state === ExtensionState.ACTIVE) {
                        await manager._callExtensionDisable(uuid);
                        if (extension.state !== ExtensionState.INACTIVE)
                            throw new Error(
                                \`replacement disable did not reach INACTIVE: \${stateName(extension.state)}\`
                            );
                    } else {
                        await nextState.disable();
                    }
                    rollback.replacementCleanupOk = true;
                } catch (cleanupError) {
                    rollback.replacementCleanupOk = false;
                    appendRollbackError(\`replacement cleanup: \${cleanupError.message}\`);
                }
            }

            extension.stateObj = previousState;
            if (extension.state !== ExtensionState.INACTIVE)
                manager._changeExtensionState(extension, ExtensionState.INACTIVE);
            await manager._callExtensionEnable(uuid);
            rollback.stateObjectRestored = extension.stateObj === previousState;
            rollback.activeStateRestored = extension.state === ExtensionState.ACTIVE;
            rollback.orderBookkeepingRestored =
                rollback.activeStateRestored && restoreOrderBookkeeping();
            const replacementCleanupProven =
                !rollback.replacementCleanupAttempted ||
                rollback.replacementCleanupOk === true;
            rollback.ok = replacementCleanupProven &&
                rollback.stateObjectRestored &&
                rollback.activeStateRestored &&
                rollback.orderBookkeepingRestored;
            if (!rollback.ok && !rollback.error)
                appendRollbackError('rollback proof is incomplete; manual recovery required');
        } catch (rollbackError) {
            rollback.ok = false;
            appendRollbackError(rollbackError.message);
        }
    } else if (mutationStarted && extension && previousState) {
        rollback.attempted = true;
        rollback.stateObjectRestored = extension.stateObj === previousState;
        rollback.activeStateRestored = extension.state === ExtensionState.ACTIVE;
        rollback.orderBookkeepingRestored = restoreOrderBookkeeping();
        rollback.ok = false;
        appendRollbackError(
            'current disable failed before a safe INACTIVE boundary; manual recovery required'
        );
    } else {
        rollback.ok = true;
    }
    proof = {
        ok: false,
        uuid,
        token: reloadToken,
        phase,
        error: error.message,
        state: extension?.state ?? null,
        stateName: extension ? stateName(extension.state) : null,
        stateObjectReplaced: extension?.stateObj === nextState && nextState !== null,
        startingOrder,
        orderAfter: extension ? [...manager._extensionOrder] : [],
        rollback,
    };
}
/* hot-swap proof */
console[proof.ok ? 'log' : 'error'](\`\${marker} \${JSON.stringify(proof)}\`);
JSON.stringify(proof)
EOF_JS
}

emit_snippet() {
    local uuid="$1"
    local reload_token="$2"
    local one_line="$3"
    local snippet

    snippet="$(make_snippet "$uuid" "$reload_token")"
    if [ "$one_line" = true ]; then
        printf '%s' "$snippet" | tr '\n' ' '
        printf '\n'
    else
        printf '%s\n' "$snippet"
    fi
}

receipt_field() {
    local receipt="$1"
    local field="$2"
    python3 - "$receipt" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1:]
with open(path, encoding='utf-8') as handle:
    data = json.load(handle)
if field not in data or data[field] is None:
    raise SystemExit(f'missing receipt field: {field}')
print(data[field])
PY
}

write_prepared_receipt() {
    local receipt="$1"
    local uuid="$2"
    local token="$3"
    local prepared_at="$4"
    local prepared_epoch="$5"
    local payload="$6"
    local payload_sha256="$7"

    python3 - "$receipt" "$uuid" "$token" "$prepared_at" "$prepared_epoch" \
        "$payload" "$payload_sha256" <<'PY'
import json
import os
import sys
import tempfile

receipt, uuid, token, prepared_at, prepared_epoch, payload, payload_sha256 = sys.argv[1:]
data = {
    'schema': 2,
    'status': 'PREPARED',
    'uuid': uuid,
    'token': token,
    'marker': f'[gnome-wayland-reload:{token}]',
    'prepared_at': prepared_at,
    'prepared_epoch': int(prepared_epoch),
    'payload_file': payload,
    'payload_sha256': payload_sha256,
    'receipt_file': receipt,
    'verification_attempts': 0,
    'next_stage': 'OPEN_LOOKING_GLASS',
}

directory = os.path.dirname(receipt)
fd, temporary = tempfile.mkstemp(prefix='.receipt.', suffix='.tmp', dir=directory)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write('\n')
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, receipt)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print(json.dumps(data, sort_keys=True))
PY
}

verify_payload_integrity() {
    local receipt="$1"
    local status payload expected actual

    require_command python3
    require_command sha256sum
    [ -f "$receipt" ] || fail "receipt not found: $receipt"
    status="$(receipt_field "$receipt" status)"
    [ "$status" = PREPARED ] || fail "receipt is not PREPARED: $status"
    payload="$(receipt_field "$receipt" payload_file)"
    expected="$(receipt_field "$receipt" payload_sha256)"
    [ -f "$payload" ] || fail "payload not found: $payload"
    actual="$(sha256sum "$payload" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || fail "payload hash does not match receipt"
    [ "$(wc -l < "$payload")" -eq 1 ] || fail "agent payload is not exactly one line"
    printf '%s\n' "$payload"
}

update_receipt() {
    local receipt="$1"
    local operation="$2"
    local status="${3:-}"
    local proof_json="${4:-}"
    local extension_active="${5:-false}"
    local extension_info="${6:-}"
    local diagnostic="${7:-}"

    if ! python3 - "$receipt" "$operation" "$status" "$proof_json" \
        "$extension_active" "$extension_info" "$diagnostic" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

receipt, operation, status, proof_json, extension_active, extension_info, diagnostic = sys.argv[1:]
with open(receipt, encoding='utf-8') as handle:
    data = json.load(handle)

now = datetime.now(timezone.utc).astimezone().isoformat(timespec='seconds')
if operation == 'executed':
    if data.get('status') != 'PREPARED':
        raise SystemExit(f"receipt is not PREPARED: {data.get('status')}")
    data['status'] = 'EXECUTED'
    data['executed_at'] = now
    data['next_stage'] = 'TOKEN_VERIFICATION'
elif operation == 'verify':
    if data.get('status') not in {'EXECUTED', 'INCONCLUSIVE'}:
        raise SystemExit(f"receipt is not EXECUTED or INCONCLUSIVE: {data.get('status')}")
    data['status'] = status
    data['last_checked_at'] = now
    data['verification_attempts'] = int(data.get('verification_attempts', 0)) + 1
    data['extension_active'] = extension_active == 'true'
    data['extension_info'] = extension_info
    data.pop('journal_proof', None)
    data.pop('journal_diagnostic', None)
    if proof_json:
        data['journal_proof'] = json.loads(proof_json)
    if diagnostic:
        data['journal_diagnostic'] = diagnostic
    if status == 'VERIFIED':
        data['verified_at'] = now
        data['next_stage'] = 'BEHAVIOR_VERIFICATION'
    elif status == 'FAILED':
        data['next_stage'] = 'RECOVER_OR_ESCALATE'
    else:
        data['next_stage'] = 'RECHECK_OR_INSPECT'
elif operation == 'abort':
    if data.get('status') != 'PREPARED':
        raise SystemExit(f"receipt is not PREPARED: {data.get('status')}")
    data['status'] = 'ABORTED'
    data['aborted_at'] = now
    data['next_stage'] = None
else:
    raise SystemExit(f'unknown receipt operation: {operation}')

directory = os.path.dirname(receipt)
fd, temporary = tempfile.mkstemp(prefix='.receipt.', suffix='.tmp', dir=directory)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write('\n')
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, receipt)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print(json.dumps(data, sort_keys=True))
PY
    then
        fail "could not update receipt: $receipt"
    fi
}

prepare() {
    local uuid="$1"
    local requested_token="${2:-}"
    local token prepared_at prepared_epoch session_dir payload receipt payload_sha256

    validate_uuid "$uuid"
    require_command python3
    require_command sha256sum
    token="$requested_token"
    if [ -z "$token" ]; then
        token="$(new_token)"
    fi
    validate_token "$token"
    prepared_at="$(date --iso-8601=seconds)"
    prepared_epoch="$(date +%s)"
    session_dir="$STATE_ROOT/$token"
    payload="$session_dir/payload.js"
    receipt="$session_dir/receipt.json"

    umask 077
    mkdir -p "$STATE_ROOT"
    mkdir "$session_dir" || fail "hot-swap receipt already exists for token: $token"
    emit_snippet "$uuid" "$token" true > "$payload"
    payload_sha256="$(sha256sum "$payload" | awk '{print $1}')"
    write_prepared_receipt "$receipt" "$uuid" "$token" "$prepared_at" \
        "$prepared_epoch" "$payload" "$payload_sha256"
}

show_payload() {
    local receipt="$1"
    local payload
    payload="$(verify_payload_integrity "$receipt")"
    cat "$payload"
}

mark_executed() {
    local receipt="$1"
    verify_payload_integrity "$receipt" >/dev/null
    update_receipt "$receipt" executed
}

extract_proof_json() {
    local marker="$1"
    python3 -c '
import sys
marker = sys.argv[1]
matches = []
for line in sys.stdin:
    if marker in line:
        matches.append(line.split(marker, 1)[1].strip())
if matches:
    print(matches[-1])
' "$marker"
}

verify_receipt() {
    local receipt="$1"
    local uuid token marker prepared_at status journal proof_json info
    local extension_active validation final_status diagnostic validation_rc

    require_command python3
    require_command journalctl
    require_command gnome-extensions
    [ -f "$receipt" ] || fail "receipt not found: $receipt"
    status="$(receipt_field "$receipt" status)"
    case "$status" in
        EXECUTED|INCONCLUSIVE) ;;
        *) fail "receipt is not EXECUTED or INCONCLUSIVE: $status" ;;
    esac
    uuid="$(receipt_field "$receipt" uuid)"
    token="$(receipt_field "$receipt" token)"
    marker="$(receipt_field "$receipt" marker)"
    prepared_at="$(receipt_field "$receipt" prepared_at)"
    validate_uuid "$uuid"
    validate_token "$token"

    journal="$(journalctl --since "$prepared_at" -b -o cat --no-pager \
        /usr/bin/gnome-shell 2>/dev/null || true)"
    proof_json="$(printf '%s\n' "$journal" | extract_proof_json "$marker")"
    info="$(LC_ALL=C gnome-extensions info "$uuid" 2>&1 || true)"
    extension_active=false
    if grep -Eq '^[[:space:]]*State:[[:space:]]+ACTIVE([[:space:]]|$)' <<< "$info"; then
        extension_active=true
    fi

    if [ -z "$proof_json" ]; then
        update_receipt "$receipt" verify INCONCLUSIVE '' "$extension_active" \
            "$info" "exact token marker was not found in the GNOME Shell journal"
        return 3
    fi

    if validation="$(python3 - "$proof_json" "$uuid" "$token" "$extension_active" <<'PY'
import json
import sys

raw, uuid, token, extension_active = sys.argv[1:]
try:
    proof = json.loads(raw)
except json.JSONDecodeError as error:
    print(f'INCONCLUSIVE\tjournal proof is not valid JSON: {error}')
    raise SystemExit(3)

ok = (
    proof.get('ok') is True
    and proof.get('uuid') == uuid
    and proof.get('token') == token
    and proof.get('phase') == 'complete'
    and proof.get('stateObjectReplaced') is True
    and proof.get('orderBookkeepingRestored') is True
    and extension_active == 'true'
)
print(('VERIFIED' if ok else 'FAILED') + '\t')
PY
)"; then
        validation_rc=0
    else
        validation_rc=$?
    fi
    final_status="${validation%%$'\t'*}"
    diagnostic="${validation#*$'\t'}"

    case "$validation_rc" in
        0)
            update_receipt "$receipt" verify "$final_status" "$proof_json" \
                "$extension_active" "$info" "$diagnostic"
            [ "$final_status" = VERIFIED ]
            ;;
        3)
            update_receipt "$receipt" verify INCONCLUSIVE '' "$extension_active" \
                "$info" "$diagnostic"
            return 3
            ;;
        *)
            fail "could not validate journal proof"
            ;;
    esac
}

abort_receipt() {
    local receipt="$1"
    require_command python3
    [ -f "$receipt" ] || fail "receipt not found: $receipt"
    update_receipt "$receipt" abort
}

case "${1:-}" in
    prepare)
        shift
        prepare_token=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --token)
                    [ "$#" -ge 2 ] || fail "--token requires a value"
                    prepare_token="$2"
                    shift 2
                    ;;
                --help|-h)
                    usage
                    exit 0
                    ;;
                --*)
                    fail "unknown prepare option: $1"
                    ;;
                *)
                    break
                    ;;
            esac
        done
        [ "$#" -eq 1 ] || { usage >&2; exit 2; }
        prepare "$1" "$prepare_token"
        exit
        ;;
    show)
        [ "$#" -eq 2 ] || { usage >&2; exit 2; }
        show_payload "$2"
        exit
        ;;
    executed)
        [ "$#" -eq 2 ] || { usage >&2; exit 2; }
        mark_executed "$2"
        exit
        ;;
    verify)
        [ "$#" -eq 2 ] || { usage >&2; exit 2; }
        verify_receipt "$2"
        exit
        ;;
    abort)
        [ "$#" -eq 2 ] || { usage >&2; exit 2; }
        abort_receipt "$2"
        exit
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    '')
        usage >&2
        exit 2
        ;;
esac

one_line=false
reload_token=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --one-line)
            one_line=true
            shift
            ;;
        --token)
            [ "$#" -ge 2 ] || fail "--token requires a value"
            reload_token="$2"
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
            break
            ;;
    esac
done

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
uuid="$1"
validate_uuid "$uuid"
if [ -z "$reload_token" ]; then
    reload_token="$(new_token)"
fi
validate_token "$reload_token"

cat >&2 <<EOF_WARNING
warning: private GNOME Shell diagnostic; the old module remains cached
warning: use only for a top-level extension.js change with reliable cleanup
next: open Looking Glass (Alt+F2, lg) and submit the complete payload once
proof: require the exact marker [gnome-wayland-reload:$reload_token]
proof: expect ok=true and token=$reload_token in the evaluator or Shell journal
EOF_WARNING

emit_snippet "$uuid" "$reload_token" "$one_line"
