# Agent Workflow

This repo is an Emacs Lisp package. Keep changes focused on `vtab.el`, docs, tests, or the Nix development files.

Useful commands:

- `emacs -Q --batch -L . -f batch-byte-compile vtab.el`
- `nix develop`
- `nix flake check`
- `nix run .#codex-vm`

Inside the Codex MicroVM, the project is mounted at `/workspace/vtab` and Codex state is under `/home/codex/.codex`.
The default `EDITOR`, `VISUAL`, and `GIT_EDITOR` are `codex-editor`, a non-interactive no-op helper so tools that spawn an editor do not block the agent. Use `emacs` directly, or `$HUMAN_EDITOR`, when a real editor is needed.

GUI helpers inside the MicroVM:

- List visible Sway windows: `vm-windows`
- Focus a window by app id, class, or title fragment: `vm-focus emacs`
- Capture the current Wayland screen: `vm-screenshot`
- Capture one matching window: `vm-screenshot emacs`
- Type text into the focused GUI app: `vm-type "text"`
- Send keys to the focused GUI app: `vm-key Return`
- Send modified key chords: `vm-key Ctrl+x`, `vm-key C-x`, `vm-key Alt+Return`
- Move the pointer with uinput: `vm-move-mouse 500 300`
- Mouse click fallback through uinput: `vm-click`
- Open a new terminal in Sway: `Alt+Return`

Codex can use these helpers as normal commands inside the VM. Prefer keyboard-driven workflows because focus is the main source of nondeterminism:

- `vm-screenshot` is reliable and saves images under `/home/codex/screenshots`; pass a query such as `vm-screenshot emacs` to capture a matching window rectangle.
- `vm-windows` prints Sway window ids, app ids, classes, titles, focus state, and geometry.
- `vm-focus <query>` focuses the first window whose app id, class, or title contains the query, case-insensitively.
- `vm-type` and `vm-key` send input to the currently focused Wayland surface.
- `vm-key` accepts plain keys and common modifier chords. Use `+` forms such as `Ctrl+x`, `Shift+Tab`, and `Alt+Return`, or Emacs-style single-modifier forms such as `C-x` and `M-x`.
- `vm-move-mouse <x> <y>` moves the pointer to absolute output coordinates.
- `vm-click` defaults to a left click at the current pointer position.
- Use `vm-focus emacs` before typing into Emacs, or `vm-focus foot` before typing into the terminal.
- Use mouse actions only as a fallback when keyboard or `swaymsg` control is not enough.

The VM starts Codex with full permissions inside the MicroVM boundary: no Codex sandbox and no approval prompts. Treat the MicroVM as the security boundary and review generated changes before committing them.
