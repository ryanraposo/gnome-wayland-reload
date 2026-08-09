#!/usr/bin/env python3
"""Automate one exact Looking Glass payload submission on GNOME Wayland.

Observation and element targeting use cua-driver SOM captures. Keyboard input
uses cua-driver first and deliberately falls back to ydotool when Wayland input
delivery needs it. The payload is verified in the evaluator before Enter is
submitted, so callers can safely treat ``injected=true`` as one submission.

Usage:
    lg-autohotswap.py RECEIPT MARKER PAYLOAD_FILE

Output:
    injected=true
or a diagnostic ``injected=false ...`` on stderr with a non-zero exit status.
"""

from __future__ import annotations

import json
import os
import selectors
import shutil
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

CUA_HOST = os.environ.get("CUA_HOST", "127.0.0.1")
CUA_PORT = int(os.environ.get("CUA_PORT", "6847"))
INPUT_MODE = os.environ.get("GNOME_WAYLAND_RELOAD_INPUT", "auto").lower()
TEXT_ROLES = {"text", "entry", "textfield", "textbox"}


def send_frame(sock: socket.socket, obj: object) -> None:
    data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    sock.sendall(struct.pack("!I", len(data)) + data)


def recv_frame(sock: socket.socket) -> dict[str, Any]:
    header = b""
    while len(header) < 4:
        chunk = sock.recv(4 - len(header))
        if not chunk:
            raise ConnectionError("connection closed waiting for frame header")
        header += chunk

    length = struct.unpack("!I", header)[0]
    body = b""
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            raise ConnectionError("connection closed waiting for frame body")
        body += chunk

    value = json.loads(body.decode("utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError("cua-driver returned a non-object response")
    return value


class CuaConnection:
    """Small cua-driver client that keeps targeting indices capture-local."""

    def __init__(self, host: str = CUA_HOST, port: int = CUA_PORT) -> None:
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sel = selectors.DefaultSelector()
        self.sel.register(self.sock, selectors.EVENT_READ)

    def request(self, method: str, **params: object) -> dict[str, Any]:
        send_frame(
            self.sock,
            {"jsonrpc": "2.0", "method": method, "params": params},
        )
        response = recv_frame(self.sock)
        if "error" in response:
            raise RuntimeError(f"cua-driver error: {response['error']}")
        result = response.get("result", {})
        return result if isinstance(result, dict) else {}

    def close(self) -> None:
        try:
            self.sel.unregister(self.sock)
        except KeyError:
            pass
        self.sock.close()

    def capture(self) -> dict[str, Any]:
        """Capture screenshot metadata plus the SOM accessibility index."""
        return self.request("capture", app="", mode="som")

    def send_key(self, keys: str) -> None:
        self.request("key", key=keys)

    def type_text(self, text: str) -> None:
        self.request("type", text=text)

    def click_element(self, element: int) -> None:
        self.request("click", element=element)


def som_elements(capture: dict[str, Any]) -> list[dict[str, Any]]:
    raw = capture.get("elements", [])
    return [item for item in raw if isinstance(item, dict)] if isinstance(raw, list) else []


def element_index(element: dict[str, Any]) -> int | None:
    """Return only an index supplied by SOM; never invent one from list order."""
    for key in ("index", "element"):
        value = element.get(key)
        if isinstance(value, int) and value > 0:
            return value
    return None


def element_text(element: dict[str, Any]) -> str:
    for key in ("value", "text", "label", "name"):
        value = element.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def matching_elements(
    capture: dict[str, Any],
    *,
    role: str | None = None,
    label_contains: str | None = None,
) -> list[dict[str, Any]]:
    matches: list[dict[str, Any]] = []
    needle = label_contains.lower() if label_contains is not None else None
    for element in som_elements(capture):
        current_role = str(element.get("role", "")).lower()
        if role is not None and current_role != role.lower():
            continue
        if needle is not None and needle not in element_text(element).lower():
            continue
        if element_index(element) is None:
            continue
        matches.append(element)
    return matches


def has_lookin_glass(capture: dict[str, Any]) -> bool:
    labels = "\n".join(element_text(item).lower() for item in som_elements(capture))
    return "evaluator" in labels or "extensions" in labels


def has_text_input(capture: dict[str, Any]) -> bool:
    return any(
        str(item.get("role", "")).lower() in TEXT_ROLES
        for item in som_elements(capture)
    )


def ydotool_available() -> bool:
    return shutil.which("ydotool") is not None


def run_ydotool(*args: str) -> None:
    if not ydotool_available():
        raise RuntimeError("ydotool is not available")
    completed = subprocess.run(
        ["ydotool", *args],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or f"exit {completed.returncode}"
        raise RuntimeError(f"ydotool failed: {detail}")


def ydotool_alt_f2() -> None:
    # Linux input-event codes: LEFTALT=56, F2=60.
    run_ydotool("key", "56:1", "60:1", "60:0", "56:0")


def ydotool_enter() -> None:
    # KEY_ENTER=28.
    run_ydotool("key", "28:1", "28:0")


def ydotool_clear_field() -> None:
    # LEFTCTRL=29, A=30, BACKSPACE=14.
    run_ydotool("key", "29:1", "30:1", "30:0", "29:0", "14:1", "14:0")


def ydotool_type(text: str) -> None:
    run_ydotool("type", "--key-delay", "1", text)


def open_once(driver: CuaConnection, use_ydotool: bool) -> bool:
    if use_ydotool:
        ydotool_alt_f2()
    else:
        driver.send_key("alt+F2")
    time.sleep(0.6)

    capture = driver.capture()
    if has_lookin_glass(capture):
        return True
    if not has_text_input(capture):
        return False

    if use_ydotool:
        ydotool_type("lg")
        ydotool_enter()
    else:
        driver.type_text("lg")
        driver.send_key("return")
    time.sleep(1.2)
    return has_lookin_glass(driver.capture())


def open_lookin_glass(driver: CuaConnection) -> bool:
    """Open Looking Glass, escalating keyboard delivery to ydotool if needed."""
    if has_lookin_glass(driver.capture()):
        return True

    if INPUT_MODE not in {"auto", "cua", "ydotool"}:
        raise RuntimeError(
            "GNOME_WAYLAND_RELOAD_INPUT must be auto, cua, or ydotool"
        )

    attempts: list[bool]
    if INPUT_MODE == "cua":
        attempts = [False]
    elif INPUT_MODE == "ydotool":
        attempts = [True]
    else:
        attempts = [False] + ([True] if ydotool_available() else [])

    for use_ydotool in attempts:
        backend = "ydotool" if use_ydotool else "cua-driver"
        print(f"[auto] opening Looking Glass via {backend}", file=sys.stderr)
        try:
            if open_once(driver, use_ydotool):
                return True
        except RuntimeError as exc:
            print(f"[auto] {backend} open attempt failed: {exc}", file=sys.stderr)
        time.sleep(0.4)
    return False


def click_extensions_if_present(driver: CuaConnection) -> None:
    capture = driver.capture()
    buttons = matching_elements(capture, role="button", label_contains="extension")
    if not buttons:
        return
    index = element_index(buttons[0])
    if index is None:
        return
    driver.click_element(index)
    time.sleep(0.4)


def evaluator_entry(driver: CuaConnection) -> tuple[int, dict[str, Any]] | None:
    """Return one evaluator-like text entry and its capture-local SOM index."""
    capture = driver.capture()
    elements = som_elements(capture)

    explicit = [
        item
        for item in elements
        if str(item.get("role", "")).lower() in TEXT_ROLES
        and "evaluator" in element_text(item).lower()
        and element_index(item) is not None
    ]
    candidates = explicit or [
        item
        for item in elements
        if str(item.get("role", "")).lower() in TEXT_ROLES
        and element_index(item) is not None
    ]
    if not candidates:
        return None

    item = candidates[0]
    index = element_index(item)
    return (index, item) if index is not None else None


def payload_visible(driver: CuaConnection, payload: str) -> bool:
    """Prove the evaluator contains the exact payload before submission."""
    capture = driver.capture()
    for item in som_elements(capture):
        if str(item.get("role", "")).lower() not in TEXT_ROLES:
            continue
        for key in ("value", "text"):
            value = item.get(key)
            if isinstance(value, str) and value == payload:
                return True
    return False


def type_payload_verified(driver: CuaConnection, payload: str) -> str:
    entry = evaluator_entry(driver)
    if entry is None:
        raise RuntimeError("could not locate the Looking Glass evaluator input")

    index, _ = entry
    driver.click_element(index)
    time.sleep(0.2)

    if INPUT_MODE != "ydotool":
        try:
            driver.type_text(payload)
            time.sleep(0.4)
            if payload_visible(driver, payload):
                return "cua-driver"
        except RuntimeError as exc:
            print(f"[auto] cua-driver typing failed: {exc}", file=sys.stderr)

    if INPUT_MODE == "cua" or not ydotool_available():
        raise RuntimeError("payload was not visible exactly in the evaluator")

    # Typing is still pre-submit, so a verified clear + retype is safe.
    entry = evaluator_entry(driver)
    if entry is None:
        raise RuntimeError("evaluator disappeared before ydotool fallback")
    index, _ = entry
    driver.click_element(index)
    time.sleep(0.2)
    ydotool_clear_field()
    ydotool_type(payload)
    time.sleep(0.4)
    if not payload_visible(driver, payload):
        raise RuntimeError("ydotool typed payload could not be verified exactly")
    return "ydotool"


def submit_once(driver: CuaConnection) -> str:
    """Submit exactly once after payload verification."""
    if INPUT_MODE != "cua" and ydotool_available():
        ydotool_enter()
        return "ydotool"
    driver.send_key("return")
    return "cua-driver"


def inject_payload(driver: CuaConnection, payload: str) -> tuple[bool, str]:
    click_extensions_if_present(driver)
    typed_by = type_payload_verified(driver, payload)
    submitted_by = submit_once(driver)
    time.sleep(0.8)
    return True, f"typed_by={typed_by} submitted_by={submitted_by}"


def main() -> None:
    if len(sys.argv) != 4:
        print(
            "injected=false wrong_arg_count expected RECEIPT MARKER PAYLOAD_FILE",
            file=sys.stderr,
        )
        raise SystemExit(2)

    receipt_path = Path(sys.argv[1])
    marker = sys.argv[2]
    payload_path = Path(sys.argv[3])

    if not receipt_path.exists():
        print(f"injected=false receipt_not_found:{receipt_path}", file=sys.stderr)
        raise SystemExit(2)
    if not payload_path.exists():
        print(f"injected=false payload_not_found:{payload_path}", file=sys.stderr)
        raise SystemExit(2)

    with receipt_path.open(encoding="utf-8") as handle:
        receipt = json.load(handle)
    token = receipt.get("token")
    if not isinstance(token, str) or not token:
        print("injected=false missing_token_in_receipt", file=sys.stderr)
        raise SystemExit(2)

    payload = payload_path.read_text(encoding="utf-8").strip()
    if not payload.startswith("const uuid"):
        print("injected=false invalid_payload_format", file=sys.stderr)
        raise SystemExit(2)

    print(
        f"[auto] token={token} marker={marker} payload_bytes={len(payload.encode('utf-8'))}",
        file=sys.stderr,
    )

    connection: CuaConnection | None = None
    try:
        connection = CuaConnection(CUA_HOST, CUA_PORT)
        print("[auto] connected to cua-driver", file=sys.stderr)

        if not open_lookin_glass(connection):
            print("injected=false looking_glass_open_failed", file=sys.stderr)
            raise SystemExit(4)

        success, diagnostic = inject_payload(connection, payload)
        print(f"[auto] {diagnostic}", file=sys.stderr)
        if not success:
            print(f"injected=false {diagnostic}", file=sys.stderr)
            raise SystemExit(5)
        print("injected=true")

    except ConnectionRefusedError:
        print(
            f"injected=false cua_connection_refused({CUA_HOST}:{CUA_PORT})",
            file=sys.stderr,
        )
        raise SystemExit(6)
    except ConnectionError as exc:
        print(f"injected=false cua_connection_error:{exc}", file=sys.stderr)
        raise SystemExit(6)
    except RuntimeError as exc:
        print(f"injected=false input_or_cua_error:{exc}", file=sys.stderr)
        raise SystemExit(5)
    except SystemExit:
        raise
    except Exception as exc:
        print(f"injected=false uncaught_error:{exc}", file=sys.stderr)
        raise SystemExit(7)
    finally:
        if connection is not None:
            connection.close()


if __name__ == "__main__":
    main()
