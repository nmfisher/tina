# Timer system — design spec (task #33)

Status: SPEC FOR OWNER REVIEW — docs only, nothing implemented. Expands the
2026-09-05 chat proposal to implementation depth at the owner's request
("review a detailed spec BEFORE implementation"). Owner ask that created
the feature: "a timer tool and timer system inside tina... the agent within
tina should be able to invoke a timer tool; the user instructs the agent to
set a timer, e.g. every hour check this, or every five minutes check this.
Tina needs an event loop and timer system that executes these scheduled
checks within the tina runtime."

Every code anchor below was verified against main @ 03c0f45. Texts marked
**VERBATIM** are normative — the implementation legs copy them exactly
(round-13 lesson: a leg once substituted its own steering text, silently).

## 1. The feature

The agent can set, list, and cancel named timers. Each timer carries an
interval and a self-contained check instruction. While tina runs, the
runtime fires each timer on its schedule and executes the check as a REAL
agent turn — the same model, tools, permissions, budgets, persistence, and
display as a typed turn — for as long as the process lives. The operator
can inspect and cancel timers without going through the agent.

## 2. Decisions of record

The six proposal decisions, adopted by recommendation and standing as the
design of record unless the owner vetoes in spec review:

| #  | Decision | Design of record |
|----|----------|------------------|
| 1  | Tool surface | Three thin tools: `set_timer`, `cancel_timer`, `list_timers` |
| 2  | Interval format | Human string ("90s", "5m", "1h30m"), parsed + clamped by the tool |
| 3  | Schedule | Fixed grid anchored at fire time, with busy-collapse |
| 4  | Operator command | `/timers` (list / show / cancel) |
| 5  | Runaway guard | Suspend after 6 consecutive aborted fire-turns |
| 6  | Scope | Runtime-scoped, no persistence (v1) |

New sub-decisions surfaced by this spec (each with a recommendation; the
owner can veto any of them cheaply in review):

| # | Sub-decision | Recommendation |
|---|--------------|----------------|
| a | Service ownership | ONE TimerService owned by the SessionController (runtime-wide), firing into the ACTIVE conversation — not one service per Conversation. Timers survive `/session switch`; their instructions are required to be self-contained precisely so this is safe. A fire when no conversation is active is skipped with a dim notice. |
| b | Fire attribution | The controller keeps an exact-prompt → timer-name map (`_pendingTimerFireByPrompt`) and consults it at turn start. No MessageQueue schema change; an operator cannot spoof membership (map lookup, not string sniffing). The prompt carries a fire number (`#<n>`) so a typed collision is effectively impossible. |
| c | What counts as a "failed" fire for the guard | Any fire-turn that ends with `cancel.isCompleted || agent.abortedReason != null` — ESC-cancel included. Rationale: six deliberate operator kills of the same check is a stop signal; the un-suspend path is trivial (re-set). A clean end (including a #31 tool interrupt) resets the counter. |
| d | In-flight fire turn vs `/timers cancel` | `/timers cancel` removes the SCHEDULE only; an already-running fire turn finishes like any turn (the operator can ESC it like any turn). |
| e | Where fire turns land | Main conversation history, via the normal turn path (workflow-injection precedent) — persisted, compacted, displayed like any exchange. |
| f | #31 interrupt gesture with only timer fires queued | No change. The gesture fires on "running + queue non-empty"; draining into a timer fire afterward is correct (interrupt is not a cancel, nothing is destroyed). Reviewed, deliberately untouched. |

## 3. Verified anchors (main @ 03c0f45)

- `Agent.run` already takes `cancelSignal` and `toolInterruptSignal`
  (packages/tina_engine/lib/src/agent/agent.dart:445-446); `abortedReason`
  is `String?` (agent.dart:383, reset :469); `AbortedKind { none, provider,
  transport, budget, steps, cancel }` (:190).
- Turn lifecycle, lib/session_controller.dart: submit → enqueue-or-start
  (:419-438); `_startTurn` (:552) arms fresh cancel/toolInterrupt
  completers (:575, :581); `agent.run` call (:641-645); abort persistence
  (:672-678); cancel rollback drops the exchange but NOT the queue (#31,
  :682-700); ownership-guarded teardown + queue drain (:717-736,
  `dequeue` :724, drain `_startTurn(s, next)` :736).
- Background-injection precedent — workflow completion:
  session_controller.dart:763-778 (`_workflowOutcomePrompt` →
  `isRunning ? enqueue : _startTurn`). A timer fire is the same shape.
- Composition: `Agent buildAgent({...})` lib/composition/agent_composition.dart:59;
  base tools at :114 (`buildTools(safeMode: config.safeMode).all`, engine
  buildTools at packages/tina_engine/lib/src/agent/agent_pipeline.dart:250).
- Commands: registry entries `_kSessionCommandEntries`
  (lib/session_commands/session_command_registry.dart:67); handler dispatch
  (lib/session_commands/session_command_handlers.dart:23, :71); output via
  `ctx.active.host.showMessage(text, style: HostMessageStyle.*)`;
  `CmdResult` variants incl. `CmdHandled` (command_context.dart:29-44);
  `CommandContext` is the handler-facing interface (fakes implement it).
- Conversation state (lib/conversation.dart): `messageQueue` :33,
  `cancelCompleter` :37, `toolInterruptCompleter` :46, `isRunning` :49-50.
- `NoticeKind { info, warning, error }` (agent_sink.dart:13) — but timer
  notices fire OUTSIDE turns, so the operator channel is
  `host.showMessage`, not the agent sink.
- Bare `Timer` precedent: bin/tina.dart:583 (watchdog grace);
  lib/host/headless_watchdog.dart. No scheduler exists anywhere today.
- TUI bootstrap (where the service gets constructed):
  lib/tui_coordinator.dart:857 (`SessionController(`).

## 4. TimerService (engine — new packages/tina_engine/lib/src/timers/)

### 4.1 Shape

```dart
typedef TimerFactory = Timer Function(Duration duration, void Function() callback);
typedef TimerFireCallback = void Function(String name, int fireNumber);
typedef TimerNoticeCallback = void Function(String text, {required bool warning});

class TimerSpec {
  final String name;        // validated by the tool layer, trusted here
  final Duration interval;  // already clamped by the tool layer
  final String instruction;
  final bool once;          // sugar for maxFires == 1; mutually exclusive
  final int? maxFires;      // null = unlimited (recurring)
}

enum TimerEntryState { idle, queued, running }

class TimerSnapshot {          // what list()/list_timers expose
  final String name; final Duration interval; final String instruction;
  final int fireCount; final bool once; final int? maxFires;
  final bool suspended; final int consecutiveAbortedFires;
  final TimerEntryState state; final DateTime? nextFireAt;
}

enum TimerSetOutcome { created, replaced, rejected(String reason) }

class TimerService {
  TimerService({
    required TimerFireCallback onFire,       // app wires the controller seam
    required TimerNoticeCallback onNotice,   // app wires host.showMessage
    TimerFactory? timerFactory,              // default: Dart Timer; tests fake it
    DateTime Function()? clock,              // default: DateTime.now; tests fake it
  });
  TimerSetOutcome set(TimerSpec spec);       // same name REPLACES (idempotent)
  bool cancel(String name);                  // false = unknown name
  List<TimerSnapshot> list();
  void ackStarted(String name);              // queued → running (no-op otherwise)
  void ackFinished(String name, {required bool aborted});  // running → idle
  void dispose();                            // cancels every armed Dart Timer
}
```

The tools (§6) translate outcomes into `ToolResult` text; the service never
builds tool text itself. Constants live engine-side, named (repo precedent:
`_consecutiveAnomalyNoticeThreshold`):

```dart
const int kMaxActiveTimers = 8;
const Duration kMinTimerInterval = Duration(seconds: 30);
const Duration kMaxTimerInterval = Duration(hours: 24);
const int kMaxTimerFiresBeforeSuspend = 6;
const int kMaxTimerInstructionChars = 2000;
```

### 4.2 Per-timer entry state

`name`, `interval`, `instruction`, `once`/`maxFires`, `fireCount`,
`consecutiveAbortedFires`, `suspended`, `state` (idle/queued/running),
`nextAnchor` (the grid position), and the currently armed Dart `Timer`.

### 4.3 The event loop

Dart's own event loop; no isolate, no thread. One armed `Timer` per active,
non-suspended timer. Fires execute as turns, and turns are already
serialized per conversation, so the service needs no locking — at most one
timer callback runs at a time, and it only mutates its own map and calls
the injected callbacks.

- `TimerFactory` and `clock` are constructor-injected; production passes
  nothing (real `Timer`, real clock), tests pass fakes that never sleep.
- `dispose()` cancels every armed timer. Called on TUI teardown; process
  exit makes it moot but correct.

### 4.4 Grid with busy-collapse (exact semantics)

Fixed grid: the anchor advances by `interval` from the PREVIOUS anchor,
never from actual execution time — a slow check cannot drift the schedule.

1. `set` → `nextAnchor = clock() + interval`; arm.
2. Tick fires (armed `Timer` callback):
   - **State idle** → FIRE: `fireCount += 1`, `state = queued`,
     `onFire(name, fireCount)`.
   - **State queued or running** → COLLAPSE (skip this tick): at most one
     fire per timer is in flight (queued OR executing) at any moment —
     ticks are never stacked and the queue can never fill with one timer's
     backlog. Emit the collapse notice ONCE per in-flight window (first
     skip only), so a 30s timer whose check runs ten minutes emits one
     skip line, not twenty.
3. Advance the anchor and re-arm — at fire time, at collapse, and at
   `ackFinished`: `while (nextAnchor <= clock()) nextAnchor += interval;`
   then arm for `max(nextAnchor - now, 0)`. Ticks that fell in the past
   (long check, busy loop) are skipped, and the next fire lands on the
   first future grid point. Arming for 0 is safe: the immediate tick sees
   a non-idle state and collapses.
4. `ackStarted` (queued → running): tolerated no-op in any other state
   (defensive against a mis-attributed turn).
5. `ackFinished(aborted:)`: `state = idle`; `consecutiveAbortedFires =
   aborted ? consecutiveAbortedFires + 1 : 0`; if `aborted` reaches
   `kMaxTimerFiresBeforeSuspend` → suspend (§8). If the fire count reached
   the cap (`once`, or `fireCount == maxFires`) → remove the entry and
   disarm (a completed `once` timer disappears from `/timers`). Otherwise
   re-arm per step 3.
6. `set` on an existing name REPLACES: new interval/instruction, fresh
   `fireCount` and `consecutiveAbortedFires`, `suspended = false` — the
   documented path back from suspension (§8). Replacing does not double-
   count against the cap.
7. `cancel` → disarm and remove. `list()` → snapshot of active entries,
   including suspended ones (they hold their cap slot).

## 5. Interval format + clamping

Grammar (parsed by `set_timer`, engine-side helper, unit-tested directly):

```
every  := pair+
pair   := ws* integer ws* unit ws*
unit   := 's' | 'm' | 'h' | 'd'        (case-insensitive)
integer := [0-9]{1,6}                  (no zero components)
```

- Compound sums are allowed in any order: `90s`, `5m`, `1h`, `1h30m`,
  `45m`, `1d`, `30m1h` (= `1h30m`). Seconds is the sum's unit.
- Rejected (tool error stating the grammar): empty, bare number (`5`),
  bare unit (`m`), words (`five`), zero components (`0m`), sign or other
  punctuation (`1h-30m`, `+5m`), > 6 digits.
- Clamp AFTER summing: `< 30s` → 30s; `> 24h` → 24h. Clamping is not an
  error, but the result text says so (§6). `1d` is exactly the maximum.
- Dart `int` (64-bit) cannot overflow at 6 digits × 86400 — no guard needed.

## 6. Tool surface (three thin tools, engine)

Registered app-side in `buildAgent` (agent_composition.dart:59): new
optional param `TimerService? timers`; after :114,
`if (timers != null) tools.addAll(timerToolsFor(timers));`. When `timers`
is null the tools do not exist (headless — §10). `ToolRegistry` is
last-wins; the names are new so no collision. Permissions: the standard
policy path, no special-casing — the tools mutate runtime state only.

Schema descriptions carry the steering (the model reads them where it
acts): instructions must be SELF-CONTAINED (compaction may have summarized
the context that motivated the check); checks should default to cheap,
read-only inspection; a check that keeps failing should be cancelled, not
left burning turns (pairs with the round-13 guardrails).

### 6.1 set_timer

Input: `{ name: string (required), every: string (required),
instruction: string (required), once: bool (default false), max_fires:
int (optional) }`.

Validation order, each failure returning its own error:

1. `name` matches `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` (starts alphanumeric
   so `/timers cancel <name>` parsing stays unambiguous).
2. `every` parses (§5); clamp applied (not an error).
3. `instruction` non-empty, ≤ `kMaxTimerInstructionChars`.
4. `once` and `max_fires` are mutually exclusive; `max_fires` ≥ 1.
5. Cap: creating (not replacing) beyond `kMaxActiveTimers` is rejected.

Result texts (**VERBATIM**):

- created:
  `timer '<name>' set: every <every>, <recurring | once | stops after <N> fires>. cancel with cancel_timer('<name>') or /timers cancel <name>.`
  — plus ` interval clamped to the 30s minimum.` or ` interval clamped to
  the 24h maximum.` appended when clamped.
- rejected: `set_timer rejected: <reason>. (active timers: <comma-separated
  names, or "none">)` — reason examples: name syntax, interval grammar,
  `once and max_fires are mutually exclusive`,
  `8-timer limit reached`.
- replaced: same as created, prefixed `timer '<name>' replaced:`.

### 6.2 cancel_timer

Input `{ name: string (required) }`.

- ok (**VERBATIM**): `timer '<name>' cancelled (<N> fires so far).`
- unknown (**VERBATIM**): `no timer named '<name>'. active timers: <names
  or "none">.` (isError true)

### 6.3 list_timers

Input `{}`. One line per timer, empty → `no active timers.` (**VERBATIM**):
`<name>: every <every>, <recurring | once | max <N> fires>, fired <N>x, <active | SUSPENDED (after <M> failed fires)>, next in <human duration | "in flight">`.

## 7. How a fire becomes a real agent turn

### 7.1 Injection path (the workflow precedent, verbatim seams)

`TimerService.onFire` is wired, at construction in the TUI coordinator,
to a new `SessionController` method:

```dart
void _injectTimerFire(String name, int n, String instruction) {
  final conv = active; if (conv == null) return;   // §2a: skip, dim notice
  final prompt = '[timer $name #$n] scheduled check. Instruction: $instruction\n'
      '(Report concisely; if there is nothing to report, say so in one line.)';
  _pendingTimerFireByPrompt[prompt] = name;
  host.showMessage('[timer $name #$n fired]', style: HostMessageStyle.dim);
  if (conv.isRunning) { conv.messageQueue.enqueue(prompt); }
  else { _startTurn(conv, prompt); }
}
```

The prompt text above is **VERBATIM** (including the `#<n>` and the
parenthetical steering line). The mechanism is deliberately the workflow
pattern (session_controller.dart:763-778): fires join the same
`MessageQueue` as operator input and workflow outcomes (FIFO — a human
message typed before the tick fires first), and go through the normal turn
path: echo-less (the dim `fired` line is the operator's cue), persisted
(the prompt becomes the user message; a resume shows the check exchanges),
auto-compact eligible, and budgeted like any turn.

### 7.2 Attribution (sub-decision b)

- `_startTurn` (session_controller.dart:552) gains, before arming the
  completers:
  ```dart
  final timerName = _pendingTimerFireByPrompt.remove(input);
  ```
  On a hit: `timers?.ackStarted(timerName)` and remember
  `_runningTimerFire = timerName`. On a miss (any typed, queued, or
  workflow prompt): both stay untouched.
- Queue membership is the controller's own map, so a literal typed
  `[timer x #3] …` line can never hijack attribution — map membership is
  authoritative, and the `#<n>` makes a collision need the exact fire
  number.
- `#31` interplay: a cancelled turn's queue survives and drains (#31);
  a queued timer fire that drains after a cancel is attributed by the
  same map lookup when its turn starts.

### 7.3 Ack + outcome truth at turn end

In `_runTurn`, immediately after the `agent.run` try/catch settles
(both the normal return and the catch path must ack — a thrown turn is a
failed fire), BEFORE the unwind/teardown:

```dart
final fire = _runningTimerFire; _runningTimerFire = null;
if (fire != null) {
  timers?.ackFinished(fire,
      aborted: cancel.isCompleted || s.agent.abortedReason != null);
}
```

- Failed fire = the turn was ESC-cancelled (`cancel.isCompleted`) or
  aborted (`abortedReason != null`: provider, transport-exhausted, budget,
  steps). Both count (sub-decision c). A cancelled fire turn's exchange is
  rolled back by the existing cancel path — the guard still counts the
  attempt, deliberately.
- Clean end — including a #31 operator tool-interrupt, which ends the turn
  cleanly by design — resets the counter.
- `_runningTimerFire` is a single field: turns are serialized, so at most
  one fire turn runs at a time (sub-decision a's skip rule guarantees at
  most one QUEUED fire per timer, and one RUNNING fire globally follows
  from turn serialization).

### 7.4 Round-13 interplay (each reviewed, none changed)

- **#30 timeout honesty**: a fire-turn's bash calls obey the same
  clamps/kill grace; a timed-out call is just an anomalous result to the
  check.
- **#29 retry breaker**: per-turn, per-signature — every fire gets a fresh
  streak. The TIMER-level runaway guard (§8) is the cross-fire analogue;
  the two compose instead of overlapping.
- **#31 interrupt gesture**: never triggered by timer input; fires only on
  the operator's empty-Enter. See sub-decision f.
- **#28 transport ladder**: fire-turns are `agent.run` calls; a mid-stream
  500 backs off and retries inside the turn. Exhausted ladder → aborted →
  a failed fire.
- **Spend limits / max-steps / per-turn budgets**: unchanged; any spend
  abort of a fire-turn is a failed fire. The system prompt's
  failure-discipline text (#32) already tells the agent to note-and-skip
  unrelated failures during a check.

## 8. Runaway guard

The #29 breaker cannot see ACROSS fires: a check that fails every five
minutes burns one turn per fire forever. Hence, per timer,
`consecutiveAbortedFires` (§4.4 step 5): at
`kMaxTimerFiresBeforeSuspend` (6) consecutive failed fires the service
suspends the timer — disarms it, keeps the entry and its cap slot, sets
`suspended` — and emits (**VERBATIM**, warning style):

`[timer <name> suspended after 6 consecutive failed checks — /timers cancel <name>, or ask the agent to fix and re-set it]`

Paths back: `/timers cancel`, or the agent (or operator) re-sets the name
— `set` replaces with fresh counters (§4.4 step 6). No resume subcommand
in v1. Counter resets on: any clean fire, replacement, cancel.

## 9. Operator surface — /timers

Enrollment: a new `SessionCommandEntry` in `_kSessionCommandEntries`
(session_command_registry.dart:67), names `['/timers']`, one-line
description, helpOrder next to the session commands; handler in
session_command_handlers.dart. `CommandContext` gains
`TimerService? get timers => null;` (default null keeps every existing
fake working); `SessionController` overrides it. Sub-commands:

- `/timers` — list. Output shape (indicative, via
  `host.showMessage(..., style: HostMessageStyle.dim)`):
  ```
  timers: 2/8 active
  check-build   every 5m   next in 2m13s   fired 12x   active
  watch-log     every 1h   —               fired 3x    SUSPENDED (after 6 failed fires)
  instructions truncated to ~60 chars; /timers show <name> for the full text
  ```
  Empty: `no active timers.`
- `/timers show <name>` — full instruction, fire count, last-outcome line,
  suspended state, next fire time.
- `/timers cancel <name>` — cancels the schedule without asking the agent
  (sub-decision d: a running fire turn is not killed). Output:
  `cancelled timer '<name>'`; unknown name → the active list.
- Unknown sub-command → one usage line. Service absent (headless, or
  timers unavailable) → `/timers: timer system not available in this
  session.`

## 10. Runtime scope & hosts

- **Constructed only on the interactive path**: `TimerService` is built at
  the TUI bootstrap beside `SessionController` (tui_coordinator.dart:857),
  wired (`onFire` → controller, `onNotice` → `host.showMessage`), passed
  to the controller (CommandContext exposure) and to `buildAgent(timers:)`.
- **Headless never sees it**: the `--prompt` runner constructs no service,
  so `buildAgent` gets `timers: null` and registers no timer tools — no
  dead surface. Verified seam: agent_composition.dart:114.
- **No persistence, no resume reinstatement (v1)**: timers live and die
  with the process (the owner's framing: "within the tina runtime"). A
  resumed session's history shows past check exchanges but no live timers;
  the agent must re-set them. A keep-alive mode (`--run-timers <duration>`)
  is deferred (§13).
- **Session switch**: the service is controller-owned (sub-decision a) and
  outlives individual conversations; fires target the active conversation,
  and are skipped (dim notice) when none is active.
- **Dispose**: TUI teardown calls `dispose()` (cancels all armed timers).

## 11. Testing plan

Engine suite (packages/tina_engine) — fake factory + fake clock, no sleeps:

- `timer_service_test.dart`: arm→tick→onFire callback; grid anchor drift
  (late fire → next anchor = old anchor + interval); past-tick skip rule;
  collapse while queued (second tick skipped, ONE notice per window);
  queued→running→idle transitions via acks; `ackStarted`/`ackFinished`
  tolerated no-ops in wrong states; `once` removes the entry after its
  fire completes; `max_fires` expiry; suspension at exactly 6 consecutive
  aborts (5 then a clean fire resets); replace resets counters and clears
  suspension; replace does not double-count the cap; cap 8 creation
  rejection; cancel returns false on unknown; dispose cancels all.
- `timer_tools_test.dart`: interval parse table (`90s`, `5m`, `1h30m`,
  `1d`, `30m1h` accept; `10s`→clamp-30 text, `25h`→clamp-24h text;
  ``, `5`, `m`, `five`, `0m`, `1h-30m`, 7-digit reject); name validation
  table; instruction length bound; once/max_fires exclusion; cap
  rejection text; cancel unknown lists actives; list empty text; result
  texts byte-match §6 **VERBATIM** strings.

Root suite (test/):

- `session_controller_test.dart`: fire-while-idle starts a turn with the
  exact prompt text; fire-while-busy enqueues and drains FIFO behind a
  typed message; a second tick during the queued window collapses; turn
  end acks (clean → counter reset); ESC-cancelled fire counts toward
  suspension; thrown turn (stub provider error) counts; attribution map
  cannot be spoofed by a typed look-alike prompt (wrong `#<n>`); #31
  gesture still works when only a timer fire is queued (sub-decision f).
- session-commands test: `/timers` list/show/cancel against a fake
  service (incl. unknown name and absent-service messages);
  `CommandContext.timers` default null compiles existing fakes unchanged.
- `agent_composition` test: `buildAgent(timers: null)` registers no timer
  tools; non-null registers exactly the three.

Console package: untouched (no tina_console files in this feature).

## 12. Rollout (after owner sign-off on this spec)

Two legs driven through tina (the driver never implements), off
post-#45 main:

1. **Engine leg** — `timers/` (service, interval parser, three tools,
   constants) + engine tests; this spec file rides the leg as a tracked
   doc (paths updated if anchors moved).
2. **App leg** — composition wiring, `SessionController` injection/acks,
   `/timers` command + tests.

Round-close-note style log entry at the end. Nothing merges without an
explicit owner instruction.

## 13. Out of scope / deferred

- Persistence across restarts; `--resume` reinstating timers.
- Headless keep-alive (`--run-timers <duration>`).
- Cross-conversation/global timer targeting; per-conversation services.
- Cron-expression schedules (v1 is interval-only).
- Timer fires interrupting a hung tool — interrupts stay human-only (#31).
- Suspension resume subcommand (v1 path: cancel or re-set).
