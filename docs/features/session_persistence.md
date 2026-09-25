# Session persistence and cancellation

`JsonlSessionStore` is the shipped session backend, but the persistence
contract is backend-neutral: it is defined by the `SessionStore` interface
(`packages/tina_engine/lib/src/persistence/session_store.dart`) and proven
by a shared contract suite
(`packages/tina_engine/test/persistence/session_store_contract_test.dart`)
that runs the same groups and expectations against the JSONL store and a
non-file in-memory backend (SP5's acceptance criterion).

Selection of the backend is configuration, not code identity: the `[sessions]`
table in `~/.tina/config` names the provider —

```toml
[sessions]
provider = "jsonl"        # default; the only shipped backend

[sessions.jsonl]
# root = "/custom/path"   # optional; defaults to ~/.tina/sessions/
```

An unknown provider id fails at startup (exit 64) before any session is
created, never mid-session. The resume picker, `--resume`'s cwd restore, and
`--list` resolve the same selection through a read-only `SessionIndex`, so
startup reads and the runtime always see one backend.

Advisory locking is a store capability, not a backend type test: a store
implements `LockableSessionStore` (`lockNamespaceFor`) to declare that
cross-process session locks apply; the JSONL store's namespace is its session
directory. A backend without the capability skips locking, exactly as
non-file backends always have. `--force` still takes a held lock.

`tina --resume` lists saved sessions, most recent first, and asks for a session
number. Each entry includes its title, update time, message count, ID and project
directory. Enter or `q` cancels; an empty list exits without starting a session.
Selection happens before project trust and agent initialization, so the resumed
session uses its saved directory and the usual session lock.

`tina --resume <id>` resumes directly. `tina --continue` resumes the latest session
for the current directory, and `tina --list` prints saved sessions and exits.
The startup picker requires a terminal; scripts and `--prompt`/`--workflow` runs
must supply an explicit ID. Inside Tina, `/sessions` or Alt+S opens the TUI picker.

Interactive conversations and delegated agent sessions save progress during a
turn. The user prompt, assistant completions, reasoning records, and each
completed tool result are written before the next tool or approval starts.
Cancelling a turn preserves this history and records a cancellation marker;
it cannot undo filesystem or external effects of completed tools.

`TurnExecutor` supplies per-run history observers through `AgentDriver.run`.
Replacement drivers must await `onHistoryAppend` for progress and
`onHistoryReplace` for compaction. The default adapter temporarily composes these
with any construction-time observers and restores them when the run finishes.
The scheduler uses the same callbacks for delegated sessions. A final snapshot
reconciles status messages and drivers that did not publish incremental progress.

Tool batches use one result message in memory. The JSONL journal appends each
result separately, allowing earlier results to survive a crash while another
call waits. Loading coalesces adjacent result records back into a single batch.
Before sending a resumed conversation to a provider, missing tool results are
marked as having unknown execution status. The agent must check their effects
before retrying; a missing result is not proof that a command did not run.

`JsonlSessionStore` serializes writes per session, including manifest updates,
appends, and replacements. This prevents concurrent writers from overwriting
metadata or racing over shared temporary files. Failed writes reach the caller
without poisoning the queue. Lazy recorder initialization is shared by concurrent
first writes. Session locks remain responsible for excluding other processes.

Conversation manifests carry two opaque app-owned blobs per conversation,
`goal` and `plan`, so `/goal` and `/plan` survive `/resume` and restarts. The
engine stores them without parsing (like `policy`); the app layer reads and
writes them through `updateConversationTrackers` (both fields, null clears)
and restores them through `TrackerPersistence.hydrate*`, which treats the
manifest as authoritative and never echoes a read back to disk. The contract —
paired writes, null clears one field, round-trip through the manifest JSON —
is pinned in the shared `session_store_contract_test.dart` suite for every
backend.

Approval prompts carry their turn's cancellation signal. Cancelling or shutting
down releases approval waits and keyboard ownership, including prompts waiting
behind another modal or an unfinished draft. A late approval cannot execute a
command or create a permission grant for a stopped turn.

Regression coverage uses real temporary files and a fresh store to read results
while a later approval is still pending, then exercises cancellation, shutdown,
late responses, recovery of incomplete tool batches, and overlapping writes.
