# Sweep task corpus

The fixed set of tasks the sweep session gives to tina, against
`examples/workspace/`. Lives in `tool/` — NOT inside the fixture — so
the agent under test can't read its own task sheet.

Each task: the prompt to type into tina, what tina machinery it
exercises, and the observable outcome to check. Reference tasks in
tickets as `T<n>` (e.g. "repro: T6 at 80×24 with stub stream #2").
Combine freely with the geometry sweep and scenario seeds.

| ID | Prompt (typed into tina) | Exercises | Expected observable outcome |
|----|---------------------------|-----------|------------------------------|
| T1 | What does EventBus.publish do when a subscriber publishes during dispatch? | search tool, index traversal, read | correct answer (queued, dispatched after current batch); citations land on event_bus.dart |
| T2 | List every class that implements Repository and where each lives. | graph extends/implements edges, multi-file render | MemoryRepository + JsonFileStore with paths |
| T3 | Rename StoreErrors.corrupt to StoreErrors.corrupted everywhere. | edit tool, permission prompt, multi-file edits | ≥2 files touched (repository.dart, json_file_store.dart); diff preview renders |
| T4 | Add a count command to the track CLI that prints the number of events in the store. | write tool, multi-step plan, new file | new file under packages/cli; report.dart-style wiring; agent explains what it changed |
| T5 | Run git status in the workspace and summarize the changes. | bash tool, permission gate, output streaming | permission prompt for bash; summary matches `tool/example_workspace.sh dirty` state if applied |
| T6 | Read packages/core/lib/src/naive_cache.dart and summarize its eviction policy. | CJK/emoji render, read | wide chars render correctly; answer: lazy TTL eviction on read, no LRU |
| T7 | Why does broken_probe.dart fail to parse, and does the index still work despite it? | parser robustness, partial results | agent reports the syntax errors AND that other symbols (e.g. NaiveCache) are still indexed |
| T8 | Trace everything that happens when `track add` runs, file by file. | multi-file read chain, long tool output | chain track.dart → add.dart → store → core rendered readably; scrollback intact |
| T9 | Change Repository.fetch to also return the entity as JSON. | interface refactor, cross-package blast radius | agent surfaces the implementors it must touch before editing; asks/approves edits |
| T10 | Parse data/samples.ndjson and tell me how many tasks are currently open. | bash/read on ndjson, unicode titles | correct fold (newest event per task; TaskCompleted not last = open); unicode title renders |
| T11 | Show me data/long_line.txt. | truncation of huge tool output | no layout breakage; sensible truncation indicator |
| T12 | Remove NaiveCache from core and fix everything that breaks. | deletion refactor, barrel export awareness | agent notices core.dart re-exports it; removes export + file |
| T13 | Summarize each package under packages/ in one line each. | regions / fleet fan-out, spend metering | per-region agents spawn; metering shows concurrent activity; summaries arrive |
| T14 | (scenario) Start T3, kill tina mid-edit (kill -9), restart with --resume, ask it to continue. | session persistence, crash recovery | history restored; agent knows what was already done |
| T15 | Add a note to ~/notes.txt (outside the workspace). | permission scoping | edit outside cwd gated by approval, not silently allowed |

Rules for using the corpus:

- Run every task at least once per sweep batch, across at least two
  geometries; T6/T7/T10/T11 are the highest-yield for render bugs.
- Tasks are inputs, not scripts — vary phrasing slightly between runs
  where it doesn't change the expected outcome.
- If a task's expected outcome is wrong (fixture changed), fix this
  file in the same commit as the fixture change.

## Snapshot-based verification

`tool/example_workspace.sh snapshot <name>` / `restore <name>` /
`snapshots` capture and replay arbitrary workspace states (including
untracked files and half-finished agent edits) as tarballs under
`build/workspace-snapshots/` (gitignored). Verification workflow for a
UI bug that involves agent-modified state:

1. While the failing state exists: `tool/example_workspace.sh snapshot
   <ticket-id>` (snapshot BEFORE fixing anything).
2. Reproduce, fix, close per the normal criteria.
3. `restore <ticket-id>` and replay the same task + geometry to confirm
   the fix holds against the original mess, not just a clean run.
4. `tool/example_workspace.sh reset` before the next scenario.

Keep a `pristine` snapshot at all times (retake it after any fixture
change) so a clean baseline is one restore away even if `reset`'s git
path can't run.

With the stub provider the agent's actions are deterministic, so a
snapshot + the same stub script is a fully replayable repro.
