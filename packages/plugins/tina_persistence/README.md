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

## Agent history tools

The CLI supplies `SessionHistoryTools` to persistence, contributing
`search_sessions` and `read_session`. Search defaults to **only the current
workspace's store**, excludes the active session, and never broadens after an
empty result. Empty queries list recent sessions. Results always prioritize
latest activity (including resumed conversations), rather than relevance.
Search is a literal phrase match; ASCII case is ignored. `limit` and `offset`
page bounded snippets. Reads default to recent messages in conversation order;
`next_before_seq` pages backwards. Each message is capped at 6000 characters,
with an explicit `text_truncated` flag. Continue a long message by passing its
`seq` as `message_seq` and `next_text_offset` as `text_offset` to `read_session`.

`scope: global` searches known stores registered when Tina opens a workspace,
including custom `--store` locations. The catalog lives beside the global
config in `session-stores/`, one registration per workspace/store pair. It does
not scan the filesystem. Workspaces last used before this feature must be
opened again to become discoverable. Global results include an opaque
`store_id`; pass it to `read_session` to select that store. Omit it for the
current store. Ordering across stores uses latest commit timestamps.

All reads go through the shared mode policy. Workspace reads are free;
outside-workspace stores, including external custom stores and symlink targets,
require human approval in every ordinary mode. Approval shows the query or
session, workspace paths, and that saved conversation text enters the current
conversation. **Allow once** covers that call. **Remember** covers searches and
reads of exactly those histories for this conversation; new stores still ask.
No persistent or general file access grant is offered. Launch-time yolo follows
the same policy's existing bypass.

Workers use separate SQLite read-only connections without migrations or
journal-mode changes. Queries run outside the UI isolate and return only
user/assistant text and small metadata. Tool arguments/results, plugin state,
images and synthetic messages are excluded. Retrieved text is historical
evidence, not instructions. Unavailable global stores are counted explicitly
without hiding valid matches.

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
