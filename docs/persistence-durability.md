# Session persistence and startup

Session persistence uses WAL with `synchronous=FULL` explicitly set on every
connection. File-backed stores refuse to open if SQLite does not enter WAL
mode. In-memory test stores use SQLite's `memory` journal mode.

An append returns after its transaction commits. A failed transaction rolls
back the whole batch and database failures poison the connection. The
persistence plugin also remembers serialization/save failures: later turns
cannot skip the missing entries and continue as if they were saved.

The database schema, entry JSON and session-local sequence numbers are
unchanged. Existing stores need no migration.

## Ownership

- `AgentLoop` owns the in-memory event log, sequence numbers and generic
  synchronous notifications. It works without a persistence plugin.
- `PersistencePlugin` owns restoration, registration, metadata, its store
  connection, subscription and shutdown.
- `SessionStore` maps session metadata and entries into the shared log table.
- `TinaEntryLog` owns generic append transactions, with no session knowledge.

Settings restoration before plugin construction and persistence restoration
still read independently. There is no shared cross-plugin session loader.

## Commit boundaries

| Boundary | One FULL transaction contains |
| --- | --- |
| Start a turn, before any preparation/input hooks | `TurnStarted`, raw `InputRecorded`, plus registration if this is a new session |
| After input preparation, before a provider request | Processed user `MessageAppended` |
| Input rewrites or other plugin state | Each synchronous append at its existing boundary |
| Before executing tools | Assistant message containing the tool requests |
| After each tool | Its result, before the next tool or provider call |
| Complete an ordinary assistant response | Final assistant message and `TurnEnded` together |

No transaction spans a model request, tool execution or arbitrary async hook.
Completion is committed before end hooks and before returning an outcome.
Streamed text remains provisional until the final append succeeds. On write
failure the in-memory log can contain entries absent from disk; the failure is
surfaced, and that persistence plugin refuses further saves.

For an ordinary first turn, data commits before the first provider call fall
from four to two. A resumed turn falls from three to two. These counts exclude
schema creation, mounting activity and additional entries produced by plugins.

Enabling persistence after in-memory activity saves registration and all
existing history in one transaction. Subscription replay never re-appends
those entries. Registration is marked saved only after COMMIT succeeds.

## Listener contract

`subscribeBatches` receives an immutable list with consecutive sequence
numbers; the entire batch is already visible in `loop.log`. Existing entries
arrive as one replay batch. Empty logs produce no replay callback.

Batch subscribers run before per-entry observers. `subscribe` retains ordered
per-entry delivery through an adapter. Each subscriber queues deliveries, so a
re-entrant append drains its older pending entries before newer ones. This can
re-enter the same callback. Subscribing during notification replays a snapshot;
it does not duplicate the batch already being delivered. Unsubscribing drops
pending callbacks for that subscription.

Callbacks finish synchronously and propagate failures. They must not start an
unawaited save and return. Catching an error from a nested append does not hide
it from the enclosing append. A failed replay removes its subscription.

## Reproducing measurements and recovery checks

```sh
(cd apps/tina_cli && dart pub get && dart build cli -t tool/perf/startup_stages.dart -o build/perf/stages)
python3 apps/tina_cli/tool/startup_bench.py --dart /path/to/dart --runs 5
(cd packages/tina_sqlite && dart pub get && mkdir -p build/perf && dart run tool/perf/sqlite_batches.dart bench build/perf/transactions.db)
python3 packages/tina_sqlite/tool/sqlite_recovery_test.py --dart /path/to/dart
```

The startup driver owns a localhost HTTP stub and isolates HOME, workspace,
configuration and store. It calls the real `runCli` and assembly path without
extra configuration loads or store opens. Resume samples each copy the same
closed seed database; history does not grow between samples. JIT and AOT
results are separate. AOT uses `dart build cli` to include native assets.

Parent monotonic timestamps start before process creation and end when stage
markers arrive through a pipe. They include runtime/JIT launch and pipe
delivery latency. Child monotonic timestamps measure the actual stage work,
including the settings replay read. The first stream event and first nonempty
text delta have separate markers. Headless stdout otherwise prints only after
the turn, so it is not used as a first-token measurement.

The small isolated benchmark counts transaction-ending WAL frames at ready and
at the first provider call, excluding schema/startup commits. This diagnostic
assumes no checkpoint/reset between those observations and is not a production
WAL reader. The heartbeat reports the largest event-loop gap from `main`
through completion, including synchronous assembly work. Filesystem caches are
warm; this is not a cold-disk benchmark. Run comparisons without other builds
or writers competing for the same storage.

Recovery checks compile a disposable writer once, kill its process group
before COMMIT and after the append acknowledgement, then verify atomic recovery
and `integrity_check`. Two concurrent writer processes also verify attribution
and sequence order. These tests cover process crashes, not an OS crash or power
loss. FULL retains SQLite's sync contract and its dependence on the filesystem
and hardware; this change does not enable macOS `fullfsync`.

The implementation remains synchronous. An isolate would require ordered,
awaitable acknowledgements and explicit failure/drain handling within the
persistence plugin. It can reduce UI blocking but cannot remove the need to
wait for a durable commit. It should be evaluated separately with representative
large histories and slower storage.

## Local measurements, 2026-10-11

On this macOS arm64 workspace filesystem, using SQLite 3.53.4 and the local
stub, these are median milliseconds from the parent process clock. The
baseline uses the original individual FULL transactions. Both versions include
the same pre-existing workspace changes and startup instrumentation. JIT has
three samples per mode/version; AOT has five baseline and three final samples.

| Launch | Ready, before → after | First text, before → after | Pre-request data commits |
| --- | --- | --- | --- |
| JIT fresh | 4055.8 → 3706.6 | 4190.6 → 3816.5 | 4 → 2 |
| JIT resume | 3911.5 → 3871.1 | 3990.4 → 3945.1 | 3 → 2 |
| AOT fresh | 42.5 → 44.5 | 67.1 → 56.7 | 4 → 2 |
| AOT resume | 36.1 → 34.9 | 55.0 → 49.5 | 3 → 2 |

These small samples on a shared development machine are descriptive, not a
performance threshold. The JIT runs remain dominated by launch/compilation and
their timing variation cannot be attributed solely to batching. Assembly
readiness is largely unchanged for AOT, as expected: batching reduces writes
after the assembly is ready. Median maximum heartbeat gaps for AOT fell from
44.7 to 34.9 ms fresh and 32.4 to 28.9 ms on resume; these include assembly and
do not isolate fsync time.

The focused transaction probe alternated 100 samples of each mode on one FULL
WAL connection. Four individual commits took 19.28 ms median; the equivalent
two commits took 8.68 ms. Worst samples still varied substantially (52.35 and
61.01 ms). No durability setting was relaxed to obtain these results.

Validation: 421 tests across the supported engine, storage, provider and related
plugin suites passed, as did architecture checks, the crash/concurrent-writer
checks and both full CLI PTY smoke tests. The final listener failure refinement
also passed all 127 engine/persistence tests, and the final rollback refinement
passed all 33 SQLite tests. Analysis of changed Dart code is clean. The TUI unit
suite has 344 passes and four existing approval-panel failures; all four were
reproduced using the original engine, persistence and SQLite code in an isolated
copy. The deferred workflows package is outside the root dependency graph and
was excluded from the supported-package run.
