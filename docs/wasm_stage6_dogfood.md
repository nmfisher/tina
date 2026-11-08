# Stage 6 — the front end, the suite, and the dogfood (engine-on-wasm program, final stage)

Stage 6 puts a client on top of the wasm engine, holds both engines
to the same agent-TURN scenario suite, fixes the flagged performance
numbers, and completes one real coding task end-to-end through the
wasm engine.

## What landed (tina, `asb/wasm-stage6-dogfood`)

### The front end: a `HostInterface` client over `--pipes`

The native TUI cannot drive the engine: it mounts an in-process
session (`SessionView` over `SessionConnection`), and the daemon that
would separate the two is an unimplemented proposal
(`docs/proposals/daemon_sessions.md`: "no daemon has been built"). The
accepted path per the program plan is a client that speaks the
in-process front-end contract — the pipes protocol IS that contract,
serialized ("the thinnest serialization of the in-process front-end
contract (`SessionConnection`, `SessionAttachment`").

`tool/front_end.dart` is that client, and it is thin: it spawns an
engine command (native `tina --pipes` or the wasm engine under the case
runner), speaks exactly the engine's ops (`submit`, `cancel`,
`approve`, `status`, `shutdown` — no client-side command language),
renders a human transcript (turns, tool calls and results, approval
asks and answers), records the raw event stream, and can play a
scenario file (sends, waits, expectations) for the suite. Ids a script
cannot know ahead of time (the approval id, the active work id) are
bound from waited-for events (`$approval`, `$work`).

### Approvals answerable over pipes

- `pipes.dart` now bridges the `tina/approvals-stream` channel: every
  `ApprovalRequest` the channel delivers is emitted as an
  `approval` event, and a new `approve` op answers it
  (`allow` / `always` / `deny`; the reply reports whether a pending
  request accepted it). Without this subscription the stream channel
  auto-denies every delivery — asks were previously unanswerable on a
  headless engine (stage 5 ran yolo only).
- The wasm engine boots in ask mode when the host sets
  `TINA_ENGINE_YOLO=0`; the native engine runs ask mode by omitting
  `--yolo` (`--pipes` already selects the stream channel natively).

### The portable asking boundary (`tina_tools`)

`SandboxedFileSystem` is `dart:io`-bound (symlink canonicalization at
its core), so the wasm tools slice had no permission boundary. Stage 6
adds `AskingBoundary` (`src/asking_boundary.dart`, no `dart:io`): the
same decision route — protected paths, the one total policy table
(`resolveAuthorization`), `operationReason`'s reason strings, session
grants, once-per-operation authorization scopes that absorb atomic
write staging — with WASI-shaped paths (containment by preopen
attribution, no symlink walk; preopen confinement already refuses `..`
and outside-preopen paths).

Supporting extraction, no behavior change natively:

- `SandboxViolation` moved to its own portable file (re-exported).
- `ToolBoundary`: the boundary interface `ToolFileSystem` consults
  (`SandboxedFileSystem implements ToolBoundary`; `ToolFileSystem.of`
  engages either boundary). The tools' front door is unchanged.
- `portable_tools.dart` also exports the permission vocabulary
  (`Approval`, `Approver`, `FileOp`, `FileGrants`, `decideOperation`,
  `operationReason`).

The wasm `tina/tools` plugin now routes its boundary's asks through the
mode policy (`modePolicy.request`), like the native plugin's
`attachModePolicy` wiring: the same policy table, precedent store and
approval channel answer; the `tina/approvals` coordinator joined the
wasm registry.

### Persistence under wasm (resume in the preopen)

- `tina_persistence/session_store_api.dart`: the store contract
  (`SessionStoreApi`), the shared value types (`StoredSession`,
  `StoreGap`, `SessionStoreException`), `restoreSessionSettingsFromLog`
  (the plugin's settings replay, extracted) and
  `decodePersistedEntry` — one pure-Dart library whose import graph is
  `tina_core` + `tina_settings`. The sqlite `SessionStore` implements
  the interface; `SessionStoreOpener` now names it.
- The app-layer persistence seam became injectable
  (`injectedPersistenceWiring`): a composition root supplies
  open/replay/model lookups; the native sqlite path is the default.
- `tina_wasm`'s `WasiSessionStore`: the same contract over one JSON
  Lines file in a preopen (load at boot, in-memory during the session,
  flush at shutdown — the same place stdout drains). Marker/entry/
  details lines; file order is the truth; `seq` runs checked on read.
- `WasmPersistencePlugin`: the sqlite plugin's lifecycle over the WASI
  store (register with the first batch, append every committed batch,
  revise details, seed a resume with its log, details and model).
- The engine selects this when the host sets `TINA_ENGINE_STORE`
  (a guest path); `TINA_ENGINE_RESUME` resumes a stored session id.
  The config must enable `tina/persistence` (the baseline list joins
  only when a store loaded — the plugin baseline is validated against
  the registry).
- `bin/native_resume_probe.dart`: the CLI's argument gate reserves
  `--resume` for the terminal ("--pipes cannot be combined with
  --resume"); the assembly itself resumes headlessly, and this probe is
  exactly that assembly over pipes — the native reference for the
  persist+resume scenario.

### The scenario suite (`tool/scenario_suite.sh`)

Agent-TURN scenarios, each run against BOTH engines with the same
client and scripted provider (`tool/fake_provider.py`), transcripts
recorded raw, normalized (`tool/normalize.py`), and compared:

| scenario | native | wasm | normalized comparison |
|---|---|---|---|
| multi_turn (context carried across turns) | PASS | PASS | IDENTICAL |
| tool_error (mid-turn error + recovery) | PASS | PASS | IDENTICAL |
| approval_grant | PASS | PASS | IDENTICAL |
| approval_deny | PASS | PASS | IDENTICAL |
| cancel_mid_turn | PASS | PASS | IDENTICAL |
| persist_a (session persisted in the preopen) | PASS | PASS | IDENTICAL |
| persist_b (resumed session, context re-carried) | PASS | PASS | IDENTICAL |

The normalizer erases only volatile identity (session/epoch/turn/work/
approval ids, timestamps, the native engine's absolute workspace
prefix, the runner's own brackets, an internal token estimate); entry
shapes, order, tool calls and results, approvals and answers compare
byte-for-byte. Recorded: `tool/records/scenario_results.txt`, raw
transcripts in the suite's artifacts directory.

## The exit test (recorded)

A real coding task completed through the wasm engine, driven from the
front-end client (`tool/records/dogfood_*.transcript`): the engine —
in ask-mode-free yolo over `--pipes`, session persisted in the
workspace preopen — read a real Dart package, added
`greatestCommonDivisor` to `lib/math_utils.dart`, wrote a test file
whose expectation was deliberately wrong, received the REAL host-side
`dart test` failure ("Expected: <5> Actual: <4>") as feedback in a
resumed session, diagnosed itself ("My expectation was wrong — gcd(12,
8) is 4, not 5"), fixed the test, and summarized after the host's
second run passed. The tool-call breaker stopping the unchanged retry
mid-fix is visible in the phase-B transcript. Final state:
`00:00 +2: All tests passed!` (`tool/records/dogfood_test_runs.txt`).

## Performance (the flagged numbers, before → after)

- Spawned-runner startup to a booted engine: **75.4 s → ~4.4 s.** The
  dominant cost was the DEBUG-build runner: cranelift in a debug
  binary compiling the 1.82 MB component dominates (83-84 s to full
  exit, boot to shutdown). A release build of the same runner
  (`cargo build --release -p test_runner`) boots the same component in
  4.3-5.1 s, spawned or direct. Cheap, safe, no code change — the fix
  is the build profile.
- Peak RSS: **363 MiB → ~352 MiB** (sampled VmHWM, boot + shutdown).
  Attribution: the 1.1 MB stage-3 probe under the same release runner
  peaks at ~251 MiB — the dart2wasm embedder runtime and instance
  metadata dominate; the engine's larger code and heap add ~100 MiB.
  Not cheaply reducible from the runner; recorded as the embedder's
  floor (see wasm.dart `pkg/test_runner/docs/stage6_dogfood.md`).
- Component rebuild: unchanged (7-23 s warm; dart2wasm dominates).

## Deviations and open unknowns

- The fake provider drives the "model" (no credentials exist in this
  program); the engine's work is real — real files, real session, real
  protocol, real host-side test runs.
- The wasm engine's reads/writes of the config tree are still the
  preloaded snapshot (runtime writes memory-only); the session store
  is the one runtime-persisted file.
- One intermittent event drop was observed once during suite
  development (an `entry` line lost on stdout under load, never
  reproduced after the UTF-8 emit fix); the stage-4/5 stream fixes
  cover the known causes. If it recurs, suspect the guest stream
  close path again.
- An operator error during stage 6: a broad `kill` on `python3`
  processes terminated one stale pre-session server (no observed
  impact); suite scripts now kill only pids they recorded.
- The suite's native persist+resume uses the resume probe (the CLI's
  `--pipes` gate); if the CLI ever allows headless resume, the probe
  retires.
- Local development still needs the `hooks` override (uncommitted
  `pubspec_overrides.yaml`) and the pinned 3.14-edge SDK for compiles;
  the box's stable 3.13 SDK runs the native engine and its tests.
