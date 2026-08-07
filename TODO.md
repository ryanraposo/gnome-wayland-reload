# TODO

## Automate Looking Glass injection into live desktop

Current state: the host hot-swap workflow (`looking-glass-hotswap.sh`) generates
a JS snippet, then requires **manual** user action — open Looking Glass
(`Alt+F2` → `lg`), paste the snippet, and press Enter. This breaks the
agent-executable loop described in SKILL.md and AGENTS.md.

### Goal

Replace the manual step with an automated injection path that works under
Ubuntu GNOME Wayland:

1. **Preferred:** Use `computer_use` (cua-driver) to drive `Alt+F2`, type `lg`,
   wait for Looking Glass to appear, find the Extensions tab, inject the
   snippet into the command field, and press Enter. Verify via screenshot or
   console inspection that `ok=true`.

2. **Fallback:** If Looking Glass cannot be driven reliably from background,
   emit a compact self-contained one-liner that users can paste directly into
   their running Shell process (e.g., via a dbus method or a small helper
   script that reads the snippet from stdin and feeds it to `gnome-shell`).

### Design constraints

- Must work on GNOME 50 / Wayland. No X11 assumptions.
- No focus steal if possible — use background delivery mode. Escalate only
  when required (focus steal is visible but acceptable for one-shot reloads).
- Output must verify success (parse proof JSON from console/journal).
- Should integrate cleanly into the existing `--one-line` flag format so
  consumers don't need separate logic branches.

### Open questions

- Does `Alt+F2` → `lg` produce a reliable, draggable element index via
  cua-driver SOM mode? The prompt text field may be behind GTK native styling.
- Can we read the shell's console output programmatically to confirm the
  proof marker was emitted? (Requires `org.gnome.Shell.Debug` introspection
  or journalctl polling.)
- Is there a non-Looking-Glass path for dynamic GJS import into the live
  Shell process? GNOME 50 private APIs are fragile; document any viable
  alternatives.
