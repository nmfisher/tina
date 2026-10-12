# tina_cwd_tui

Displays `cwd: /path/to/workspace` in the status bar for the active session.
Long paths are shortened from the left to preserve the workspace name.

The application registers `tina/cwd-tui`, enabled by default. Toggle it live
in Settings → Plugins. Configurations with an explicit enabled list can add
`tina/cwd-tui` there or enable it through a scoped plugin override.

The assembly supplies the session's working directory, including `--cwd`.
The view does not read the TUI process's CWD. A shell command's temporary `cd`
does not change the session directory. Each attachment has its own disposable
status binding, with visibility controlled by the existing status layout.
