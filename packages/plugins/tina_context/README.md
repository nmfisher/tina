# Agent-managed working context

This package implements persisted working context for tina. The app registers
it as the experimental `tina/context` plugin, disabled by default. Enable it
in Settings → Plugins or set a workspace/global plugin override, then restart:

```toml
[plugins.overrides]
"tina/context" = true
```

The app allocates a separate temporary `live.json` for each primary conversation
and grants dedicated file tools writes to that exact file. The prompt identifies
the path. Session mirrors are deleted on close and regenerated from the log on
resume. `.tina` remains protected. Automatic compaction and `/compact` are paused
while this plugin is actually loaded, including when disablement is pending
restart. Child agents retain their existing plugin set.

The append-only session log remains the audit trail. Accepted replacements
are `tina/context` / `working_context` plugin-state snapshots in that same log.
The model receives the latest eligible replacement plus later messages.
`AgentLoop.derive()` continues to return its existing conversation view.

## Use

Add a fresh `ContextPlugin` to a session's plugin list and mount it through the
normal plugin lifecycle. To replace context:

```dart
final current = contextPlugin.workingContext;
contextPlugin.replaceWorkingContext(
  expectedRevision: current.revision,
  expectedThroughSeq: current.throughSeq,
  messages: replacementMessages,
);
```

Both counters must match. The revision detects another accepted edit; the log
watermark also detects intervening conversation activity. Messages and nested
payloads are detached and frozen. Replacement validation rejects malformed
tool exchanges and changes to retained signed reasoning. The current user
request must remain unchanged. Edits during an executing tool batch are
rejected until its results have been recorded. Settled exchanges, including
those within the active turn, may be removed or rewritten.

The package supplies no editing tools or budget policy. It never executes
tools as part of reconstruction. Applications must mount a
persistence plugin if context must survive process exit; without one, the log
and snapshots exist only in memory.

## Optional editable file

Pass an explicit, session-specific file to enable the mirror:

```dart
final contextPlugin = ContextPlugin(
  mirrorFile: File('/path/to/context/<session-id>/live.json'),
);
```

This requires `dart:io`. Without `mirrorFile`, the plugin creates no files and
adds no prompt instructions or edit receipts. Supplying a path opts into
overwriting that file on mount with the restored working context. Use one
mirror path per session and permit existing file tools to access it through
their normal sandbox policy.

Embedders can instead use `ContextPlugin.sessionMirror(onMirrorReady: ...)`
to allocate the same temporary editing surface used by the app. The callback
runs after creation and initialization, allowing the embedding to grant access
through its file-tool policy. The plugin itself has no tools dependency.

The file contains `schema_version`, `revision`, `through_seq`, and `messages`.
Edit only `messages`. Before each model call, the plugin reads edits, validates
them, and submits a replacement through the persisted state API. Messages
recorded since the previous export are appended to the edited base, preserving
results from the very command that edited the file. A concurrent replacement
or context reset rejects the edit instead of rebasing it.

Accepted edits receive a short synthetic receipt in the next model request.
Invalid JSON, changed counters, stale edits, and attempts to remove the
current task receive a rejection receipt; the current context is restored to
the file. Receipts are transient and are not added to the session transcript.
The plugin also contributes a prompt section identifying the file and format.

Each export writes a temporary file beside the mirror, flushes it, and renames
it over the destination. The log is authoritative; leftover file edits are
discarded on restart. File synchronization happens at model-call boundaries,
so the final model reply enters the log before it appears in a later export.
Allow file editing only through completed tool operations; concurrent external
writers are not coordinated by this experiment.

## Recovery and integration constraints

- Snapshots accepted during completed turns survive restart, including turns
  that ended with cancellation or error.
- Snapshots from unfinished turns are ignored on resume. During execution,
  only the latest open turn is considered live. Later edits use monotonically
  increasing revisions even when an unfinished snapshot was discarded.
- A context clear invalidates all older snapshots.
- Existing compaction can bootstrap the initial context. Compaction after a
  working-context edit fails explicitly because its indexes address a
  different message list. Do not enable automatic compaction alongside this
  plugin; a future integration must coordinate the two policies.
- A failed snapshot write blocks subsequent model calls through this plugin.
  Restart is required to reconstruct from the actually persisted log.
- A file-publish failure also prevents that model request. A persisted edit
  can still be recovered after restart if the subsequent file export failed.
- Mounting validates restored state. Unsupported versions or corrupt
  snapshots fail rather than silently reverting to full history.
- The hook runs at order 800. Later request transforms may still redact or
  otherwise change the outgoing request according to their own policy.

Snapshots copy the full edited context only when replacements are accepted.
Normal message appends are replayed from the log. The original conversation
and previous snapshots remain stored, so this reduces model input rather than
database size.

## Optional visualizer

Enable the separate `tina/context-tui` plugin alongside `tina/context`, then use
`/context`. The read-only panel shows accepted messages, revision, a token
estimate, pending file status and latest accepted changes. It never applies
file edits. See the [viewer](../tina_context_tui/README.md) for controls and limits.

Embedders can inspect `workingContext`, `latestChange`, `fileStatus` and
`lastEditReceipt` without console dependencies. The latest comparison is
replayed from eligible snapshots; file receipts remain transient.

## Verify

From this directory:

```sh
dart pub get
dart analyze
dart test
```

Tests include actual SQLite close/reopen, file edits across tool calls,
abandoned-turn recovery, stale cursors, immutable payloads, malformed files,
protected requests, and failed writes preventing provider requests.
