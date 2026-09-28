# tina_persistence

`PersistencePlugin` (`tina/persistence`) owns the session store, log subscription,
session metadata updates and resume. The application assembly injects a
`SessionStoreOpener`; the host knows only the generic plugin lifecycle.

On open, the plugin creates a session or restores and validates its saved log.
It subscribes before other plugins mount, ignores replayed entries, and appends
each new entry unchanged. Close unsubscribes and releases the store. Failed
startup also closes partially opened resources. Starting an existing session ID
fails; callers must resume it instead.

`SessionStore` uses `tina_sqlite`. Parent and child sessions can share one file:
entries name their session, and listings fold metadata updates into one result
per session. The format is separate from legacy tina sessions.
