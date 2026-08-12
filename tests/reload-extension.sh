#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/reload-extension.sh"
INJECT_SCRIPT="$ROOT/scripts/looking-glass-inject.sh"
DRIVER="$ROOT/scripts/lg-autohotswap.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Packaging proof: exactly one installed live-reload driver path.
grep -F 'scripts/reload-extension.sh' "$ROOT/install.sh" >/dev/null
grep -F 'scripts/looking-glass-inject.sh' "$ROOT/install.sh" >/dev/null
grep -F 'scripts/lg-autohotswap.py' "$ROOT/install.sh" >/dev/null
grep -F 'scripts/diagnose.sh' "$ROOT/install.sh" >/dev/null
grep -F 'chmod +x "$stage/scripts/"*.sh "$stage/scripts/"*.py' "$ROOT/install.sh" >/dev/null
[ ! -e "$ROOT/scripts/lg-autohotswap.sh" ]

# CUA contract proof: use the supported CLI surface and a compositor fallback.
grep -F 'health_report' "$DRIVER" >/dev/null
grep -F 'start_session' "$DRIVER" >/dev/null
grep -F 'type_text' "$DRIVER" >/dev/null
grep -F 'press_key' "$DRIVER" >/dev/null
grep -F 'ydotool' "$DRIVER" >/dev/null
grep -F 'gnome-wayland-reload-preflight' "$DRIVER" >/dev/null
! grep -F 'socket.create_connection' "$DRIVER" >/dev/null
python3 - "$DRIVER" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY

REPO="$TMP/horner-like-repo"
SOURCE="$REPO/manifestations/desktop/extension/test@example.com"
INSTALLED_REAL="$TMP/installed-real/test@example.com"
INSTALLED_LINK="$TMP/installed/test@example.com"
FAKEBIN="$TMP/bin"
INJECTOR="$TMP/fake-injector.sh"
RECYCLER="$TMP/fake-recycler.sh"
DIAGNOSE="$TMP/fake-diagnose.sh"
CALLS="$TMP/calls"
STATE_FILE="$TMP/state"

mkdir -p "$SOURCE" "$INSTALLED_REAL" "$(dirname "$INSTALLED_LINK")" "$FAKEBIN"
ln -s "$INSTALLED_REAL" "$INSTALLED_LINK"
printf 'ACTIVE\n' > "$STATE_FILE"
: > "$CALLS"

cat > "$SOURCE/metadata.json" <<'JSON'
{"uuid":"test@example.com","name":"Test Extension","shell-version":["50"]}
JSON
printf 'export default class FreshExtension {}\n' > "$SOURCE/extension.js"
printf 'fresh asset\n' > "$SOURCE/asset.txt"
printf 'export default class StaleExtension {}\n' > "$INSTALLED_REAL/extension.js"
cp "$SOURCE/metadata.json" "$INSTALLED_REAL/metadata.json"

cat > "$FAKEBIN/gnome-extensions" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'gnome-extensions %s\n' "\$*" >> '$CALLS'
case "\${1:-}" in
  info)
    [ "\${2:-}" = 'test@example.com' ] || exit 92
    printf 'Name: Test Extension\nState: %s\nPath: %s\n' "\$(cat '$STATE_FILE')" '$INSTALLED_LINK'
    ;;
  list)
    if [ "\${2:-}" = '--enabled' ] && [ "\$(cat '$STATE_FILE')" = ACTIVE ]; then
      printf 'test@example.com\n'
    fi
    ;;
  disable)
    printf 'INACTIVE\n' > '$STATE_FILE'
    ;;
  enable)
    printf 'ACTIVE\n' > '$STATE_FILE'
    ;;
  prefs)
    ;;
  *)
    echo "unexpected gnome-extensions operation: \$*" >&2
    exit 91
    ;;
esac
EOF
chmod +x "$FAKEBIN/gnome-extensions"

cat > "$INJECTOR" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'injector %s\n' "\$*" >> '$CALLS'
EOF
chmod +x "$INJECTOR"

cat > "$RECYCLER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'recycler %s\n' "\$*" >> '$CALLS'
EOF
chmod +x "$RECYCLER"

cat > "$DIAGNOSE" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'diagnose %s\n' "\$*" >> '$CALLS'
EOF
chmod +x "$DIAGNOSE"

COMMON_ENV=(
    "PATH=$FAKEBIN:$PATH"
    "GNOME_WAYLAND_RELOAD_INJECTOR=$INJECTOR"
    "GNOME_WAYLAND_RELOAD_RECYCLER=$RECYCLER"
    "GNOME_WAYLAND_RELOAD_DIAGNOSE=$DIAGNOSE"
)

# --plan must classify without changing installed bytes or runtime state.
env "${COMMON_ENV[@]}" bash "$SCRIPT" --plan "$REPO" > "$TMP/plan.out"
grep -Fx 'route=HOST_HOTSWAP' "$TMP/plan.out" >/dev/null
grep -F 'changed=' "$TMP/plan.out" | grep -F 'extension.js' >/dev/null
grep -F 'StaleExtension' "$INSTALLED_REAL/extension.js" >/dev/null
[ ! -s "$CALLS" ] || ! grep -Eq '^(injector|recycler|diagnose) ' "$CALLS"

: > "$CALLS"
env "${COMMON_ENV[@]}" \
    bash "$SCRIPT" --no-wait --token horner-proof "$REPO"

cmp -s "$SOURCE/extension.js" "$INSTALLED_REAL/extension.js"
cmp -s "$SOURCE/asset.txt" "$INSTALLED_REAL/asset.txt"
[ -L "$INSTALLED_LINK" ]
grep -Fx 'injector --no-wait --token horner-proof test@example.com' "$CALLS" >/dev/null
! grep -q '^recycler ' "$CALLS"

# Generated schemas are runtime state and must not invent a schema-change route.
mkdir -p "$INSTALLED_REAL/schemas"
printf 'compiled runtime state\n' > "$INSTALLED_REAL/schemas/gschemas.compiled"
env "${COMMON_ENV[@]}" bash "$SCRIPT" --plan "$REPO" > "$TMP/generated-schema-plan.out"
grep -Fx 'route=HOST_HOTSWAP' "$TMP/generated-schema-plan.out" >/dev/null

# Target-only imported code forces a fresh boundary and is removed by deployment.
printf 'export const stale = true;\n' > "$INSTALLED_REAL/stale-helper.js"
: > "$CALLS"
env "${COMMON_ENV[@]}" bash "$SCRIPT" --plan "$REPO" > "$TMP/stale-plan.out"
grep -Fx 'route=FRESH_PROCESS' "$TMP/stale-plan.out" >/dev/null
set +e
env "${COMMON_ENV[@]}" bash "$SCRIPT" "$REPO" > "$TMP/stale.out" 2> "$TMP/stale.err"
rc=$?
set -e
[ "$rc" -eq 4 ]
[ ! -e "$INSTALLED_REAL/stale-helper.js" ]
[ -f "$INSTALLED_REAL/schemas/gschemas.compiled" ]
[ -L "$INSTALLED_LINK" ]

# Stylesheet-only edits use a lifecycle recycle, not Looking Glass.
printf '.panel { opacity: 0.9; }\n' > "$SOURCE/stylesheet.css"
: > "$CALLS"
env "${COMMON_ENV[@]}" bash "$SCRIPT" --plan "$REPO" > "$TMP/style-plan.out"
grep -Fx 'route=SOFT_CYCLE' "$TMP/style-plan.out" >/dev/null
env "${COMMON_ENV[@]}" bash "$SCRIPT" "$REPO"
grep -Fx 'recycler test@example.com' "$CALLS" >/dev/null
! grep -q '^injector ' "$CALLS"
cmp -s "$SOURCE/stylesheet.css" "$INSTALLED_REAL/stylesheet.css"

# prefs.js is a separate process boundary and incomplete until that process reopens.
printf 'export default class Prefs {}\n' > "$SOURCE/prefs.js"
: > "$CALLS"
env "${COMMON_ENV[@]}" bash "$SCRIPT" --plan "$REPO" > "$TMP/prefs-plan.out"
grep -Fx 'route=PREFS_REOPEN' "$TMP/prefs-plan.out" >/dev/null
set +e
env "${COMMON_ENV[@]}" bash "$SCRIPT" "$REPO" > "$TMP/prefs.out" 2> "$TMP/prefs.err"
rc=$?
set -e
[ "$rc" -eq 4 ]
grep -F 'gnome-extensions prefs' "$TMP/prefs.err" >/dev/null
! grep -Eq '^(injector|recycler) ' "$CALLS"
cmp -s "$SOURCE/prefs.js" "$INSTALLED_REAL/prefs.js"

# Imported Shell-side JavaScript must cross a fresh-process boundary.
printf 'export const helper = 1;\n' > "$SOURCE/helper.js"
: > "$CALLS"
env "${COMMON_ENV[@]}" bash "$SCRIPT" --plan "$REPO" > "$TMP/import-plan.out"
grep -Fx 'route=FRESH_PROCESS' "$TMP/import-plan.out" >/dev/null
set +e
env "${COMMON_ENV[@]}" bash "$SCRIPT" "$REPO" > "$TMP/import.out" 2> "$TMP/import.err"
rc=$?
set -e
[ "$rc" -eq 4 ]
cmp -s "$SOURCE/helper.js" "$INSTALLED_REAL/helper.js"
grep -F 'live host runtime was intentionally left untouched' "$TMP/import.err" >/dev/null
! grep -Eq '^(injector|recycler) ' "$CALLS"

# ERROR is a first-class repair route: deploy candidate bytes, diagnose, no blind enable.
printf 'ERROR\n' > "$STATE_FILE"
printf 'export default class RepairedCandidate {}\n' > "$SOURCE/extension.js"
: > "$CALLS"
set +e
env "${COMMON_ENV[@]}" bash "$SCRIPT" "$REPO" > "$TMP/error.out" 2> "$TMP/error.err"
rc=$?
set -e
[ "$rc" -eq 4 ]
grep -Fx 'diagnose test@example.com' "$CALLS" >/dev/null
! grep -Eq '^(injector|recycler) ' "$CALLS"
grep -F 'RepairedCandidate' "$INSTALLED_REAL/extension.js" >/dev/null

# Installed but inactive is never silently enabled.
printf 'DISABLED\n' > "$STATE_FILE"
printf 'export default class InactiveCandidate {}\n' > "$SOURCE/extension.js"
: > "$CALLS"
set +e
env "${COMMON_ENV[@]}" bash "$SCRIPT" "$REPO" > "$TMP/inactive.out" 2> "$TMP/inactive.err"
rc=$?
set -e
[ "$rc" -eq 4 ]
grep -F 'do not silently enable it' "$TMP/inactive.err" >/dev/null
! grep -Eq '^(injector|recycler|diagnose) ' "$CALLS"

# Multiple extension roots remain an explicit decision.
mkdir -p "$REPO/another-extension"
cat > "$REPO/another-extension/metadata.json" <<'JSON'
{"uuid":"other@example.com"}
JSON
printf 'export default class OtherExtension {}\n' > "$REPO/another-extension/extension.js"

printf 'ACTIVE\n' > "$STATE_FILE"
set +e
env "${COMMON_ENV[@]}" bash "$SCRIPT" "$REPO" > "$TMP/multiple.out" 2> "$TMP/multiple.err"
rc=$?
set -e
[ "$rc" -eq 2 ]
grep -F 'multiple extension metadata.json files found' "$TMP/multiple.err" >/dev/null

# Injector regression: a failed GUI driver must never be recorded as EXECUTED.
HOTLOG="$TMP/hotswap.log"
FAKE_HOTSWAP="$TMP/fake-hotswap.sh"
FAIL_DRIVER="$TMP/fail-driver.py"
OK_DRIVER="$TMP/ok-driver.py"
: > "$HOTLOG"

cat > "$FAKE_HOTSWAP" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> '$HOTLOG'
case "\${1:-}" in
  prepare)
    shift
    token='fake-token'
    if [ "\${1:-}" = '--token' ]; then
      token="\$2"
      shift 2
    fi
    uuid="\${1:-test@example.com}"
    dir='$TMP/receipt-'"\$token"
    mkdir -p "\$dir"
    receipt="\$dir/receipt.json"
    payload="\$dir/payload.js"
    printf "const uuid = '%s';\n" "\$uuid" > "\$payload"
    python3 - "\$receipt" "\$payload" "\$token" <<'PY'
import json,sys
receipt,payload,token=sys.argv[1:]
data={
    "receipt_file": receipt,
    "payload_file": payload,
    "token": token,
    "prepared_at": "2026-08-09T00:00:00-04:00",
    "status": "PREPARED",
}
with open(receipt,"w",encoding="utf-8") as f:
    json.dump(data,f)
print(json.dumps(data))
PY
    ;;
  show)
    python3 - "\$2" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as f:
    print(open(json.load(f)["payload_file"],encoding="utf-8").read(), end="")
PY
    ;;
  executed)
    ;;
  verify)
    exit 0
    ;;
  abort)
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$FAKE_HOTSWAP"

cat > "$FAIL_DRIVER" <<'PY'
#!/usr/bin/env python3
import sys
print("injected=false simulated_driver_failure", file=sys.stderr)
raise SystemExit(5)
PY
chmod +x "$FAIL_DRIVER"

cat > "$OK_DRIVER" <<'PY'
#!/usr/bin/env python3
import pathlib
import sys

state_arg = sys.argv.index("--submission-state") + 1
pathlib.Path(sys.argv[state_arg]).write_text("SUBMITTED\n", encoding="utf-8")
print("injected=true")
PY
chmod +x "$OK_DRIVER"

: > "$HOTLOG"
set +e
GNOME_WAYLAND_RELOAD_HOTSWAP="$FAKE_HOTSWAP" \
GNOME_WAYLAND_RELOAD_DRIVER="$FAIL_DRIVER" \
GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$TMP/hotswap-state" \
    bash "$INJECT_SCRIPT" --no-wait --token failed-token test@example.com \
    > "$TMP/inject-fail.out" 2> "$TMP/inject-fail.err"
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  cat "$TMP/inject-fail.err" >&2
  echo "expected pre-submit driver failure to exit 2, got $rc" >&2
  exit 1
fi
! grep -q '^executed ' "$HOTLOG"
grep -q '^abort ' "$HOTLOG"
grep -F 'payload was not submitted; receipt aborted safely' "$TMP/inject-fail.err" >/dev/null

: > "$HOTLOG"
GNOME_WAYLAND_RELOAD_HOTSWAP="$FAKE_HOTSWAP" \
GNOME_WAYLAND_RELOAD_DRIVER="$OK_DRIVER" \
GNOME_WAYLAND_RELOAD_HOTSWAP_HOME="$TMP/hotswap-state" \
    bash "$INJECT_SCRIPT" --no-wait --token success-token test@example.com \
    > "$TMP/inject-ok.out" 2> "$TMP/inject-ok.err"
grep -q '^executed ' "$HOTLOG"
grep -q '^verify ' "$HOTLOG"

echo 'ok - state-aware reload routes, exact deployment, Wayland targeting, and exact-once injector semantics'
