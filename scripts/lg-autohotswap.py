#!/usr/bin/env python3
"""Automated Looking Glass Injection Driver (lg-autohotswap).

Uses cua-driver to drive GNOME Looking Glass end-to-end:
    Alt+F2 → type "lg" → enter → click Extensions → click Evaluator → paste payload → enter

Communicates with cua-driver via localhost:6847 TCP socket (standard cua-port).
Exits 0 with injected=true on success; exits 4+ with diagnostic info on GUI failure.

Usage:
    lg-autohotswap.py RECEIPT MARKER PAYLOAD_FILE

Arguments:
    RECEIPT    Path to the prepared receipt.json from looking-glass-hotswap.sh
    MARKER     Exact marker string, e.g. [gnome-wayland-reload:token]
    PAYLOAD_FILE   File containing the one-line JS payload

Returns (one line on stdout):
    injected=true|false  <diagnostic_json>
"""

from __future__ import annotations

import json
import os
import selectors
import socket
import struct
import sys
import time
from pathlib import Path

CUA_HOST = os.environ.get("CUA_HOST", "127.0.0.1")
CUA_PORT = int(os.environ.get("CUA_PORT", "6847"))

# ---------------------------------------------------------------------------
# Protocol helpers — cua-driver speaks JSON over TCP with length-prefixed frames
# Frame format: 4 bytes big-endian uint32 length, then that many bytes of JSON
# ---------------------------------------------------------------------------


def send_frame(sock: socket.socket, obj) -> None:
    """Send a JSON frame over a cua-driver socket."""
    data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    sock.sendall(struct.pack("!I", len(data)) + data)


def recv_frame(sock: socket.socket) -> dict:
    """Receive a single JSON frame from cua-driver."""
    # Read 4-byte length header
    header = b""
    while len(header) < 4:
        chunk = sock.recv(4 - len(header))
        if not chunk:
            raise ConnectionError("Connection closed waiting for frame header")
        header += chunk
    length = struct.unpack("!I", header)[0]

    # Read body
    body = b""
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            raise ConnectionError("Connection closed waiting for frame body")
        body += chunk

    return json.loads(body.decode("utf-8"))


# ---------------------------------------------------------------------------
# High-level actions wrapping cua-driver frames
# ---------------------------------------------------------------------------


class CuaConnection:
    """Thin wrapper around a live cua-driver TCP session."""

    def __init__(self, host: str = CUA_HOST, port: int = CUA_PORT) -> None:
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sel = selectors.DefaultSelector()
        self.sel.register(self.sock, selectors.EVENT_READ)

    def request(self, method: str, **params) -> dict:
        """Send a method call and wait for response."""
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        send_frame(self.sock, msg)
        resp = recv_frame(self.sock)

        if "error" in resp:
            raise RuntimeError(f"cua-driver error: {resp['error']}")
        return resp.get("result", {})

    def close(self) -> None:
        try:
            self.sel.unregister(self.sock)
        except KeyError:
            pass
        self.sock.close()

    # --- convenience wrappers ---

    def capture(self) -> dict:
        """Take a screenshot + AX tree capture."""
        return self.request("capture", app="", mode="ax")

    def send_key(self, keys: str) -> dict:
        """Send keyboard shortcut(s)."""
        return self.request("key", key=keys)

    def type_text(self, text: str) -> dict:
        """Type text into focused element."""
        return self.request("type", text=text)

    def click_element(self, element: int) -> dict:
        """Click by SOM element index."""
        return self.request("click", element=element)

    def find_elements(self, role: str | None = None, label_contains: str | None = None):
        """Return list of element dicts matching criteria from current capture."""
        cap = self.capture()
        elements = cap.get("elements", [])
        results = []
        for i, el in enumerate(elements):
            if role and el.get("role") != role:
                continue
            if label_contains and label_contains.lower() not in el.get("label", "").lower():
                continue
            results.append({"index": i + 1, **el})
        return results


# ---------------------------------------------------------------------------
# Core automation sequence
# ---------------------------------------------------------------------------


def open_lookin_glass(driver: CuaConnection, retries: int = 2) -> bool:
    """Open Looking Glass via Alt+F2 → lg → Enter. Returns True on success."""
    for attempt in range(retries):
        if attempt > 0:
            print(f"[auto] Retry {attempt}: opening Looking Glass …", file=sys.stderr)
            time.sleep(0.5)

        driver.send_key("alt+F2")
        time.sleep(0.6)

        # Capture and look for either a run-dialog text input or already-open LG
        cap = driver.capture()
        elements = cap.get("elements", [])

        # Check if LG is already open (look for "evaluator" button/tab)
        has_evaluator = any(
            "evaluator" in el.get("label", "").lower() for el in elements
        )
        has_ext = any(
            "extensions" in el.get("label", "").lower()
            for el in elements
            if el.get("role") == "button"
        )
        if has_evaluator or has_ext:
            print("[auto] Looking Glass appears to be open", file=sys.stderr)
            return True

        # Verify a text input exists (run dialog)
        has_input = any(
            el.get("role") in ("text", "entry", "textfield") for el in elements
        )
        if not has_input:
            # Fallback: try clicking center of screen to regain focus, then retry
            print(
                "[auto] No text input visible after Alt+F2, refocusing …",
                file=sys.stderr,
            )
            driver.click_element(1)  # Click top-most element
            time.sleep(0.3)
            driver.send_key("alt+F2")
            time.sleep(0.6)

        # Type "lg"
        driver.type_text("lg")
        time.sleep(0.3)

        # Press Enter
        driver.send_key("return")
        time.sleep(1.2)

        # Verify LG opened
        cap2 = driver.capture()
        elements2 = cap2.get("elements", [])
        has_eval2 = any(
            "evaluator" in el.get("label", "").lower() for el in elements2
        )
        has_ext2 = any(
            "extensions" in el.get("label", "").lower()
            for el in elements2
            if el.get("role") == "button"
        )
        if has_eval2 or has_ext2:
            print("[auto] ✓ Looking Glass opened", file=sys.stderr)
            return True

    return False


def find_evaluate_entry(driver: CuaConnection) -> int | None:
    """Find the Evaluator text entry in Looking Glass Extensions tab.

    Returns the 1-based element index or None.
    """
    elements = driver.find_elements(label_contains="evaluator")
    if elements:
        return elements[0]["index"]

    # Broader search: any text entry near "Evaluate" button
    buttons = driver.find_elements(role="button", label_contains="evaluate")
    text_inputs = driver.find_elements(
        role="text", label_contains=""
    )  # all text roles

    if text_inputs and buttons:
        # Prefer the first text entry near the evaluate button region
        # For simplicity, just pick the most prominent text area
        return text_inputs[0]["index"]

    return None


def inject_payload(
    driver: CuaConnection, payload: str, marker: str
) -> tuple[bool, str]:
    """Click Evaluator, type the full payload, press Enter.

    Returns (success: bool, diagnostic: str).
    """
    # Navigate to Extensions tab if not already there
    ext_btns = driver.find_elements(role="button", label_contains="extension")
    if ext_btns:
        idx = ext_btns[0]["index"]
        driver.click_element(idx)
        time.sleep(0.4)

    # Find the evaluator entry field
    entry_idx = find_evaluate_entry(driver)
    if entry_idx is None:
        return False, "Could not locate Evaluator input field"

    # Click the entry field
    driver.click_element(entry_idx)
    time.sleep(0.3)

    # Type the payload
    driver.type_text(payload)
    time.sleep(0.5)

    # Verify typing worked by checking captured text starts correctly
    cap = driver.capture()
    last_text = cap.get("last_text", "")
    if not last_text.startswith("const uuid"):
        return (
            False,
            f"Payload typing produced unexpected result: {last_text[:80]}",
        )

    # Press Enter to execute
    driver.send_key("return")
    time.sleep(3.0)  # Wait for async ES-module load cycle

    final = driver.capture()
    labels = final.get("labels", [])
    detected = marker in " ".join(labels)

    return True, f"markers_detected={detected}"


# ---------------------------------------------------------------------------
# Main orchestration
# ---------------------------------------------------------------------------


def main() -> None:
    if len(sys.argv) != 4:
        print(
            "injected=false wrong_arg_count expected RECEIPT MARKER PAYLOAD_FILE",
            file=sys.stderr,
        )
        sys.exit(2)

    receipt_path: str = sys.argv[1]
    marker: str = sys.argv[2]
    payload_path: str = sys.argv[3]

    # Validate inputs
    if not Path(receipt_path).exists():
        print(
            f"injected=false receipt_not_found:{receipt_path}",
            file=sys.stderr,
        )
        sys.exit(2)
    if not Path(payload_path).exists():
        print(
            f"injected=false payload_not_found:{payload_path}",
            file=sys.stderr,
        )
        sys.exit(2)

    with open(receipt_path, encoding="utf-8") as f:
        receipt = json.load(f)
    token = receipt.get("token", "unknown")
    if token == "unknown":
        print("injected=false missing_token_in_receipt", file=sys.stderr)
        sys.exit(2)

    with open(payload_path, encoding="utf-8") as f:
        payload = f.read().strip()

    if not payload.startswith("const uuid"):
        print("injected=false invalid_payload_format", file=sys.stderr)
        sys.exit(2)

    print(
        f"[auto] token={token} marker={marker} payload_lines={len(payload.splitlines())}",
        file=sys.stderr,
    )

    conn: CuaConnection | None = None
    try:
        # Connect to cua-driver
        conn = CuaConnection(CUA_HOST, CUA_PORT)
        print("[auto] Connected to cua-driver", file=sys.stderr)

        # Step 1: Open Looking Glass
        if not open_lookin_glass(conn):
            print(
                "injected=false looking_glass_open_failed",
                file=sys.stderr,
            )
            sys.exit(4)

        # Step 2: Inject payload into Evaluator
        success, diag = inject_payload(conn, payload, marker)
        print(f"[auto] {diag}", file=sys.stderr)

        if success:
            print("injected=true")
        else:
            print(f"injected=false {diag}", file=sys.stderr)
            sys.exit(5)

    except ConnectionRefusedError:
        print(
            f"injected=false cua_connection_refused({CUA_HOST}:{CUA_PORT})",
            file=sys.stderr,
        )
        sys.exit(6)
    except ConnectionError as exc:
        print(f"injected=false cua_connection_error:{exc}", file=sys.stderr)
        sys.exit(6)
    except RuntimeError as exc:
        print(f"injected=false cua_driver_error:{exc}", file=sys.stderr)
        sys.exit(5)
    except Exception as exc:
        print(f"injected=false uncaught_error:{exc}", file=sys.stderr)
        sys.exit(7)
    finally:
        if conn:
            conn.close()


if __name__ == "__main__":
    main()
