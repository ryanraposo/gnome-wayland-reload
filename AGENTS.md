# Installing this project

When a user points at this repository and asks to install it:

1. Read the Install section in `README.md`.
2. Run `./install.sh` as the desktop user, never as root.
3. Let the installer prepare `mutter-dev-bin` through `pkexec`. It enables a
   fresh GNOME Shell test session in a window without restarting the real
   desktop. Use `--skip-devkit` only when the user explicitly wants skill files
   without the nested-Shell runner.
4. Install both runtime copies by default. Narrow with `--agents-only` or
   `--hermes-only` only when the user asks.
5. Report any unmanaged directory that the installer backed up.
6. Ask the user to start a fresh agent session. For an active Hermes session,
   `/reload-skills` can rescan immediately.

The installer requests privilege only for
`pkexec apt-get install -y mutter-dev-bin`; do not open a general-purpose root
shell or type the user's password.

The repository root `SKILL.md` follows OpenAI Agent Skills metadata rules. The
installer composes the Hermes copy with `runtimes/hermes-frontmatter.yaml`, so
the installed payload follows Hermes's versioned, tagged metadata shape.

## Use it yourself

Read `SKILL.md`, choose the smallest refresh from its decision matrix, and
preserve the distinction between lifecycle cycling and fresh-process reloads.
Never kill or replace the active host `gnome-shell` on Wayland.

From a checkout, helpers are available directly:

```bash
./scripts/diagnose.sh
./scripts/recycle-extension.sh UUID
./scripts/dev-shell.sh
```
