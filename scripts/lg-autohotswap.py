#!/usr/bin/env python3
"""Submit one immutable payload through GNOME Shell 50 Looking Glass.

The driver uses cua-driver for health/capability discovery and native desktop
input when that backend is usable. On GNOME Wayland hosts where compositor
global input is unavailable, it deliberately falls back to ydotool. It never
reads or writes the clipboard; the immutable receipt and exact journal marker
are the integrity and post-submit proof.

Normal use:
    lg-autohotswap.py --submission-state FILE RECEIPT MARKER PAYLOAD_FILE

Harmless integration probe:
    lg-autohotswap.py --probe MARKER JAVASCRIPT
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

SESSION = f"gnome-wayland-reload-{os.getpid()}"
INPUT_MODE = os.environ.get("GNOME_WAYLAND_RELOAD_INPUT", "auto").lower()
CUA = os.environ.get("GNOME_WAYLAND_RELOAD_CUA_DRIVER", "cua-driver")
YDOTOOL = os.environ.get("GNOME_WAYLAND_RELOAD_YDOTOOL", "ydotool")
TOKEN_RE = re.compile(r"^[A-Za-z0-9._-]+$")


class DriverError(RuntimeError):
    pass


def log(message: str) -> None:
    print(f"[auto] {message}", file=sys.stderr)


def run(
    argv: list[str],
    *,
    input_bytes: bytes | None = None,
    timeout: float = 15,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            argv,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise DriverError(f"{argv[0]} failed to run: {exc}") from exc
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise DriverError(f"{' '.join(argv)} failed: {detail or result.returncode}")
    return result


def json_result(tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
    result = run([CUA, tool, json.dumps(arguments, separators=(",", ":"))])
    try:
        value = json.loads(result.stdout.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise DriverError(f"cua-driver {tool} returned invalid JSON") from exc
    if not isinstance(value, dict):
        raise DriverError(f"cua-driver {tool} returned a non-object")
    return value


def ensure_cua_daemon() -> bool:
    if shutil.which(CUA) is None:
        return False
    status = run([CUA, "status"], check=False)
    if status.returncode == 0:
        return True

    log("starting cua-driver daemon")
    try:
        subprocess.Popen(
            [CUA, "serve"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        return False

    for _ in range(30):
        time.sleep(0.1)
        if run([CUA, "status"], check=False).returncode == 0:
            return True
    return False


def cua_health() -> dict[str, Any] | None:
    if not ensure_cua_daemon():
        return None
    try:
        return json_result("health_report", {})
    except DriverError as exc:
        log(str(exc))
        return None


def native_wayland_input_ready(health: dict[str, Any] | None) -> bool:
    if health is None or health.get("overall") == "failed":
        return False
    checks = health.get("checks", [])
    if not isinstance(checks, list):
        return False
    for item in checks:
        if (
            isinstance(item, dict)
            and item.get("name") == "wayland_backend"
            and item.get("status") == "pass"
        ):
            return True
    return os.environ.get("XDG_SESSION_TYPE") != "wayland"


def cua_start() -> None:
    json_result("start_session", {"session": SESSION, "capture_scope": "desktop"})


def cua_end() -> None:
    try:
        json_result("end_session", {"session": SESSION})
    except DriverError:
        pass


def cua_open_looking_glass() -> None:
    common = {"session": SESSION, "scope": "desktop", "delivery_mode": "background"}
    json_result("hotkey", {**common, "keys": ["alt", "f2"]})
    time.sleep(0.15)
    json_result("type_text", {**common, "text": "lg"})
    json_result("press_key", {**common, "key": "return"})


def cua_type(text: str) -> None:
    json_result(
        "type_text",
        {
            "session": SESSION,
            "scope": "desktop",
            "delivery_mode": "background",
            "text": text,
        },
    )


def cua_enter() -> None:
    json_result(
        "press_key",
        {
            "session": SESSION,
            "scope": "desktop",
            "delivery_mode": "background",
            "key": "return",
        },
    )


def ydotool(*args: str) -> None:
    if shutil.which(YDOTOOL) is None:
        raise DriverError("ydotool is required for this GNOME Wayland input path")
    run([YDOTOOL, *args])


def ydotool_hotkey(*codes: int) -> None:
    events = [f"{code}:1" for code in codes]
    events.extend(f"{code}:0" for code in reversed(codes))
    ydotool("key", *events)


def ydotool_open_looking_glass() -> None:
    # LEFTALT=56, F2=60, ENTER=28. Keep this focus-sensitive span uninterrupted.
    ydotool_hotkey(56, 60)
    time.sleep(0.15)
    ydotool("type", "--key-delay", "1", "lg")
    ydotool_hotkey(28)


def ydotool_type(text: str) -> None:
    ydotool("type", "--key-delay", "1", text)


def ydotool_enter() -> None:
    ydotool_hotkey(28)


def validate_receipt(
    receipt_path: Path, marker: str, payload_path: Path
) -> tuple[str, str, str]:
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise DriverError(f"invalid receipt: {exc}") from exc
    if receipt.get("status") != "PREPARED":
        raise DriverError("receipt must be PREPARED")
    token = receipt.get("token")
    prepared_at = receipt.get("prepared_at")
    if not isinstance(token, str) or not token:
        raise DriverError("receipt has no token")
    if TOKEN_RE.fullmatch(token) is None:
        raise DriverError("receipt token contains unsupported characters")
    if not isinstance(prepared_at, str) or not prepared_at:
        raise DriverError("receipt has no preparation timestamp")
    if receipt.get("marker") != marker:
        raise DriverError("requested marker does not match receipt")
    payload = payload_path.read_text(encoding="utf-8").strip()
    if not payload.startswith("const uuid") or not payload.endswith("JSON.stringify(proof)"):
        raise DriverError("payload does not have the expected evaluator-safe envelope")
    if marker not in payload:
        raise DriverError("receipt marker is absent from payload")
    try:
        payload.encode("ascii")
    except UnicodeEncodeError as exc:
        raise DriverError("payload must be ASCII for deterministic keyboard injection") from exc
    digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
    if receipt.get("payload_sha256") != digest:
        raise DriverError("payload hash does not match receipt")
    return payload, token, prepared_at


def choose_backend(health: dict[str, Any] | None) -> str:
    if INPUT_MODE not in {"auto", "cua", "ydotool"}:
        raise DriverError("GNOME_WAYLAND_RELOAD_INPUT must be auto, cua, or ydotool")
    if INPUT_MODE == "cua":
        if health is None:
            raise DriverError("cua-driver is unavailable")
        return "cua-driver"
    if INPUT_MODE == "ydotool":
        return "ydotool"
    if native_wayland_input_ready(health):
        return "cua-driver"
    return "ydotool"


def write_submission_state(path: Path | None, state: str) -> None:
    if path is None:
        return
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temp.write_text(state + "\n", encoding="utf-8")
    os.chmod(temp, 0o600)
    temp.replace(path)


def open_backend(backend: str) -> None:
    if backend == "cua-driver":
        cua_start()
        cua_open_looking_glass()
    else:
        ydotool_open_looking_glass()
    time.sleep(0.8)


def type_backend(backend: str, payload: str) -> None:
    if backend == "cua-driver":
        cua_type(payload)
    else:
        ydotool_type(payload)


def enter_backend(backend: str) -> None:
    if backend == "cua-driver":
        cua_enter()
    else:
        ydotool_enter()


def journal_has(marker: str, since: str) -> bool:
    result = run(
        [
            "journalctl",
            "--since",
            since,
            "-b",
            "-o",
            "cat",
            "/usr/bin/gnome-shell",
        ],
        check=False,
        timeout=10,
    )
    return result.returncode == 0 and marker.encode() in result.stdout


def prove_evaluator_focus(backend: str, token: str, since: str) -> None:
    preflight_marker = f"[gnome-wayland-reload-preflight:{token}]"
    preflight = (
        f"console.log('{preflight_marker}'); "
        f"'{preflight_marker}'"
    )
    type_backend(backend, preflight)
    enter_backend(backend)
    for _ in range(40):
        time.sleep(0.1)
        if journal_has(preflight_marker, since):
            log("Looking Glass evaluator focus proved by exact journal preflight")
            return
    raise DriverError(
        "Looking Glass preflight marker was absent; real payload was not typed"
    )


def submit(
    payload: str,
    *,
    backend: str,
    submission_state: Path | None,
    token: str,
    prepared_at: str,
) -> None:
    open_backend(backend)
    prove_evaluator_focus(backend, token, prepared_at)
    type_backend(backend, payload)

    # The prepared file was hash-verified before typing and the evaluator focus
    # was proved with a harmless journal marker. Persist before the one-shot Enter.
    log(f"payload typed without clipboard access ({len(payload.encode('utf-8'))} bytes)")
    write_submission_state(submission_state, "SUBMITTING")
    enter_backend(backend)
    write_submission_state(submission_state, "SUBMITTED")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--submission-state", type=Path)
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("values", nargs="+")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    health = cua_health()
    backend = choose_backend(health)
    log(f"input_backend={backend} cua_health={'ok' if health else 'unavailable'}")

    try:
        if args.probe:
            if len(args.values) != 2:
                raise DriverError("--probe expects MARKER JAVASCRIPT")
            marker, payload = args.values
            if marker not in payload:
                raise DriverError("probe marker must appear in JavaScript")
            token = f"probe-{os.getpid()}"
            prepared_at = datetime.datetime.now(
                datetime.timezone.utc
            ).isoformat()
        else:
            if len(args.values) != 3:
                raise DriverError("expected RECEIPT MARKER PAYLOAD_FILE")
            receipt_path = Path(args.values[0])
            marker = args.values[1]
            payload_path = Path(args.values[2])
            payload, token, prepared_at = validate_receipt(
                receipt_path, marker, payload_path
            )

        submit(
            payload,
            backend=backend,
            submission_state=args.submission_state,
            token=token,
            prepared_at=prepared_at,
        )
        print(f"injected=true backend={backend}")
        return 0
    except DriverError as exc:
        print(f"injected=false {exc}", file=sys.stderr)
        return 5
    finally:
        if health is not None:
            cua_end()


if __name__ == "__main__":
    raise SystemExit(main())
