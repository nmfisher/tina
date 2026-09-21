# Session persistence and cancellation

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

Approval prompts carry their turn's cancellation signal. Cancelling or shutting
down releases approval waits and keyboard ownership, including prompts waiting
behind another modal or an unfinished draft. A late approval cannot execute a
command or create a permission grant for a stopped turn.

Regression coverage uses real temporary files and a fresh store to read results
while a later approval is still pending, then exercises cancellation, shutdown,
late responses, recovery of incomplete tool batches, and overlapping writes.
