# Installing this project

When a user points at this repository and asks to install it:

1. Read the Install section in `README.md`.
2. Run `./install.sh` as the desktop user, never as root.
3. Install both runtime copies by default. Narrow with `--agents-only` or
   `--hermes-only` only when the user asks.
4. Report any unmanaged directory that the installer backed up.
5. Ask the user to start a fresh agent session. For an active Hermes session,
   `/reload-skills` can rescan immediately.

The installer does not install Ubuntu packages. `mutter-dev-bin` is required
only for the nested development-Shell workflow and should be installed with
the user's normal package-management approval. Prefer
`pkexec apt-get install -y mutter-dev-bin` for an agent-driven graphical
privilege prompt; do not open a general-purpose root shell.

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
