# Tickets — tool-cancellation gaps

Status: PROPOSED — owner to greenlight per ticket.
Anchors verified against `main` @ `0037fb7` (2026-09-17). Working tree has 32
modified / 15 untracked files; re-anchor line numbers before implementation.

Provenance: found via a bounded Typesafe `explore_project` run plus targeted
greps. Evidence classes are marked per ticket: **[E]** = read in returned
source excerpt, **[G]** = grep/read hit this session (line seen, body not
read), **[?]** = inferred, unverified. No ticket claims work is needed in a
file whose relevant body was not at least grep-confirmed.

## Shared context (what exists)

Cancellation is layered; tickets below only touch seams that greps show are
not fully closed:

1. **Gestures** — Esc/Esc-Esc = cancel the turn (`cancelCompleter`);
   Enter-on-empty with queued input = operator interrupt
   (`toolInterruptCompleter`) [E: `lib/session_controller.dart:415-436`,
   `packages/tina_app/lib/src/execution/turn_executor.dart:99-114`].
2. **Per-turn signals** — `TurnExecutor._drain` creates a fresh completer
   pair each turn and passes both into `driver.run` [E:
   `turn_executor.dart:178-180, 330-341`].
3. **Agent loop** — `Agent._runTurn` arms the interrupt
   (`agent.dart:549`), computes the either-signal stop future
   (`Future.any([cancelSignal, toolInterruptSignal])`, `agent.dart:560-564`),
   and hands both to the executor (`agent.dart:572`) [G: line hits; body
   chunk not read].
4. **Dispatch** — `ToolExecutor` passes `toolStopSignal` to `tool.execute`
   at three sites (`tool_executor.dart:530, 638, 708`) [G]; whole-batch
   invariants pinned by `packages/tina_engine/test/agent/agent_tool_interrupt_test.dart`
   [E: full file].
5. **Kill** — `ProcessTool` races `proc.exitCode` against `postKillGrace`
   (10 s) after `killProcessTree` + `proc.kill(force: true)` on cancel or
   timeout [E: `process_tool.dart:438-474`]; stragglers reaped at exit by
   `ChildProcessRegistry.reapAll` [E: `process_registry.dart:1-45`].

Confirmed NOT gaps (do not re-ticket): `Agent` wiring (above);
`LineEditor.beginCancelMonitor` is live production wiring, not dead code
(`line_editor.dart:333`; `ARCHITECTURE.md:155`; tests
`ctrl_c_paths_test.dart:87-119`) — see Ticket T307; Ctrl+C quit hardening
shipped in `7b31efd` ("Always let the user quit") with test coverage in
`packages/tina_console/test/ctrl_c_paths_test.dart` [G];
`grep_tool` already honors `cancelSignal` (`grep_tool.dart:204,294`) [G].

---

## T304 — Audit every `Tool` implementation against the `cancelSignal` contract

**Area:** engine (`packages/tina_engine/lib/src/tools/`) · **Priority:** High
**Evidence:** [G] sweep of `cancelSignal` in tool implementations.

**Problem.** The seam is declared once (`tool.dart:48,57`: "cancelSignal is
completed when the user has asked to…") and reached from
`ToolExecutor` (`tool_executor.dart:530,638,708`), but honoring it is
per-tool and uneven. Confirmed honoring: `process_tool.dart:442`,
`grep_tool.dart:204,294`. Present but mechanism unread: `delegate_tool.dart`
(doc comment at `:15` claims propagation to spawned jobs; `:58` shows
`cancelSignal?.whenComplete`). Accept the parameter with no observed use:
`edit, execution_info, fetch, git, glob, ls, read, render_image, search,
stat, web_search, which, write_summary, write` (line numbers from grep —
each may still use it in unread code; that is the point of the audit).
Not swept at all: any PTY-backed tool (`docs/features/pty_backend.md`
describes a PTY backend; no PTY tool appeared in the grep) [?].

**Work items.**
1. Enumerate every `Tool implements`/subclass in the repo (include PTY and
   channel-backed tools). For each: does it *act* on `cancelSignal` (race a
   network/stream future, kill a process, abort a loop), or only accept it?
2. For tools where cancellation cannot take effect (e.g. a pure-FS read that
   completes in microseconds), say so in one line of doc — silence reads as
   support.
3. For tools that can pend (fetch, web_search, delegate, channel tools),
   wire the signal: race the in-flight future against
   `cancelSignal`, return an error `ToolResult` naming the cancellation.
   Keep the additive no-throw shape — a completed signal must never throw
   out of `execute`.
4. Add a contract test (pattern: `agent_tool_interrupt_test.dart`'s
   `GatedTool`) asserting each pendable tool returns promptly when its
   signal completes mid-flight.

**Accept.** Table in this file's successor (or the tool docs) listing every
tool → behavior; contract test green for all pendable tools; no change to
`Tool.execute`'s signature.

**Risks.** Racing a future that is later completed normally can double-
report; return the cancellation result only when the signal actually fired
(`Completer.isCompleted` at decision time), as `process_tool` does with its
`cancelled` flag [E: `process_tool.dart:442-447`].

---

## T305 — Populate `ToolResult` cancellation/timeout metadata beyond bash

**Area:** engine tools + executor guardrails · **Priority:** Medium
**Evidence:** [E] `tool_executor.dart:192-215` (`isAnomalousResult` reads
`timedOut`/`emptyOutput`); [G] population sites observed only in
`process_tool` (flag writes at `:447-460`, result assembly unread);
[?] other tools.

**Problem.** The anomaly guardrail (#29) only sees `timedOut` / `emptyOutput`
metadata when a tool populates it. Proposal §6 explicitly deferred
"Populating the new metadata in tools beyond bash." Net effect: a hung
`fetch` or `web_search` call that times out at the HTTP layer looks like an
ordinary error to the retry guard, so the model is free to re-run it — the
exact spiral #29 exists to stop.

**Work items.**
1. `fetch_tool`, `web_search`: on timeout class failures set
   `timedOut: true` + `elapsed`; on zero-byte success bodies set
   `emptyOutput: true` (match bash's semantics — see
   `isAnomalousResult`, `tool_executor.dart:192-215`).
2. `delegate_tool`: surface child-run abort/timeout as `timedOut` where the
   supervisor already knows it, so a delegation that burned its whole budget
   counts toward the guardrail.
3. Keep fields nullable and additive; nothing normal-path may change bytes
   (proposal §5 "normal runs are byte-identical" applies).
4. Extend `tool_executor_test.dart` (ranked 0.43 last run, unread) with
   anomaly-count cases for a non-bash tool.

**Accept.** A fetch/web_search timeout increments the per-turn anomaly streak
and eventually appends `anomalyGuardrailNote`; bash behavior unchanged.

**Depends:** T304 (fetch/web_search cancel wiring overlaps).

---

## T306 — Workflow cancellation: inventory, then close or document

**Area:** app/engine workflow seam (`packages/attractor`, workflow
supervisor) · **Priority:** Medium
**Evidence:** [E] `turn_executor.dart:127` (`injectWorkflowResult` *skips*
`WorkflowRunStatus.cancelled` — the type exists); [?] no cancel path found
for a *running* workflow in any returned excerpt.

**Problem.** Two sibling async mechanisms diverge: delegated sub-agent jobs
document cancel propagation (`delegate_tool.dart:15`), and chat turns have
two gestures plus per-turn completers, but nothing excerpted shows how an
operator cancels a running `WorkflowRun` — or that they can. The system
prompt tells the user to "Cancel a running launch with `stop_workflow`"
while `launch_workflow` runs fire-and-forget in the background
(`turn_executor.dart:309-317` comment); whether a tool/backing
implementation for stopping exists was not established.

**Work items.**
1. Inventory: trace `WorkflowRun` lifecycle — who can set
   `WorkflowRunStatus.cancelled` today, and from which surface?
2. If no user path exists: add one (tool parameter or session command) that
   completes the run's cancellation future and lets nodes stop at the next
   boundary — mirroring the toolInterrupt pattern rather than killing
   mid-write.
3. If a path exists: verify the running node's in-flight LLM call and tools
   receive a cancel signal (they may only check between nodes).
4. Test: cancel a running workflow with one node parked; assert the node
   stops at its next boundary, status lands `cancelled`, and
   `injectWorkflowResult` stays silent for it.

**Accept.** Either a working cancel gesture with the test above, or a
documented decision (doc note here + feature doc) that workflows are not
operator-cancellable, with the reason.

---

## T307 — Correct `runaway_command_guardrails.md`: it misstates shipped code

**Area:** docs · **Priority:** High (cheap, actively misleading)
**Evidence:** [E] `docs/proposals/runaway_command_guardrails.md`;
[G] contradicting hits listed below.

**Problem.** The doc is anchored at `af4c0dd` (2026-09-05) and three of its
claims are now false against `0037fb7`:

1. **"Dead code note" (line 69) is wrong.** `LineEditor.beginCancelMonitor`
   is the production ESC/queue-submit wiring — `line_editor.dart:333`,
   documented in `ARCHITECTURE.md:155`, driven from
   `session_controller`'s capture-window path, covered by
   `ctrl_c_paths_test.dart:87-119`. This is the *second* time this claim
   circulated: `TINA_IMPROVEMENTS_LOG.md:1755` records a prior
   "grep-clean everywhere — false" incident. Deferred item §6
   "Removing or wiring the dead `beginCancelMonitor` queue-mode path"
   should be struck or rewritten.
2. **Deferred item "Step-boundary queue drain" is superseded.** Cancel
   no longer destroys the queue: `TurnExecutor` keeps and drains it
   (`turn_executor.dart:214`, queue survives cancel per the `'[cancelled]'`
   handling at `:372-379`) — proposal §3C implemented.
3. **Status header stale.** Legs A/B/C are implemented (constants
   `kOperatorInterruptedLine`/`kOperatorInterruptedStub`
   `tool_executor.dart:112-119`; kill-bypass grace `process_tool.dart:452-474`;
   interrupt seam + Enter-on-empty gesture `session_controller.dart:415-436`),
   yet the doc still reads "Not yet greenlit; nothing implemented."

**Work items.** Update the doc: mark implemented legs with current anchors
@ `0037fb7`; fix the dead-code claim; resolve superseded deferred items;
re-run the §4 decision list and record what was actually chosen (e.g. the
Enter-on-empty gesture shipped as recommended). Add a one-line note that
anchors older than the working tree are historical.

**Accept.** Every file:line citation in the doc resolves against `main`;
nothing in the doc calls wired code dead. No code changes.

---

## T308 — Headless + watchdog cancellation contract

**Area:** headless runner (`bin/`, headless host paths) + session watchdog
(`lib/config.dart` per process_tool's comment) · **Priority:** Medium-Low
**Evidence:** [E] `process_tool.dart:157-162` — timeout clamp to 900 s is
sized against "the session watchdog's 300s default (lib/config.dart)";
[E] `session_controller.dart:38-39` (`exitSignal`) and `run()` doc "Returns
when [exitSignal] fires"; [?] how headless wires the two signals.

**Problem.** Interactive cancellation is well covered; the non-interactive
path is not established. Two concrete unknowns: (1) does the headless runner
hand `Agent.run` a `cancelSignal`/`toolInterruptSignal` at all, and on what
stimulus (SIGTERM? `exitSignal`?); (2) when the session watchdog fires mid-
tool, does anything deliver `cancelSignal` to the running tool, or does the
tool's own 900 s clamp (540 s past the watchdog) simply outlive the session?
`ChildProcessRegistry.reapAll` bounds orphan leaks at exit
(`process_registry.dart:36-44`) but says nothing about the turn unwinding
cleanly.

**Work items.**
1. Read the headless entry path; record whether and how each signal is
   populated.
2. If the watchdog only kills the process: decide whether watchdog fire
   should complete the turn's cancel completer first (graceful unwind —
   history preserved, `[cancelled]` marker) before hard exit.
3. Test: headless run with a tool parked past the watchdog — assert process
   exit is bounded and no child outlives the session
   (`reapAll` already covers the leak half; the turn-state half is the gap).

**Accept.** Written contract (feature doc or doc comment on the headless
runner) answering (1) and (2), plus the test if implementation changes.

---

## Ordering

T307 (doc fix, zero risk) → T304 (audit; informs T305) → T305 → T308 →
T306. T306 can run parallel to T304; they share no files.

## Not ticketed, for the record

- `Agent._runTurn` interrupt wiring — confirmed present (`agent.dart:549-573`).
- `tool_executor.dart` chunks 2–3 / `process_tool` chunk 2 unread — that is
  exploration hygiene from the audit run, not a product gap; T304's audit
  reads those regions anyway.
- Ctrl+C quit hardening — shipped (`7b31efd`) with tests.
