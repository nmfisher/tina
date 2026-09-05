# Guardrails for stuck commands and operator interrupts

Status: PROPOSAL — owner findings from a live interactive run (2026-09-05).
Not yet greenlit; nothing implemented. Anchors verified against `main` @
`af4c0dd` (2026-09-05).

## 1. Findings

1. No self-detection of a repeatedly failing command — the agent re-ran the
   exact same hung test instead of recognizing "this always times out,
   unrelated, move on".
2. Hung commands are not interruptible from the message queue — queued
   messages never processed while a long/hung bash command ran; the operator
   had to manually Ctrl-C.
3. Wasted tokens on unrelated flakiness — large time/output spent chasing a
   test outside the task's scope instead of returning to the primary task
   (push + open PR).
4. No timeout awareness — the agent did not stop retrying a test that
   produced empty output 4+ times.

## 2. Root causes

### 2.1 Finding 1 — the engine has no memory of a failing command

The only repetition counters in the agent loop are `denialCounts`
(agent.dart:451 — permission DENIALS only, keyed by tool name, #27 breaker,
threshold 3 at agent.dart:60) and `emptyCompletions` (agent.dart:446 — empty
MODEL completions, not tool output). An executed command that fails, hangs,
or returns nothing is appended to history like any other result and the loop
continues (agent.dart:833 onward); nothing anywhere hashes, compares, or
counts command content (verified: no such map exists in engine or app).
The model is free to re-run the identical command forever.

### 2.2 Finding 4 — a timeout exists but is invisible and model-controlled

BashTool already has a default 60s timeout (bash_tool.dart:162), overridable
per call by the MODEL via `input.timeoutSeconds` (bash_tool.dart:232; schema
:211) with no validation or clamp. On expiry the result (bash_tool.dart
:345-358) never mentions it: the model sees `exit: -15` — byte-identical in
shape to any crash — because `cancelled` (:349) is set only on the
user-cancel path and no flag records the timer firing. Timeout and cancel are
indistinguishable; there is no elapsed time either. Worst case: the model
re-runs the hung test with `timeoutSeconds: 3600` and parks the turn for an
hour. Empty output is equally invisible: exit-0-with-no-output reports
`isError: false` with only the literal `(empty)` placeholders (:353,:356).

### 2.3 Finding 2 — queued input is inert, and the interrupt destroys it

Typed input during a run goes to a per-conversation in-memory queue
(session_controller.dart:411) drained ONE message per completed turn
(session_controller.dart:661). The only gestures that touch a running turn
complete the turn's cancel completer (Esc arm-then-cancel; Esc-Esc
immediate); cancelSignal flows into `tool.execute` (agent.dart:833) and bash
kills the process tree on it (bash_tool.dart:325-327). Three defects compose:

- Cancelling DISCARDS the entire queue (session_controller.dart:627-631,
  "[N queued messages discarded]") — breaking in destroys the operator's
  typed work.
- The kill is best-effort: `terminate()` is fire-and-forget and the tool
  awaits `proc.exitCode` forever if the kill fails (bash_tool.dart:314-330,
  no bypass; `setsid`/process-group escape documented at process_tree.dart
  :8-11). A child that survives the kill freezes the turn at agent.dart:833
  — even Esc stops working, and Ctrl-C x2 (app quit; buffer-clear
  line_editor.dart:777-780, quit-confirm path) is the only exit, losing the
  in-memory queue with the process.
- Race: the run flag clears (session_controller.dart:649) before the drain
  (:661), so a submit in that window starts a second concurrent turn.

Dead code note: `LineEditor.beginCancelMonitor` (line_editor.dart:299)
implements a queue-mode submit path with no production callers.

### 2.4 Finding 3 — no scope discipline exists anywhere

The identity prompt (agent_pipeline.dart:277-291, assembled via
system_prompt.dart:59/:127) contains nothing about failing commands,
retries, or scope; greps for unrelated/flaky/move-on/retry/finish hit only
per-event injections (malformed-args remediation, the 90%-budget nudge, the
headless closing-summary ask). The model has no stated policy for
unrelated flakiness — and the #27 lesson is that prose outside tool results
does not reliably steer the model, so a prompt fix alone is insufficient.

## 3. Proposed fixes — four work items

### A. Command retry guard (findings 1 + 4) — engine, agent loop

- `ToolResult` gains additive optional metadata: `timedOut`, `elapsed`,
  `emptyOutput` (nullable, default null — source-compatible with every
  existing construction, tool.dart:12-19). Only BashTool populates them this
  round; null degrades gracefully.
- Per-turn streak map beside `denialCounts`, keyed by
  `signature = tool name + normalized input` (bash: whitespace-collapsed
  command; other tools: serialized input).
- Anomaly classes: (1) `timedOut == true`; (2) `emptyOutput == true` at any
  exit code; (3) `isError` whose content equals the previous attempt's
  content for the same signature.
- Threshold 3 consecutive anomalies of one signature — same constant and
  rationale as the #27 denial breaker (agent.dart:60); reset on a normal
  result or a different signature; per-turn scope. No config surface, like
  `kMaxToolCallsPerRun` (agent.dart:25).
- At/after the threshold: append a model-visible NOTE to the tool_result
  content (in-band, the #27 lesson) + `sink.notice` UI mirror. The NOTE
  carries finding 3 mechanically: stop re-running unchanged; if the failure
  is unrelated to the task, record it and return to the primary objective;
  if it is essential, change the approach (narrower target, timeout,
  different tool, fix the cause).

### B. Timeout honesty + kill bypass (finding 4; the hang half of finding 2)
    — engine, BashTool

- Label the timeout: timer-fired termination reports
  `command timed out after <sec>s (exit: -15)` plus an `elapsed: <t>` line;
  sets `ToolResult.timedOut` (feeds A); user-cancel keeps its own line.
- Clamp model-supplied `timeoutSeconds` to [1, 900] (above the headless
  watchdog default of 300; past the watchdog a longer value is pointless).
- Kill bypass: after `terminate()` — timeout OR cancel — race
  `proc.exitCode` against a bounded grace (10s); if the child survives,
  return the result with "process did not exit after kill; output may be
  incomplete". `execute()` can then never pend forever, so agent.dart:833
  always unblocks and Esc always frees the turn.
- Stopwatch elapsed on every result.

### C. Operator interrupt + queue survival (finding 2) — app layer

- Engine seam: `Agent.run` gains an optional `toolInterruptSignal`,
  distinct from `cancelSignal`. While a tool executes, the agent passes the
  interrupt signal to `tool.execute` (bash kills via its existing cancel
  path); on fire, the interrupted call's result is prefixed "interrupted by
  operator — new input pending", remaining uses in the batch get
  "(skipped: operator interrupt)" stubs, and the batch is appended WHOLE —
  tool_use/tool_result pairing (the hard invariant) is preserved. The turn
  then ends cleanly: no `[cancelled]` notice, `abortedKind` none. Provider
  stream phases are NOT interrupted (bounded by stream-idle-timeout;
  interrupting mid-token loses work for no gain).
- New gesture: pressing Enter on an EMPTY input while the session is running
  and the queue is non-empty completes `toolInterrupt` instead of doing
  nothing. Division of labor: Esc/Esc-Esc = cancel the whole turn
  (unchanged); Enter-on-empty = "break into the run and process what I
  typed".
- Queue survives cancel: the discard at session_controller.dart:627-631
  becomes keep-and-drain — a cancelled turn hands the backlog to the next
  turn like a finished one. Typed input is the operator's work; destroying
  it punishes exactly the person the interrupt exists for.
- Rider: fix the :649/:661 race (drain decision before clearing the run
  flag, or re-check).

### D. Scope discipline in the identity prompt (finding 3) — engine text

Append ~3 sentences to `_mainIdentity` (agent_pipeline.dart:277): failures
unrelated to the change (pre-existing flakiness, infrastructure, untouched
files) are noted, not chased; two identical failures of the same command
mean change the approach or move on; anything skipped this way is named in
the closing summary. Optional rider: one line in the default workflow node
identities (lib/pipeline/default_workflow.dart) — sub-agents do not inherit
the main identity. Reinforced mechanically by A's NOTE (prose + in-band,
the #27 pattern).

## 4. Decisions for the owner (recommendations marked)

1. Interrupt gesture: Enter-on-empty-with-queued-input (RECOMMENDED) vs
   auto-interrupt on first enqueue (more aggressive; risks killing
   legitimate long commands the operator was merely queueing behind).
2. Queue survives cancel: keep-and-drain (RECOMMENDED — finding 2 implies
   it) vs current discard.
3. `timeoutSeconds` clamp max: 900 (RECOMMENDED) vs tying it to
   `--watchdog-seconds` at startup.
4. Retry-guard threshold: 3 (RECOMMENDED, matches #27) — not configurable.
5. Empty-output counting: include exit-0-empty (RECOMMENDED — that is
   finding 4's shape) vs error results only.

## 5. Rollout (round 13, after greenlight)

Four tickets, one per finding (A covers 1 + the mechanism half of 4).
Suggested leg order: (1) B + D — small, independent, engine-only;
(2) A — loop + metadata + tests; (3) C — engine seam + app layer. The
driver sequences legs and verifies per the standing ritual; nothing merges
without explicit owner instruction. Engine default behavior note: A's NOTE
text and B's labels change tool results only on the abnormal paths they
exist for (timeouts, empty output, identical failures); normal runs are
byte-identical.

## 6. Deferred

- Step-boundary queue drain (redundant once the interrupt gesture exists).
- Spend-based detour nudge (#37-style) if A + D prove insufficient.
- `ToolResult` cancelled-by enum to disambiguate cancel/interrupt wording
  inside bash's own report (v1 uses the engine-side prefix).
- Populating the new metadata in tools beyond bash.
- Removing or wiring the dead `beginCancelMonitor` queue-mode path.
