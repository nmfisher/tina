# tina_tui

Reusable terminal rendering over session operations and presentation data.
The application in [`apps/tina_cli`](../../apps/tina_cli/README.md) constructs
sessions and feature views, supplies settings operations, and owns shutdown.

- `SessionView` receives a `SessionConnection` and `SessionPresentation`.
  Each view owns its subscriptions, dialogs and rendering state.
- `runApp` accepts a view, an optional workspace and application callbacks for
  session creation and cleanup. Without an ownership callback, exiting detaches
  the view while the borrowed session continues.
- `SettingsPanel` receives `SettingsManagement` operations and sanitized drafts.
- `SessionPicker` receives display-only `SessionChoice` records. It cannot open
  the session store.
- `StartupTerminal` owns the screen, input and terminal modes from startup through
  the render loop. ANSI and notcurses use the same frontend behavior.

This package has no dependency on concrete feature plugins, provider/configuration
implementations, persistence or the application. Architecture tests enforce this
for both imports and manifests. Feature-specific views remain in `*_tui` packages.

Run `dart test` here for renderer tests. Application wiring, configuration,
lifecycle and compiled terminal smokes are tested from `apps/tina_cli`.
