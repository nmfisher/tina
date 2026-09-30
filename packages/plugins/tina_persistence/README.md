# tina_persistence

`PersistencePlugin` (`tina/persistence`) owns the session store, log subscription,
session metadata updates and resume. The application assembly injects a
`SessionStoreOpener`; the host knows only the generic plugin lifecycle.

On open, the plugin restores and validates saved sessions. New sessions are
registered only when the first log entry is recorded; opening and quitting,
unsent drafts, and model metadata changes alone do not create saved sessions.
Enabling persistence after activity also captures the existing in-memory log.
It subscribes before other plugins mount, ignores replayed entries, and appends
each new entry unchanged. Close unsubscribes and releases the store. Failed
startup also closes partially opened resources. Starting an existing session ID
fails; callers must resume it instead.

`SessionStore` uses `tina_sqlite`. Parent and child sessions can share one file:
entries name their session, and listings fold metadata updates into one result
per session. The format is separate from legacy tina sessions.

## Plugin state compatibility

New state events use a namespaced, versioned `plugin_state` envelope. Plans,
goals, workflows and permission modes own their payload schemas. Existing SQLite
rows are normalized when read without rewriting them; unknown plugin payloads
are preserved while their owner is disabled.

Older binaries cannot read new `plugin_state` events. To downgrade after writing
new sessions, restore a pre-upgrade database backup or use a separate store.

Session metadata records the selected provider/model at creation and whenever
it changes. Resume restores this selection before opening a provider. A launch
override replaces it and is persisted for later resumes. Older metadata without
a model falls back to the configured default.
